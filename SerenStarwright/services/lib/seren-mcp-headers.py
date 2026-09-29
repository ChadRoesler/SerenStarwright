"""
seren-mcp-headers.py - a Seren service's Authorization header, for Claude Code.

    <service venv python> seren-mcp-headers.py <service config yaml>

Prints one JSON object: {"Authorization": "Bearer <token>"}, or {} when the
service has no bearer. Exits 1 with the reason on stderr when the config
cannot be read, so Claude Code reports a failed helper rather than connecting
without a token and getting a 401.

WHY: a card with --claude-mcp registers its service with Claude Code at user
scope (every folder). Claude Code keeps an MCP server's headers in
~/.claude.json, and the only way to put them there from a command is on the
command line - `claude mcp add --header "Authorization: Bearer ..."` - which
this family never does with a token. So the registration holds a
headersHelper instead, this script run by the service's own python, and the
token is read when Claude Code connects: from the same config and by the same
rules the service uses (seren_meninges: inline, env var or keyring). A rotated
token needs no re-registration.

The card copies this file into the service's app folder, so it outlives the
Starwright bundle it came from.
"""
from __future__ import annotations

import json
import sys


def main(argv: list[str]) -> int:
    if len(argv) != 1:
        print("usage: seren-mcp-headers.py <service config yaml>", file=sys.stderr)
        return 64
    try:
        # read_yaml is lenient - a missing or unreadable file is {} and a
        # service on defaults - which here would be a silent 401. Open it first.
        open(argv[0], encoding="utf-8").close()
        from seren_meninges.config import ServerConfig, read_yaml
        token = ServerConfig.from_dict((read_yaml(argv[0]) or {}).get("server")).resolve_bearer()
    except Exception as e:  # noqa: BLE001 - say why, and fail: no header is a 401 later
        print(f"seren-mcp-headers: cannot read the bearer from {argv[0]}: {type(e).__name__}: {e}", file=sys.stderr)
        return 1
    print(json.dumps({"Authorization": f"Bearer {token}"} if token else {}))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
