"""
seren-keep-config.py - carry forward what a card does not write.

    python seren-keep-config.py <config.yaml>

WHY: every card writes its config whole, from its own template, on every
install. Anything the operator added by hand - a hippocampus's
model.lifecycle block, a sleep.at time, a notify webhook, a callosum knob -
was silently dropped on the next reinstall (seen live 25 Sept 2026: the
hippocampus reinstalled and its lifecycle block was gone, so it never started
its model). The card already backs the old file up as <config>.bak.<epoch>
before writing; this reads that backup and puts back, VERBATIM:

  - every top-level block the new file does not have, and
  - every key under a block the new file has, that the new block lacks
    (with everything nested beneath it).

What the card wrote always wins; this only restores what it did not write.
Two levels deep, text in and text out - comments, quoting and order of the
restored lines are kept exactly. No yaml parser needed. Standard library only.

Only a backup made in the last hour counts: a fresh install next to an old
leftover .bak must not resurrect settings from some other life.
"""
from __future__ import annotations

import re
import sys
import time
from pathlib import Path

RECENT_SECONDS = 3600
TOP = re.compile(r"^([A-Za-z_][\w-]*):(\s.*)?$")
SECOND = re.compile(r"^  ([A-Za-z_][\w-]*):(\s.*)?$")


def _blocks(lines: list[str]) -> dict[str, tuple[int, int]]:
    """top-level key -> (start, end) line range, end exclusive; a block runs
    until the next top-level key. Blank lines and comments between blocks
    belong to the block above."""
    starts = [(i, m.group(1)) for i, l in enumerate(lines) if (m := TOP.match(l))]
    out: dict[str, tuple[int, int]] = {}
    for n, (i, key) in enumerate(starts):
        end = starts[n + 1][0] if n + 1 < len(starts) else len(lines)
        out.setdefault(key, (i, end))
    return out


def _children(lines: list[str], start: int, end: int) -> dict[str, tuple[int, int]]:
    """second-level key -> (start, end) within a block: the key's line and
    every following line indented deeper than two spaces (its subtree)."""
    out: dict[str, tuple[int, int]] = {}
    i = start + 1
    while i < end:
        m = SECOND.match(lines[i])
        if m:
            j = i + 1
            while j < end and (lines[j].startswith("   ") or (lines[j].startswith("  - "))):
                j += 1
            out.setdefault(m.group(1), (i, j))
            i = j
        else:
            i += 1
    return out


def merge(new_text: str, old_text: str) -> tuple[str, list[str]]:
    nl = "\r\n" if "\r\n" in new_text else "\n"
    new = new_text.replace("\r\n", "\n").split("\n")
    old = old_text.replace("\r\n", "\n").split("\n")
    restored: list[str] = []
    nb, ob = _blocks(new), _blocks(old)

    # keys missing inside blocks both files have: insert at the end of the
    # new block's own lines (before trailing blanks), in the old order
    inserts: list[tuple[int, list[str]]] = []
    for key, (ns, ne) in nb.items():
        if key not in ob:
            continue
        os_, oe = ob[key]
        have = _children(new, ns, ne)
        at = ne
        while at > ns + 1 and not new[at - 1].strip():
            at -= 1
        lines: list[str] = []
        for child, (cs, ce) in _children(old, os_, oe).items():
            if child not in have:
                lines.extend(old[cs:ce])
                restored.append(f"{key}.{child}")
        if lines:
            inserts.append((at, lines))
    for at, lines in sorted(inserts, reverse=True):
        new[at:at] = lines

    # whole blocks the new file does not have: appended, in the old order
    tail: list[str] = []
    for key, (os_, oe) in ob.items():
        if key not in nb:
            block = old[os_:oe]
            while block and not block[-1].strip():
                block.pop()
            tail.extend([""] + block)
            restored.append(key)
    if tail:
        while new and not new[-1].strip():
            new.pop()
        new.extend(tail + [""])
    return nl.join(new), restored


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print("usage: seren-keep-config.py <config.yaml>", file=sys.stderr)
        return 2
    cfg = Path(argv[1])
    if not cfg.is_file():
        return 0
    baks = sorted(cfg.parent.glob(cfg.name + ".bak.*"), key=lambda p: p.stat().st_mtime, reverse=True)
    baks = [b for b in baks if time.time() - b.stat().st_mtime < RECENT_SECONDS]
    if not baks:
        return 0
    raw = cfg.read_bytes()
    bom = raw.startswith(b"\xef\xbb\xbf")
    text = raw.decode("utf-8-sig")
    merged, restored = merge(text, baks[0].read_bytes().decode("utf-8-sig", errors="replace"))
    if restored:
        cfg.write_bytes((b"\xef\xbb\xbf" if bom else b"") + merged.encode("utf-8"))
        print("kept from the previous config: " + ", ".join(restored))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
