"""
seren-margin-bookmark.py - print Margin's bookmark, for a harness hook.

    <margin venv python> seren-margin-bookmark.py <margin config yaml>

Prints the bookmark's text - the dedication and how many letters wait - as a
session starts, so the model picks up where it left off instead of walking in
cold. A Claude Code SessionStart hook runs this (Starwright's Margin card,
--claude-bookmark); whatever it prints lands in the session.

It never blocks a session: Margin down, a bad config, a 401 - it prints one
short line saying so and exits 0. The bearer is read from Margin's own config
by Margin's own rules (seren_meninges: inline, env var or keyring), never
from a command line. The card copies this file into Margin's app folder, so it
outlives the Starwright bundle it came from. Standard library plus
seren_meninges, which the Margin venv has.
"""
from __future__ import annotations

import sys
import urllib.error
import urllib.request


def main(argv: list[str]) -> int:
    if len(argv) != 1:
        print("usage: seren-margin-bookmark.py <margin config yaml>", file=sys.stderr)
        return 0
    try:
        open(argv[0], encoding="utf-8").close()
        from seren_meninges.config import ServerConfig, read_yaml
        server = ServerConfig.from_dict((read_yaml(argv[0]) or {}).get("server"))
        host = server.host if server.host not in ("", "0.0.0.0", "::", None) else "127.0.0.1"
        port = server.port or 7421
        token = server.resolve_bearer()
    except Exception as e:  # noqa: BLE001 - never block the session
        print(f"(Margin's bookmark is unavailable: cannot read {argv[0]}: {type(e).__name__}: {e})")
        return 0
    req = urllib.request.Request(f"http://{host}:{port}/bookmark?format=text")
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    try:
        with urllib.request.urlopen(req, timeout=5) as r:
            body = r.read().decode("utf-8", "replace").rstrip()
    except urllib.error.HTTPError as e:
        print(f"(Margin's bookmark is unavailable: HTTP {e.code} from {host}:{port} - "
              f"{'an older Margin without /bookmark?' if e.code == 404 else 'check the bearer'})")
        return 0
    except Exception as e:  # noqa: BLE001
        print(f"(Margin's bookmark is unavailable: {host}:{port} did not answer: {e})")
        return 0
    print("Your bookmark, from Margin - picking up where you left off:\n")
    print(body)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
