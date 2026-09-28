"""
seren-claude-ripple.py - the ripple command for Claude Code, read off this box.

    python seren-claude-ripple.py <project dir> [--claude-json PATH] [--yaml INDENT]

Prints one JSON object: {"command": [...], "cwd": "<project dir>", "servers": [...]}.
With --yaml N it prints the two config lines instead, indented N spaces:
`command: [...]` and `cwd: "..."` (JSON is valid YAML), ready to drop into a
ripple block.

WHY: a ripple wakes the main model with `claude -p "{message}"`. For that run
to BE the model - Wren, with their memory - two things have to be true that the
bare command does not give (Chad, 28 Sept 2026, "so that YOU can use it here"):

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
"""
from __future__ import annotations

import json
import os
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
    command = ["claude", "-p", "{message}", "--allowedTools", ",".join(f"mcp__{s}" for s in servers)]
    cwd = os.path.abspath(os.path.expanduser(project))
    if "--yaml" in argv:
        pad = " " * int(argv[argv.index("--yaml") + 1])
        print(f"{pad}command: {json.dumps(command)}")
        print(f"{pad}cwd: {json.dumps(cwd)}")
        return 0
    print(json.dumps({"command": command, "cwd": cwd, "servers": servers}))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
