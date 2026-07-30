# SerenStarwright — repo layout proposal

For folding `SerenSetupScripts` + `SetupScripts` into one repo. Opinionated so
there's something to push back on.

---

## Lead with this: stop sniffing for the root

Starwright currently finds its scripts by walking up looking for a directory
named `Bash/` or `Powershell/`. That has already broken twice tonight — once
inside a zipapp (where `__file__` is the archive), once on a box with no
checkout — and **a reorg breaks it a third time by definition**, because the
directory names are the thing you're about to change.

Fix it before the move, not after:

```
SerenStarwright/
└── .starwright-root        # empty marker file, or a tiny TOML
```

Root resolution becomes: `$SEREN_STARWRIGHT_ROOT` → walk up for
`.starwright-root` → bundled copy in the `.pyz`. Directory names become free to
change without touching discovery code.

If it holds content, the useful content is *where things are*:

```toml
services = "services"
nodes    = "nodes"
```

which means the layout below is a decision the repo states about itself,
instead of a convention Starwright has memorised.

---

## Proposed tree

```
SerenStarwright/
├── .starwright-root
├── .gitattributes              # *.sh eol=lf  — carry this over, see below
├── README.md
├── LICENSE
│
├── starwright.sh               # launcher (bootstraps venv, runs TUI)
├── starwright.ps1
├── build-starwright.sh         # bundles deps + scripts into one .pyz
├── build-starwright.ps1
├── verify-powershell.ps1       # PS parse/encoding/shadowing/describe checks
├── test-starwright.py          # 46-check TUI regression suite
│
├── starwright/                 # the TUI itself
│   └── __main__.py             # (single file for now — see "package or file")
│
├── services/                   # was SerenSetupScripts
│   ├── bash/
│   │   ├── seren-memory-setup.sh
│   │   └── …
│   ├── powershell/
│   │   └── …
│   └── lib/
│       ├── seren-install-lib.sh
│       ├── seren-install-lib.ps1
│       ├── setup-seren-service.sh
│       ├── setup-seren-service.ps1
│       └── setup-seren-dotnet-service.{sh,ps1}
│
├── nodes/                      # was SetupScripts
│   ├── seren-prepare-node.sh   # was seren-setup.sh — RENAME, see below
│   ├── lib/
│   │   └── common.sh
│   ├── xavier/
│   ├── nano/
│   └── spark/
│
└── docs/
    ├── PREPARE-NODE-PLAN.md
    └── CONTRACTS.md            # --describe / --json, in one place
```

---

## Rename `seren-setup.sh`

`nodes/seren-setup.sh` and `services/bash/seren-memory-setup.sh` are one word
apart and do entirely different things — one prepares a machine, the other
installs a package. In a repo that now contains both, that's a trap.

**`seren-prepare-node.sh`.** Matches the button in the TUI, matches the doc,
and can't be confused with a `seren-<x>-setup.sh`.

---

## The case-rename trap (do this carefully)

`Bash/` → `bash/` and `Powershell/` → `powershell/` are **case-only renames**,
and Windows filesystems are case-insensitive. Git on Windows will frequently
either miss the change entirely or record something odd, and you find out when
a Linux clone has both `Bash/` and `bash/`.

Two-step it, per directory:

```bash
git mv Bash bash-tmp && git commit -m "rename step 1"
git mv bash-tmp bash && git commit -m "rename step 2"
```

Or just keep the capitals. Honestly `Bash/` and `Powershell/` are fine and this
is a real hazard for zero functional gain — **my recommendation is keep the
existing case** and only rename the things whose *names* are wrong
(`seren-setup.sh`), not the ones whose capitalisation is merely unfashionable.

---

## One shared contract lib, eventually

Both halves will speak `--describe` and `--json`. Right now that machinery
(`_json_esc`, `emit`, `seren_describe`, `seren_flags_from_self`) lives in
`services/lib/seren-install-lib.sh`, and `nodes/lib/common.sh` has its own
`_seren_json_escape` that does the same job.

Two JSON escapers in one repo is the duplicate-source-of-truth shape we've now
killed three times tonight in different costumes.

**Suggested:** `lib/seren-contract.sh` at the top level, sourced by both. Just
the contract — escaping, `emit`, `--describe` rendering. Leave the
install-specific and node-specific helpers where they are; they genuinely
differ.

**Do this AFTER the move, not during.** Moving files and refactoring their
contents in one commit makes the diff unreviewable and a bisect useless.

---

## Package or single file for the TUI

`seren-starwright.py` is ~950 lines. Both options work:

- **Single file** — trivial to bundle, readable end to end, and the whole thing
  fits in one review. What's there now.
- **Package** (`starwright/{__main__,discovery,screens/…}.py`) — better once
  Prepare Node lands, since that's another two screens and a second discovery
  path. zipapp handles packages fine.

**Recommend: single file until Prepare Node ships, then split.** The split is
mechanical and the current file isn't yet painful. Splitting now means doing it
before you know what the second discovery path actually needs.

---

## Carry `.gitattributes` over — it's load-bearing

```
*.sh    text eol=lf
*.bash  text eol=lf
```

Not cosmetic. CRLF in a `.sh` is a **parse error**, and tonight nine scripts —
every service installer plus the shared lib — were unrunnable in the Windows
working tree for exactly this reason. `* text=auto` alone does *not* prevent it,
because it checks out native on Windows.

A fresh repo starts without this file. Add it in the first commit, before any
`.sh` lands.

Same category: every `.ps1` containing non-ASCII needs a **UTF-8 BOM**, or
Windows PowerShell 5.1 reads it as the ANSI codepage and a multi-byte character
inside a string terminates it early. `verify-powershell.ps1` checks for this;
keep running it.

---

## History

Three options, in ascending effort:

1. **Fresh start.** New repo, copy files, one initial commit. History for the
   old repos stays in the old repos, which still exist.
2. **`git subtree add`** for each, preserving both histories under their
   prefixes. Easy, and `git log` works.
3. **`git filter-repo`** to rewrite paths, then merge. Cleanest single history,
   most effort, and rewrites public repo history.

**Recommend 2** if the history matters to you, **1** if it doesn't. Not 3 — the
prize isn't worth rewriting two public repos.

---

## What has to change in Starwright

Small, and mostly the thing from the top:

- `_find_base_dir()` → look for `.starwright-root`, not `Bash/`
- `_installer_paths()` → `services/bash` / `services/powershell`
- `build-starwright.{sh,ps1}` → bundle `services/` **and** `nodes/`
- `test-starwright.py` → path updates only; every assertion still holds

The `--describe` / `--json` contracts don't move at all. Which is the point —
the installers describe themselves, so relocating them is a path change and
nothing more.

---

## Open

- Does `SerenSetupScripts` stay alive as a redirect/archive, or get archived on
  GitHub? Anyone who cloned it has stale paths either way.
- `seren-wipe.sh` and `seren-sudoers-update.sh` — `nodes/` or a `tools/` dir?
  They're neither prep modules nor installers.
- Does the `.pyz` get published as a GitHub release artifact? If so,
  `build-starwright.sh` wants to run in CI, which means the pure-Python guard
  becomes a build gate rather than a local nicety.
