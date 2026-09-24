# Seren Starwright

The thing that builds the vessel that sails by the Lodestar.

A TUI installer for the Seren stack - pick what you want, watch it install.
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
| `SerenStarwright/seren_starwright/` | the TUI |
| `SerenStarwright/services/` | per-service installers (memory, loci, margin, …), bash and PowerShell |
| `SerenStarwright/nodes/` | node preparation (Xavier / Orin Nano / DGX Spark) |
| `SerenStarwright/verify-powershell.ps1`, `test-starwright.py` | the checks CI runs |

Every script in `services/` and `nodes/` runs **standalone**. Starwright is a
front-end, not a gatekeeper - if you'd rather install one service by hand on a
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
there isn't, it unpacks its bundled copy to `~/.seren-starwright/…` - a real,
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

The same trick powers the rest of it - dependency resolution and install
ordering come from `requires`, the card colours come from `accent` (each taken
from that service's own web viewer, so the card you tick matches the UI you land
on), and the flag list is derived from the installer's own argument parser
rather than declared twice.

### The two contracts

| Flag | Promise |
| --- | --- |
| `--describe` | one line of JSON on stdout, exit 0, **zero side effects** - no venv, no network, no Python required |
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
signals - and since that detection is written from spec rather than from a
tested machine, **`--platform` overrides everything** and is the reliable path.

### Base prep is opt-in

The slow, machine-wide part - OS trim, CUDA, NVMe, swap, power profile, and the
`sudoers.d` drop-in - is **base prep**, and it is separate from installing a
component:

```bash
bash nodes/seren-prepare-node.sh -l -k -d --rename xavier-brain --trim-os --wipe-nvme   # first build of a box
bash nodes/seren-prepare-node.sh -m                               # add Ms.MoE, touch nothing else
bash nodes/seren-prepare-node.sh --prep                           # re-run prep on its own
```

The two irreversible parts of prep are opt-in by flag: `--trim-os` (remove the
desktop, docker and snap) and `--wipe-nvme` (reformat an NVMe that is not
ext4). Without them prep skips the trim and stops on a non-ext4 disk. Prebuilt
artifacts come from the `SerenSystemPrebuilts` releases, tagged
`YYYYMMDD_<platform>` (`--tag 20260916_xavier-jp5` to pin one).

| | what happens |
| --- | --- |
| neither flag | prep runs **only** if this node has no record of ever being prepared |
| `--prep` | run it regardless |
| `--no-prep` | never run it, and say so loudly if the node has no prep record |

"Has this node been prepared" is read from state kept **on the machine**
(`~/.seren/node-state.json`), not from the checkout. It used to live in a
gitignored file next to the script, which meant it was absent from every fresh
clone and after every `.pyz` rebuild - so foundation re-ran in full and
`00_hostname` looked undone. Component phases still always re-run, on purpose:
you asked for them, so "make sure it's there" beats "skip work."

### Nothing renames your box unless you say so

**`--rename NAME` is the only thing that changes the hostname.** There used to be
no such flag: the name was *derived* from the service flags of that invocation,
so `-m` on a node called `xavier-llama-kokoro-chroma` computed `xavier-msmoe` and
applied it. Combined with the state file above, adding one component to a working
box renamed it.

`-H`/`--hostname` is now refused outright rather than silently ignored, so a
runbook still passing it fails loudly and tells you to use `--rename`.

### In the TUI: two doors, not one

The splash has **Install Node** and **Modify Node** where it used to have a
single "Prepare Node":

| | Install Node | Modify Node |
| --- | --- | --- |
| base prep | always runs | **not on the screen** |
| rename | optional field, blank = keep | **not on the screen** |
| components | yes | yes |
| emits | `--prep` (+ `--rename` if typed) | `--no-prep` |

Modify is greyed out on a node with no prep record, because Modify cannot create
one - the splash line tells you which state the node is in, so the choice is made
before any control is drawn.

That last part is the point. A mode picked *after* configuring still has to
render the dangerous widgets, and a checkbox left "rebuild the foundation of this
machine" one keystroke away from "add a component" on the same screen under the
same button. Modify cannot prep or rename because it has no control that says so.

---

## Development

```bash
bash starwright.sh --selftest                                    # the TUI suite
powershell -ExecutionPolicy Bypass -File .\verify-powershell.ps1  # PS checks
```

`test-starwright.py` drives the real TUI headless through Textual's pilot -
actual clicks, actual rendered geometry, no mocks. **Every test names the bug it
exists for**, and all of them shipped at least once.

`verify-powershell.ps1` checks parse, encoding, parameter shadowing, and the
`--describe` contract. Run it under `powershell.exe`, not `pwsh` - PowerShell 7
accepts syntax 5.1 rejects, so a pass under 7 proves nothing about 5.1.

### The quick dev loop

Every Seren checkout lives under one folder (`SerenCore/<Repo>/<Repo>/`).
`seren-dev-publish` builds all of them into one **dev wheelhouse** and every
card can install from it instead of a release:

```bash
bash seren-dev-publish.sh            # SerenCore/.dev-wheelhouse: one wheel per project,
                                     # starwright.pyz, SHA256SUMS, MANIFEST (git describe per wheel)
bash seren-dev-publish.sh --serve    # ...and serve it on :8765 for the nodes
.\seren-dev-publish.ps1 -Serve       # same thing from Windows

bash services/bash/seren-memory-setup.sh --local ../../.dev-wheelhouse     # a folder
bash services/bash/seren-memory-setup.sh --local http://devbox:8765        # over the LAN
```

In the TUI it is the *dev wheelhouse* field on the options screen; it beats a
release tag and PyPI. A card pointed at the house takes the newest wheel for
its own package and **pins every other `seren-*` wheel in the house** through a
pip constraints file, so a dev `seren-meninges` rides along with whichever
service you are testing. That pin is the whole trick: a dev build is a
pre-release (`2.4.1.dev3+g...`), which pip will not pick for a plain
`>=2.4.0` without `--pre`, and `--pre` would also drag in every third-party
release candidate on PyPI. An exact `==` on the dev version enables it for that
one package only.

Versions are whatever setuptools-scm says about the checkout - a dirty tree is
a `+d<date>` local version, a commit past the tag is a `.devN` - and nothing is
renamed to hide that. On a node, `starwright.pyz` from the served house plus
`--local http://devbox:8765` is the whole loop: pull, install, look, edit,
publish again.

### Two rules that are not style preferences

**`.sh` files must be LF.** CRLF in a shell script is a *parse error*, not a
tidiness issue. `.gitattributes` pins `*.sh text eol=lf`; `* text=auto` alone
does not, because it checks out native on Windows.

**`.ps1` files containing non-ASCII need a UTF-8 BOM.** Windows PowerShell 5.1
reads a BOM-less file as the ANSI codepage, and a multi-byte character inside a
quoted string terminates it early - the whole file fails to parse. Since the
banners here are full of box-drawing characters, this applies to nearly all of
them. `verify-powershell.ps1` catches it.

---

## License

GPL-3.0. Same as the rest of the Seren stack.

Rip it and win. 🌭🔧
