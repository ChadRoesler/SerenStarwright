# Seren Starwright

The thing that builds the vessel that sails by the Lodestar.

A TUI installer for the Seren stack — pick what you want, watch it install.
Works over SSH on a headless node - Jetson, DGX Spark or a NUC - which is the whole point.

```bash
bash starwright.sh
```

```
powershell -ExecutionPolicy Bypass -File .\starwright.ps1
```

It bootstraps its own venv, so there's nothing to install first.

---

## What's in here

| Path | What |
| --- | --- |
| `starwright/` | the TUI |
| `services/` | per-service installers (memory, loci, margin, …) |
| `nodes/` | node preparation (Xavier / Orin Nano / DGX Spark) |
| `docs/` | design notes and plans |

Every script in `services/` and `nodes/` runs **standalone**. Starwright is a
front-end, not a gatekeeper — if you'd rather install one service by hand on a
box at 2am, do that:

```bash
bash services/bash/seren-memory-setup.sh --pypi --mcp --service
```

---

## One file, if you want it

```bash
bash build-starwright.sh        # -> dist/starwright.pyz  (~2.6MB)
```

A zipapp with Textual, Rich, **and every installer script** inside it. Copy that
one file to a bare machine with nothing but `python3` and run it:

```bash
python3 starwright.pyz
```

If there's a checkout nearby it uses those scripts (so your edits count). If
there isn't, it unpacks its bundled copy to `~/.seren-starwright/…` — a real,
printed, editable path, because the whole objection to bundling scripts into a
binary is losing the ability to read them when a box is misbehaving.

Needs a `python3` on the target. It does **not** bundle the interpreter, and
doesn't need to: every installer here already requires Python 3.10+, so a
machine without one can't install anything anyway.

---

## How Starwright knows what exists

There is **no service list in the TUI**. It runs `--describe` on every installer
it finds and builds the grid from the answers:

```console
$ bash services/bash/seren-memory-setup.sh --describe
{"schema_version":1,"name":"seren-memory","display":"Seren Memory",
 "description":"Episodic short, near, and long term memory","group":"brain",
 "accent":"#ff6e8a","default_port":7420,"extras":["corp","mcp"],
 "flags":["corp","host","mcp","port",...],"requires":[]}
```

Write a new `seren-symposium-setup.sh` that answers `--describe` and it appears
in the grid with **zero edits to Starwright**. That's deliberate: the previous
TUI carried a hardcoded table and it was wrong about `seren-margin`'s extras
within a day of them landing.

The same trick powers the rest of it — dependency resolution and install
ordering come from `requires`, the card colours come from `accent` (each taken
from that service's own web viewer, so the card you tick matches the UI you land
on), and the flag list is derived from the installer's own argument parser
rather than declared twice.

### The two contracts

| Flag | Promise |
| --- | --- |
| `--describe` | one line of JSON on stdout, exit 0, **zero side effects** — no venv, no network, no Python required |
| `--json` | JSON Lines events on stdout while installing; human log to stderr; exit code unchanged |

Both are opt-in and invisible unless asked for. Run any installer normally and
it behaves exactly as it always did.

---

## Node preparation

```bash
bash nodes/seren-prepare-node.sh --all          # detect platform, install everything
bash nodes/seren-prepare-node.sh -l -k -d       # llama + kokoro + chromadb
bash nodes/seren-prepare-node.sh --platform spark -l
```

Platform is auto-detected from `/etc/nv_tegra_release` (R35 → Xavier/jp5,
R36 → Orin Nano/jp6). The DGX Spark has no such file, so it's detected by other
signals — and since that detection is written from spec rather than from a
tested machine, **`--platform` overrides everything** and is the reliable path.

Foundation phases are state-tracked and skip when already done. Service phases
always re-run, on purpose: you asked for them, so "make sure it's there" beats
"skip work."

> Prepare Node is not yet wired into the TUI — see
> [`docs/PREPARE-NODE-PLAN.md`](docs/PREPARE-NODE-PLAN.md).

---

## Development

```bash
bash starwright.sh --selftest                                    # 46 checks
powershell -ExecutionPolicy Bypass -File .\verify-powershell.ps1  # PS checks
```

`test-starwright.py` drives the real TUI headless through Textual's pilot —
actual clicks, actual rendered geometry, no mocks. **Every test names the bug it
exists for**, and all of them shipped at least once.

`verify-powershell.ps1` checks parse, encoding, parameter shadowing, and the
`--describe` contract. Run it under `powershell.exe`, not `pwsh` — PowerShell 7
accepts syntax 5.1 rejects, so a pass under 7 proves nothing about 5.1.

### Two rules that are not style preferences

**`.sh` files must be LF.** CRLF in a shell script is a *parse error*, not a
tidiness issue. `.gitattributes` pins `*.sh text eol=lf`; `* text=auto` alone
does not, because it checks out native on Windows.

**`.ps1` files containing non-ASCII need a UTF-8 BOM.** Windows PowerShell 5.1
reads a BOM-less file as the ANSI codepage, and a multi-byte character inside a
quoted string terminates it early — the whole file fails to parse. Since the
banners here are full of box-drawing characters, this applies to nearly all of
them. `verify-powershell.ps1` catches it.

---

## License

GPL-3.0. Same as the rest of the Seren stack.

Rip it and win. 🌭🔧
