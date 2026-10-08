"""
seren-claude-ripple.py - the ripple command for Claude Code, read off this box.

    python seren-claude-ripple.py <project dir> [--claude-json PATH] [--yaml INDENT]

Prints one JSON object: {"command": [...], "cwd": "<project dir>", "servers": [...]}.
With --yaml N it prints the two config lines instead, indented N spaces:
`command: [...]` and `cwd: "..."` (JSON is valid YAML), ready to drop into a
ripple block.

WHY: a ripple wakes the main model with `claude -p "{message}"`. For that run
to BE the model - the persona, with its memory - two things have to be true
that the bare command does not give:

  - it runs in the project the memory MCP servers are registered for. Claude
    Code keeps local-scope servers per project in ~/.claude.json; started
    anywhere else, the model wakes with no Memory, no Loci, no Margin.
  - those servers' tools are pre-approved. A headless `claude -p` cannot
    answer a permission prompt, so an unapproved submit_brief just stalls.

So the card asks for the project, and this reads which MCP servers it has
(project scope, plus any user-scope ones) and writes the command with
`--allowedTools mcp__<server>,...` - server-wide rules, one per server - and
the project as the working directory. Nothing is guessed: no servers found is
an error that says where it looked. Standard library only.

The card writes the JSON list straight into the yaml (a JSON list is valid
YAML), so the command is an argument list end to end.

THE LIST IS READ WHEN THE MODEL IS WOKEN, NOT WHEN THE CARD RAN (6 Oct 2026).
The command used to carry the server names it found at install time, frozen
into the yaml. Then the model's servers change - five of them become one
Workbench - and the next wake-up pre-approves five servers that are gone and
none that are there: the woken run can call nothing, cannot say so, and the
sleep cycle stalls without an error. So with --launcher the command the card
writes is THIS SCRIPT:

    command: [<python>, <a copy of this file>, <project>, "--run", "{message}"]

and --run does the lookup at that moment, then starts
`claude -p --allowedTools mcp__<each server now registered>` in the project,
with the message on claude's stdin (never on a command line: a wake-up can
quote anything). No servers at that moment is exit 2 and a line saying where
it looked - a wake-up that cannot work says so in the ripple log.

    python seren-claude-ripple.py <project dir> --run [MESSAGE]     (MESSAGE or stdin)
    python seren-claude-ripple.py <project dir> --yaml N --launcher <python> <path to this file>
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys


def servers_for(project: str, claude_json: str) -> list[str]:
    with open(claude_json, encoding="utf-8") as f:
        data = json.load(f)
    want = os.path.normcase(os.path.normpath(os.path.expanduser(project)))
    found: list[str] = list((data.get("mcpServers") or {}).keys())          # user scope
    for key, proj in (data.get("projects") or {}).items():
        if os.path.normcase(os.path.normpath(key)) == want:
            found += list((proj or {}).get("mcpServers", {}).keys())         # local scope
    mcp_json = os.path.join(os.path.expanduser(project), ".mcp.json")       # project scope
    if os.path.isfile(mcp_json):
        with open(mcp_json, encoding="utf-8") as f:
            found += list((json.load(f).get("mcpServers") or {}).keys())
    return sorted(set(found))


def find_claude() -> str | None:
    """Where `claude` is for the account this runs as. PATH first; then the
    places the installers put it, because a service that wakes the model
    (the Observatory, as run_as) hands it the SERVICE's PATH - CUDA, a
    system Python - and not the account's own. First seen 7 Oct 2026: the
    first wake over the cluster refused with "no claude on this account's
    PATH" while claude sat in ~/.local/bin the whole time. SEREN_CLAUDE_BIN
    names it outright and wins."""
    named = os.environ.get("SEREN_CLAUDE_BIN")
    if named:
        return named
    found = shutil.which("claude")
    if found:
        return found
    homes = [os.path.expanduser("~")]
    for var in ("USERPROFILE", "HOME"):
        if os.environ.get(var) and os.environ[var] not in homes:
            homes.append(os.environ[var])
    if os.name == "nt" and os.environ.get("USERNAME"):
        homes.append(os.path.join(os.environ.get("SystemDrive", "C:") + os.sep, "Users", os.environ["USERNAME"]))
    names = ("claude.exe", "claude.cmd", "claude") if os.name == "nt" else ("claude",)
    for home in dict.fromkeys(homes):
        for folder in (os.path.join(home, ".local", "bin"),                     # the native installer
                       os.path.join(home, ".claude", "local"),                  # claude's own local install
                       os.path.join(home, "AppData", "Roaming", "npm"),         # npm -g on Windows
                       os.path.join(home, ".npm-global", "bin")):               # npm -g with a user prefix
            for name in names:
                candidate = os.path.join(folder, name)
                if os.path.isfile(candidate):
                    return candidate
    for candidate in ("/usr/local/bin/claude", "/opt/homebrew/bin/claude"):
        if os.path.isfile(candidate):
            return candidate
    return None


def main(argv: list[str]) -> int:
    if not argv or argv[0] in ("-h", "--help"):
        print(__doc__.strip().splitlines()[2], file=sys.stderr)
        return 64
    project = argv[0]
    # SEREN_CLAUDE_JSON: tests (and an unusual layout) point it elsewhere.
    claude_json = os.environ.get("SEREN_CLAUDE_JSON") or os.path.expanduser("~/.claude.json")
    if "--claude-json" in argv:
        claude_json = argv[argv.index("--claude-json") + 1]
    if not os.path.isdir(os.path.expanduser(project)):
        print(f"no such project folder: {project}", file=sys.stderr)
        return 2
    try:
        servers = servers_for(project, claude_json)
    except FileNotFoundError:
        print(f"no Claude Code settings at {claude_json} - run claude once in {project} and add the MCP "
              f"servers there first", file=sys.stderr)
        return 2
    if not servers:
        print(f"no MCP servers are registered for {project} in {claude_json} (or its .mcp.json): a ripple "
              f"would wake the model without its memory. Add them with `claude mcp add` in that folder.",
              file=sys.stderr)
        return 2
    cwd = os.path.abspath(os.path.expanduser(project))
    allowed = ",".join(f"mcp__{s}" for s in servers)
    if "--run" in argv:
        # Woken: the lookup above was done NOW. The message is the argument
        # after --run, or stdin (a ripple that sends it that way).
        i = argv.index("--run")
        message = argv[i + 1] if len(argv) > i + 1 and not argv[i + 1].startswith("--") else sys.stdin.read()
        claude = find_claude()
        if claude is None:
            print(f"no `claude` for this account: not on PATH ({os.environ.get('PATH', '')[:200]}), not in "
                  f"~/.local/bin, ~/.claude/local or npm's folder. Set SEREN_CLAUDE_BIN to where it is. "
                  f"The model cannot be woken here.", file=sys.stderr)
            return 2
        try:
            done = subprocess.run([claude, "-p", "--allowedTools", allowed], input=message, text=True,
                                  encoding="utf-8", cwd=cwd)
        except OSError as exc:
            print(f"`claude` at {claude} could not be started ({exc}) - the model cannot be woken here",
                  file=sys.stderr)
            return 2
        return done.returncode
    command = ["claude", "-p", "{message}", "--allowedTools", allowed]
    if "--launcher" in argv:
        i = argv.index("--launcher")
        python, script = argv[i + 1], argv[i + 2]
        command = [python, script, cwd, "--run", "{message}"]
    if "--yaml" in argv:
        pad = " " * int(argv[argv.index("--yaml") + 1])
        print(f"{pad}command: {json.dumps(command)}")
        print(f"{pad}cwd: {json.dumps(cwd)}")
        return 0
    print(json.dumps({"command": command, "cwd": cwd, "servers": servers}))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
