"""
seren-claude-hook.py - add or remove a Seren hook in Claude Code's settings.

    python seren-claude-hook.py add    <event> <marker> <command> [--settings PATH]
    python seren-claude-hook.py remove <event> <marker>           [--settings PATH]

<event> is a Claude Code hook event (SessionStart, UserPromptSubmit, ...).
<marker> is a string that identifies OUR entry inside its command (the
helper's file name) - an existing entry carrying it is replaced, never
duplicated, so a reinstall is safe. <command> is the command line the hook runs.

Writes ~/.claude/settings.json (SEREN_CLAUDE_SETTINGS or --settings for
another), keeping everything else in it exactly as it was:
  - a settings file that is not valid JSON is never touched (exit 2, and why)
  - the previous file is kept beside it as settings.json.seren-bak
  - the write is atomic (temp file, then replace)

WHY a script and not the card's shell: merging JSON by hand in bash or
PowerShell is how settings files get mangled. Standard library only.
This is the Claude CLI's clip; when carabiners arrive (their own repo, .kbh
packages) this moves into the Claude one.
"""
from __future__ import annotations

import json
import os
import shutil
import sys


def _settings_path(argv: list[str]) -> str:
    if "--settings" in argv:
        return argv[argv.index("--settings") + 1]
    return os.environ.get("SEREN_CLAUDE_SETTINGS") or os.path.expanduser("~/.claude/settings.json")


def _strip(entries: list, marker: str) -> list:
    """The event's matcher groups with every hook carrying `marker` removed;
    a group left with no hooks goes too."""
    out = []
    for group in entries:
        if not isinstance(group, dict):
            out.append(group)
            continue
        hooks = [h for h in (group.get("hooks") or [])
                 if not (isinstance(h, dict) and marker in str(h.get("command", "")))]
        if hooks:
            out.append({**group, "hooks": hooks})
    return out


def main(argv: list[str]) -> int:
    pos = [a for i, a in enumerate(argv) if a != "--settings" and (i == 0 or argv[i - 1] != "--settings")]
    if len(pos) < 3 or pos[0] not in ("add", "remove") or (pos[0] == "add" and len(pos) < 4):
        print(__doc__.strip().splitlines()[2], file=sys.stderr)
        return 64
    action, event, marker = pos[0], pos[1], pos[2]
    path = _settings_path(argv)
    data: dict = {}
    if os.path.exists(path):
        try:
            with open(path, encoding="utf-8") as f:
                data = json.load(f) if os.path.getsize(path) else {}
        except (OSError, ValueError) as e:
            print(f"{path} is not valid JSON ({e}); not touching it. Fix it, then run the install again.",
                  file=sys.stderr)
            return 2
        if not isinstance(data, dict):
            print(f"{path} is not a JSON object; not touching it.", file=sys.stderr)
            return 2
    hooks = data.get("hooks") if isinstance(data.get("hooks"), dict) else {}
    entries = _strip(list(hooks.get(event) or []), marker)
    if action == "add":
        entries.append({"hooks": [{"type": "command", "command": pos[3]}]})
    if entries:
        hooks[event] = entries
    else:
        hooks.pop(event, None)
    if hooks:
        data["hooks"] = hooks
    else:
        data.pop("hooks", None)

    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    if os.path.exists(path):
        shutil.copy2(path, path + ".seren-bak")
    tmp = path + ".seren-tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
    os.replace(tmp, path)
    print(f"{'added' if action == 'add' else 'removed'} the {event} hook ({marker}) in {path}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
