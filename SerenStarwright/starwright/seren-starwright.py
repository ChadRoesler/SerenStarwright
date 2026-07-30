#!/usr/bin/env python3
"""
Seren Starwright - the TUI that builds the vessel.
═══════════════════════════════════════════════════════════════════════════

Front-end for the seren-*-setup installers. Knows NOTHING about how to
install anything: it discovers services by running `--describe` on whatever
installers exist, and drives them via `--json`, reading the JSON Lines event
stream they emit.

That's the whole design. There is no hardcoded service table here, on
purpose - the previous TUI had one and it was wrong about seren-margin's
extras within a day of --mcp landing. Write a new seren-symposium-setup.sh
and it appears in this grid with zero edits to this file.

    stdout of an installer  =  JSON Lines events, or empty
    stderr of an installer  =  human log, straight into the log pane
    exit code               =  means what it always did

USAGE
    python3 seren-starwright.py            # auto-detect platform
    python3 seren-starwright.py --dump     # print discovered services, exit
                                           # (no TUI - handy over a bad pipe)

REQUIRES
    textual  (pip install textual)
"""
from __future__ import annotations

import asyncio
import json
import os
import platform
import subprocess
import sys
import tempfile
import zipfile
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Optional

# ── version ────────────────────────────────────────────────────────────────
# Resolved and answered BEFORE the textual import, deliberately. A diagnostic
# flag has to work on the machine that's having the problem - including one
# where the dependency is missing, which is exactly when someone is asking
# "what version is this" in the first place.
VERSION_STAMP = "_starwright_version.txt"


def _bundled_archive() -> "Optional[Path]":                  # noqa: F821
    """The .pyz we're running from, or None. Duplicated in miniature above the
    textual import so --version needs nothing but stdlib."""
    try:
        p = Path(__file__).resolve()
    except Exception:                                        # noqa: BLE001
        return None
    for cand in [p.parent, *p.parents]:
        if cand.is_file() and zipfile.is_zipfile(cand):
            return cand
    return None


def resolve_version() -> str:
    """Build-time stamp first, then git, then honest ignorance.

    The stamp is what matters: once a .pyz is sitting on a Jetson there is no
    repo to interrogate, and "which build is that" is unanswerable without it.
    Falling back to git keeps a working checkout self-describing too.
    """
    archive = _bundled_archive()
    if archive is not None:
        try:
            with zipfile.ZipFile(archive) as z:
                return z.read(VERSION_STAMP).decode("utf-8").strip() or "unknown"
        except Exception:                                    # noqa: BLE001
            pass
    try:
        here = Path(__file__).resolve().parent
        out = subprocess.run(
            ["git", "describe", "--tags", "--always", "--dirty"],
            cwd=here, capture_output=True, text=True, timeout=5)
        if out.returncode == 0 and out.stdout.strip():
            return out.stdout.strip() + " (from git)"
    except Exception:                                        # noqa: BLE001
        pass
    return "unknown (no build stamp, not a git checkout)"


if "--version" in sys.argv or "-V" in sys.argv:
    print(f"seren-starwright {resolve_version()}")
    raise SystemExit(0)


try:
    from rich.text import Text
    from textual.app import App, ComposeResult
    from textual.containers import (Horizontal, Vertical, VerticalScroll, Center)
    from textual.screen import ModalScreen, Screen
    from textual.widgets import (Button, Checkbox, Footer, Header, Input, Label,
                                 ProgressBar, RadioButton, RadioSet, RichLog,
                                 Rule, Static)
except ImportError:
    sys.exit("ERROR: textual is required.  pip install textual")


IS_WINDOWS = platform.system() == "Windows"


# Directory inside the .pyz holding a copy of the installers. Written by
# build-starwright.{sh,ps1}; absent from a plain source checkout.
BUNDLE_DIR = "_seren_scripts"
BUNDLE_HOME = Path.home() / ".seren-starwright"

# The marker that declares a checkout root. Everything below keys off this
# rather than off directory names - see .starwright-root for the full why.
ROOT_MARKER = ".starwright-root"
DEFAULT_LAYOUT = {"services": "services", "nodes": "nodes"}


def _read_layout(root: Path) -> dict[str, str]:
    """Parse .starwright-root - `key = value` lines, # comments.

    Deliberately a dumb hand-rolled reader rather than tomllib/toml: this has
    to work on a fresh Jetson before anything is installed, and the file is
    four lines of paths. A dependency here would be absurd.
    """
    layout = dict(DEFAULT_LAYOUT)
    try:
        for line in (root / ROOT_MARKER).read_text(encoding="utf-8").splitlines():
            line = line.split("#", 1)[0].strip()
            if "=" not in line:
                continue
            k, v = line.split("=", 1)
            k, v = k.strip(), v.strip().strip('"').strip("'")
            if k and v:
                layout[k] = v
    except Exception:                                        # noqa: BLE001
        pass
    return layout


def _archive_path() -> Optional[Path]:
    """Return the .pyz we're running from, or None if running from source.

    Inside a zipapp __file__ is "<archive>.pyz/__main__.py", so walking up
    from it hits the archive as a FILE. is_zipfile confirms it rather than
    guessing from the extension.
    """
    try:
        p = Path(__file__).resolve()
    except Exception:                                        # noqa: BLE001
        return None
    for cand in [p.parent, *p.parents]:
        if cand.is_file() and zipfile.is_zipfile(cand):
            return cand
    return None


def _extract_bundled(archive: Path) -> Optional[Path]:
    """Unpack the bundled installers out of the archive, once, and return the
    directory holding Bash/ + Powershell/.

    Extracted to a REAL, STABLE, INSPECTABLE path (~/.seren-starwright/...)
    rather than a scratch temp dir. That's deliberate: the whole reservation
    about bundling scripts into a binary is that you lose the ability to read
    and patch them when something is weird on a box at 2am. This way you
    don't - the path is printed at startup and the scripts are right there.

    The cache key is the archive's mtime+size, so rebuilding the .pyz gets a
    fresh extraction instead of silently running yesterday's scripts. A
    .complete marker means a half-finished extraction (disk full, Ctrl-C) is
    retried rather than trusted.
    """
    try:
        with zipfile.ZipFile(archive) as z:
            names = [n for n in z.namelist() if n.startswith(BUNDLE_DIR + "/")]
            if not names:
                return None
            st = archive.stat()
            dest = BUNDLE_HOME / f"{archive.stem}-{st.st_mtime_ns:x}-{st.st_size:x}"
            marker = dest / ".complete"
            if not marker.exists():
                dest.mkdir(parents=True, exist_ok=True)
                z.extractall(dest, members=names)
                marker.write_text("ok\n", encoding="utf-8")
            root = dest / BUNDLE_DIR
            return root if root.is_dir() else None
    except Exception:                                        # noqa: BLE001
        return None


def _find_base_dir() -> Path:
    """Locate the SerenSetupScripts root - the dir holding Bash/ + Powershell/.

    Cannot just be Path(__file__).parent.parent: inside a zipapp __file__ is
    "<archive>.pyz/__main__.py", so .parent is the ARCHIVE FILE. Globbing in it
    finds nothing and you get an installer that discovers zero services with no
    error to explain it.

    Resolution order, most specific first:
      1. $SEREN_STARWRIGHT_ROOT       - explicit operator override
      2. a real checkout on disk      - walk up for .starwright-root
      3. scripts bundled in the .pyz  - extracted to ~/.seren-starwright

    ON-DISK BEATS BUNDLED, deliberately. If you're sitting in a checkout you
    want the scripts you can edit, not a frozen copy from whenever the archive
    was built. The bundle is the fallback for "I curled one file onto a fresh
    box", which is the only case where there's nothing to prefer.

    Looks for the MARKER FILE, not for directory names. Sniffing for "Bash/"
    broke inside the zipapp, broke on a bare box, and would have broken again
    the moment those directories were renamed to services/bash - which is
    exactly what happened. The marker survives any reshuffle.
    """
    env = os.environ.get("SEREN_STARWRIGHT_ROOT")
    if env:
        return Path(env).expanduser().resolve()

    def has_installers(d: Path) -> bool:
        return (d / ROOT_MARKER).is_file()

    starts = []
    try:
        starts.append(Path(__file__).resolve().parent)
    except Exception:                                        # noqa: BLE001
        pass
    if sys.argv and sys.argv[0]:
        starts.append(Path(sys.argv[0]).resolve().parent)
    starts.append(Path.cwd())

    for start in starts:
        for cand in [start, *start.parents]:
            if has_installers(cand):
                return cand

    archive = _archive_path()
    if archive:
        bundled = _extract_bundled(archive)
        if bundled:
            return bundled

    return starts[0] if starts else Path.cwd()


BASE_DIR = _find_base_dir()
IS_BUNDLED = BUNDLE_DIR in BASE_DIR.parts
LAYOUT = _read_layout(BASE_DIR)
SERVICES_DIR = BASE_DIR / LAYOUT.get("services", "services")
NODES_DIR = BASE_DIR / LAYOUT.get("nodes", "nodes")

# Group keys come from --describe; the display names live HERE rather than
# being repeated in each service's describe output. Three services all
# declaring "Seren Brain System" is the duplicate-source-of-truth shape we
# keep having to kill.
#
# This list controls ORDER and PRETTY NAMES ONLY - it is NOT an allowlist.
# See _ordered_groups: a service declaring a group nobody has heard of still
# gets rendered, under its own heading. Dropping it would be worse than ugly,
# it would be invisible: seren-probe shipped with group "infra" and simply did
# not appear, which looks exactly like "that installer doesn't exist yet".
GROUPS: list[tuple[str, str]] = [
    ("brain",     "Seren Brain System"),
    ("core",      "Seren Core Tool System"),
    ("auxiliary", "Seren Auxillary"),
]


def _ordered_groups(services: list["ServiceDef"]) -> list[tuple[str, str]]:
    """Known groups in their curated order, then any unknown ones, so that
    EVERY discovered service lands on screen somewhere."""
    out = list(GROUPS)
    seen = {k for k, _ in out}
    for s in services:
        if s.group not in seen:
            seen.add(s.group)
            pretty = s.group.replace("-", " ").replace("_", " ").title()
            out.append((s.group, f"Seren {pretty}"))
    return out

# Flags that describe the MACHINE or the RUN, not the service. Setting --corp
# per-service is meaningless: if the box is behind an intercepting proxy it's
# behind it for all of them. Same for where packages come from.
UNIVERSAL_FLAGS = {"corp", "pypi", "ref", "repo", "wheel", "venv"}

# Shown as inline checkboxes on the config row rather than buried in Advanced.
INLINE_FLAGS = ["mcp", "vector", "service"]


# ═══════════════════════════════════════════════════════════════════════
#  Discovery
# ═══════════════════════════════════════════════════════════════════════
@dataclass
class ServiceDef:
    name: str
    display: str
    description: str
    group: str
    package: str
    default_host: str
    default_port: int
    accent: str = ""            # hex colour, taken from the service's own viewer
    extras: list[str] = field(default_factory=list)
    flags: list[str] = field(default_factory=list)
    requires: list[str] = field(default_factory=list)
    params: dict[str, str] = field(default_factory=dict)   # canonical -> native (ps only)
    script: Path = Path()

    @property
    def advanced_flags(self) -> list[str]:
        """Everything that isn't universal, inline, or plumbing."""
        skip = UNIVERSAL_FLAGS | set(INLINE_FLAGS) | {"describe", "json", "help"}
        return [f for f in self.flags if f not in skip]


@dataclass
class NodeComponent:
    name: str
    display: str
    description: str
    available: bool = True
    hardware_gated: bool = False
    always_reinstalls: bool = True


@dataclass
class NodeDef:
    """One machine's prep picture, from `seren-prepare-node.sh --describe`.

    Note this describes the WHOLE node in one object rather than one per
    component - prep components are sourced into the dispatcher, not executed,
    so there is nothing to describe individually. They're facets of one machine.
    """
    platform: Optional[str]
    jp_family: Optional[str]
    cuda_arch: Optional[str]
    hostname: str
    components: list[NodeComponent] = field(default_factory=list)
    modes: list[str] = field(default_factory=lambda: ["prebuilts", "build"])
    platforms: list[str] = field(default_factory=list)
    # Derived from the dispatcher's own case branches. The screen renders an
    # option ONLY if it appears here, so it can never offer a flag the script
    # doesn't take - and a flag added to the script surfaces with no UI edit.
    flags: list[str] = field(default_factory=list)
    script: Path = Path()

    def supports(self, flag: str) -> bool:
        return flag in self.flags


@dataclass
class Job:
    """One thing to run on the install screen.

    events_file is the whole reason this exists. Service installers put their
    JSON on stdout (--json); node prep cannot, because it redirects stdout AND
    stderr into its tee'd log file, so it writes to a file instead (--events).
    One screen runs both by knowing which to read.
    """
    label: str
    cmd: list[str]
    events_file: Optional[Path] = None


def _installer_dir() -> Path:
    return SERVICES_DIR / ("powershell" if IS_WINDOWS else "bash")


def _node_script() -> Path:
    return NODES_DIR / "seren-prepare-node.sh"


def discover_node(platform_override: Optional[str] = None
                  ) -> tuple[Optional[NodeDef], Optional[str]]:
    """Ask the node what it is. Returns (node, problem).

    platform_override re-asks as if we were on that platform, which is what
    makes the "couldn't detect - pick one" path actually work: the component
    list depends on which platform's modules exist (spark has no coral.sh),
    so choosing a platform has to re-query rather than just remember a string.
    """
    script = _node_script()
    if not script.is_file():
        return None, f"no node installer at {script}"
    if IS_WINDOWS:
        # Node prep is Jetson/Spark work - bash only, and Windows is never one.
        return None, "node preparation is not available on Windows"
    cmd = ["bash", str(script), "--describe"]
    if platform_override:
        cmd += ["--platform", platform_override]
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
        out = (proc.stdout or "").strip()
        if not out:
            err = (proc.stderr or "").strip().splitlines()
            return None, ("--describe produced no output"
                          + (f" | {err[0][:110]}" if err else ""))
        d = json.loads(out.splitlines()[-1])
        comps = [NodeComponent(
            name=c["name"], display=c.get("display", c["name"]),
            description=c.get("description", ""),
            available=bool(c.get("available", True)),
            hardware_gated=bool(c.get("hardware_gated", False)),
            always_reinstalls=bool(c.get("always_reinstalls", True)))
            for c in d.get("components", [])]
        return NodeDef(
            platform=d.get("platform"), jp_family=d.get("jp_family"),
            cuda_arch=d.get("cuda_arch"), hostname=d.get("hostname", ""),
            components=comps, modes=list(d.get("modes", ["prebuilts", "build"])),
            platforms=list(d.get("platforms", [])),
            flags=list(d.get("flags", [])), script=script), None
    except Exception as e:                                   # noqa: BLE001
        return None, f"{script.name}: {e}"


def sudo_ready() -> bool:
    """Can we sudo without a prompt?

    Prep is apt-get, nvpmodel, hostname and sudoers edits. A password prompt
    fired mid-run goes to a terminal the TUI has taken over, which reads as a
    silent hang. So it is checked up front and never during.
    """
    try:
        return subprocess.run(["sudo", "-n", "true"],
                              capture_output=True, timeout=5).returncode == 0
    except Exception:                                        # noqa: BLE001
        return False


def _installer_paths() -> list[Path]:
    d = _installer_dir()
    if IS_WINDOWS:
        return sorted(d.glob("seren-*-setup.ps1"))
    return sorted(d.glob("seren-*-setup.sh"))


def _describe_cmd(script: Path) -> list[str]:
    if IS_WINDOWS:
        return ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass",
                "-File", str(script), "-Describe"]
    return ["bash", str(script), "--describe"]


def discover() -> tuple[list[ServiceDef], list[str]]:
    """Run --describe on every installer. Returns (services, problems).

    A script that fails to describe is REPORTED, never silently dropped - a
    missing card is indistinguishable from a service that doesn't exist, and
    that's exactly the class of silent wrongness this contract replaced.
    """
    services: list[ServiceDef] = []
    problems: list[str] = []
    for script in _installer_paths():
        try:
            proc = subprocess.run(_describe_cmd(script), capture_output=True,
                                  text=True, timeout=30)
            out = (proc.stdout or "").strip()
            if not out:
                # Say WHICH flag, and hand back whatever the script put on
                # stderr. "produced no output" with no reason is the same
                # unhelpful silence this whole contract exists to replace.
                flag = "-Describe" if IS_WINDOWS else "--describe"
                err = (proc.stderr or "").strip().splitlines()
                detail = f" | stderr: {err[0][:120]}" if err else " (nothing on stderr either)"
                problems.append(f"{script.name}: {flag} produced no output{detail}")
                continue
            d = json.loads(out.splitlines()[-1])
            services.append(ServiceDef(
                name=d["name"], display=d.get("display", d["name"]),
                description=d.get("description", ""), group=d.get("group", "core"),
                package=d.get("package", d["name"]),
                default_host=d.get("default_host", "127.0.0.1"),
                default_port=int(d.get("default_port", 0)),
                accent=str(d.get("accent", "") or ""),
                extras=list(d.get("extras", [])), flags=list(d.get("flags", [])),
                requires=list(d.get("requires", [])),
                params=dict(d.get("params", {})), script=script))
        except json.JSONDecodeError as e:
            problems.append(f"{script.name}: bad JSON from --describe ({e})")
        except subprocess.TimeoutExpired:
            problems.append(f"{script.name}: --describe timed out (should be instant)")
        except Exception as e:                                   # noqa: BLE001
            problems.append(f"{script.name}: {e}")
    return services, problems


def resolve_dependencies(selected: set[str], svcs: dict[str, ServiceDef]) -> set[str]:
    """Transitively pull in whatever the selection requires."""
    out, stack = set(selected), list(selected)
    while stack:
        cur = svcs.get(stack.pop())
        if not cur:
            continue
        for dep in cur.requires:
            if dep in svcs and dep not in out:
                out.add(dep)
                stack.append(dep)
    return out


def install_order(selected: set[str], svcs: dict[str, ServiceDef]) -> list[str]:
    """Topological sort so dependencies install first.

    Sequential installs make ordering free - you only have to know it. Falls
    back to a stable alphabetical tail if a cycle ever appears, because
    refusing to install is a worse answer than installing in a mediocre order.
    """
    ordered: list[str] = []
    remaining = set(selected)
    while remaining:
        ready = sorted(n for n in remaining
                       if not (set(svcs[n].requires) & remaining))
        if not ready:                       # cycle - break it, don't hang
            ready = [sorted(remaining)[0]]
        ordered.extend(ready)
        remaining -= set(ready)
    return ordered


def port_conflicts(selected: list[str], svcs: dict[str, ServiceDef],
                   overrides: dict[str, dict]) -> list[str]:
    """Catch two services landing on one port BEFORE anything is installed.

    Starwright is the only thing that can see this: each installer knows only
    its own port and can't warn about a neighbour it never hears about.
    """
    seen: dict[int, str] = {}
    out: list[str] = []
    for n in selected:
        port = int(overrides.get(n, {}).get("port") or svcs[n].default_port)
        if port in seen:
            out.append(f"port {port}: {seen[port]} and {n} collide")
        else:
            seen[port] = n
    return out


def build_command(svc: ServiceDef, cfg: dict, universal: dict) -> list[str]:
    """Turn the collected config into a real command line.

    Canonical flag names in; platform-native out. On PowerShell the `params`
    map from --describe supplies the real parameter name, which matters
    because every installer picked a different one to dodge $Host
    (MarginHost, LociHost, ObsHost...).
    """
    merged: dict[str, Any] = {}
    for k, v in universal.items():
        if k in svc.flags and v not in (None, "", False):
            merged[k] = v
    for k, v in cfg.items():
        if k in svc.flags and v not in (None, "", False):
            merged[k] = v

    if IS_WINDOWS:
        cmd = ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass",
               "-File", str(svc.script), "-Json"]
        for k, v in merged.items():
            native = svc.params.get(k)
            if not native:
                continue
            cmd.append(f"-{native}")
            if v is not True:
                cmd.append(str(v))
        return cmd

    cmd = ["bash", str(svc.script), "--json"]
    for k, v in merged.items():
        cmd.append(f"--{k}")
        if v is not True:
            cmd.append(str(v))
    return cmd


# ═══════════════════════════════════════════════════════════════════════
#  Screens
# ═══════════════════════════════════════════════════════════════════════
BANNER = r"""
╓─────┐ ╥──┐ ╥──┐ ╥──┐ ╓──┐      ╓─────┐ ╓─╥─┐ ╓──┐ ╥──┐ ╥ ╥ ┬ ╥──┐ ─╥─ ╓──┐ ╥  ┬ ╓─╥─┐
║       ╟─   ╟─┬┘ ╟─   ║  │      ║         ║   ╟──┤ ╟─┬┘ ║ ║ │ ╟─┬┘  ║  ║ ─┐ ╟──┤   ║  
╙─────┐ ╨──┘ ╨ ┴  ╨──┘ ╨  ┴      ╙─────┐   ╨   ╨  ┴ ╨ ┴  ╙─╨─┘ ╨ ┴  ─╨─ ╙──┘ ╨  ┴   ╨  
      │                                │                                             
╙─────┘                          ╙─────┘                                             
"""

BANNER_NARROW = r"""
 ___ ___ ___ ___ _  _
|_ _/ __| _ \ __| \| |  S H I P W R I G H T
 _\ \__ \   / _|| .` |
|___/___/_|_\___|_|\_|
"""


class SplashScreen(Screen):
    """Mode selector. Prepare Node and Install Services share almost no config
    surface, so they get separate doors rather than one overloaded grid."""

    def compose(self) -> ComposeResult:
        yield Header()
        with Center():
            with Vertical(id="splash"):
                yield Static(BANNER, id="banner")
                yield Static("build the vessel · sail by the lodestar",
                             id="tagline")
                yield Button("Prepare Node", id="prep", variant="default")
                yield Button("Install Services", id="install", variant="primary")
                yield Button("Exit", id="exit", variant="error")
                yield Static("", id="splash-note")
        yield Footer()

    def on_mount(self) -> None:
        # Honest about what isn't built: there are no node-prep scripts in this
        # repo yet, so the button says so instead of failing when pressed.
        self.query_one("#prep", Button).disabled = (
            self.app.node is None)          # type: ignore[attr-defined]
        n = len(self.app.services)                      # type: ignore[attr-defined]
        # First token only. resolve_version() appends an explanatory tail
        # ("(from git)", "(no build stamp, not a git checkout)") which is right
        # for --version and far too long for a splash line. No "v" prefix -
        # tags already carry one and "vunknown" reads like a typo.
        note = f"{resolve_version().split(' ')[0]}  ·  {n} installer(s) discovered"
        if self.app.problems:                           # type: ignore[attr-defined]
            note += f" · {len(self.app.problems)} problem(s) - see Install"
        self.query_one("#splash-note", Static).update(note)

        # The wide banner is 85 columns. Narrower than that it doesn't clip
        # gracefully - it loses its right-hand end mid-letter - so a small
        # terminal gets a compact wordmark instead of mangled art.
        if self.app.size.width < 90:
            self.query_one("#banner", Static).update(BANNER_NARROW)

    def on_button_pressed(self, event: Button.Pressed) -> None:
        if event.button.id == "install":
            self.app.push_screen(SelectScreen())
        elif event.button.id == "prep":
            self.app.push_screen(PrepareNodeScreen())
        elif event.button.id == "exit":
            self.app.exit()


class ServiceCard(Vertical):
    """One selectable service. Checkbox + description, as drawn."""

    def __init__(self, svc: ServiceDef) -> None:
        super().__init__(classes="card")
        self.svc = svc

    def compose(self) -> ComposeResult:
        cb = Checkbox(self.svc.display, id=f"svc-{self.svc.name}")
        # Tint the title with the service's OWN viewer accent, so the card you
        # tick here is the colour of the UI you land on afterwards. Set inline
        # rather than in CSS because the value arrives at runtime from
        # --describe; there's no stylesheet that could know it.
        if self.svc.accent:
            cb.styles.color = self.svc.accent
            self.styles.border = ("round", self.svc.accent)
        yield cb
        yield Static(self.svc.description, classes="card-desc")
        if self.svc.requires:
            yield Static("needs " + ", ".join(r.replace("seren-", "")
                                              for r in self.svc.requires),
                         classes="card-req")


class SelectScreen(Screen):
    """The grid. Groups with a parent checkbox that toggles its children."""

    BINDINGS = [("escape", "app.pop_screen", "Back")]

    def compose(self) -> ComposeResult:
        yield Header()
        with VerticalScroll(id="select-root"):
            for key, title in _ordered_groups(self.app.services):          # type: ignore[attr-defined]
                members = [s for s in self.app.services if s.group == key]  # type: ignore[attr-defined]
                if not members:
                    continue
                with Vertical(classes="group"):
                    yield Checkbox(title, id=f"grp-{key}", classes="group-head")
                    with Horizontal(classes="cards"):
                        for svc in members:
                            yield ServiceCard(svc)
            yield Static("", id="dep-note")
        with Horizontal(id="actions"):
            yield Button("Quit", id="quit", variant="error")
            yield Button("Back", id="back", variant="default")
            yield Button("Next", id="next", variant="primary")
        yield Footer()

    # -- group checkbox toggles its children ------------------------------
    def on_checkbox_changed(self, event: Checkbox.Changed) -> None:
        cid = event.checkbox.id or ""
        if cid.startswith("grp-"):
            key = cid[4:]
            for svc in self.app.services:                # type: ignore[attr-defined]
                if svc.group == key:
                    cb = self.query_one(f"#svc-{svc.name}", Checkbox)
                    if cb.value != event.value:
                        cb.value = event.value
        self._refresh_dep_note()

    def _selected(self) -> set[str]:
        out = set()
        for svc in self.app.services:                    # type: ignore[attr-defined]
            try:
                if self.query_one(f"#svc-{svc.name}", Checkbox).value:
                    out.add(svc.name)
            except Exception:                            # noqa: BLE001
                pass
        return out

    def _refresh_dep_note(self) -> None:
        svcs = self.app.svc_map                          # type: ignore[attr-defined]
        chosen = self._selected()
        pulled = resolve_dependencies(chosen, svcs) - chosen
        note = self.query_one("#dep-note", Static)
        if pulled:
            note.update("+ pulled in as dependencies: " +
                        ", ".join(sorted(p.replace("seren-", "") for p in pulled)))
        else:
            note.update("")

    def on_button_pressed(self, event: Button.Pressed) -> None:
        if event.button.id == "quit":
            self.app.exit()
        elif event.button.id == "back":
            self.app.pop_screen()
        elif event.button.id == "next":
            chosen = self._selected()
            if not chosen:
                self.query_one("#dep-note", Static).update(
                    "nothing selected - pick at least one service")
                return
            full = resolve_dependencies(chosen, self.app.svc_map)   # type: ignore[attr-defined]
            self.app.selected = install_order(full, self.app.svc_map)  # type: ignore[attr-defined]
            self.app.push_screen(ConfigScreen())


class AdvancedModal(ModalScreen[dict]):
    """Everything that isn't universal or inline, for one service.

    A real ModalScreen: Textual's own DEFAULT_CSS dims the screen underneath
    (background: $background 60%) and its bindings take precedence over the
    app's, so Escape belongs to the dialog while it's open. All this screen
    adds is centring - which is why it previously rendered flush to the
    top-left instead of floating over the config screen - and the service's
    accent colour on the frame, title and confirm button.
    """

    BINDINGS = [("escape", "cancel", "Cancel")]

    def __init__(self, svc: ServiceDef, current: dict) -> None:
        super().__init__()
        self.svc = svc
        self.current = dict(current)

    def compose(self) -> ComposeResult:
        with Vertical(id="modal"):
            yield Static(f"Advanced · {self.svc.display}", classes="modal-title")
            yield Static(f"{self.svc.package}  ·  default port "
                         f"{self.svc.default_port}", classes="modal-sub")
            with VerticalScroll(id="modal-body"):
                for flag in self.svc.advanced_flags:
                    if flag in ("gen-token",):
                        yield Checkbox("generate a bearer token",
                                       value=bool(self.current.get(flag)),
                                       id=f"adv-{flag}")
                        continue
                    default = ""
                    if flag == "port":
                        default = str(self.svc.default_port)
                    elif flag == "host":
                        default = self.svc.default_host
                    yield Label(flag)
                    # Empty value + the default as PLACEHOLDER, not as a
                    # pre-filled value. Pre-filling meant opening this dialog
                    # and pressing Okay silently added `--host 127.0.0.1` to the
                    # command line - a flag the operator never chose. The
                    # placeholder shows the same information without turning a
                    # look into an edit.
                    yield Input(value=str(self.current.get(flag, "")),
                                placeholder=default or "(unset)",
                                id=f"adv-{flag}")
            with Horizontal(id="modal-actions"):
                yield Button("Cancel", id="cancel", variant="default")
                yield Button("Okay", id="ok", variant="primary")

    def on_mount(self) -> None:
        # Applied here rather than in CSS: the colour arrives at runtime from
        # --describe, so no stylesheet could know it.
        if not self.svc.accent:
            return
        self.query_one("#modal").styles.border = ("thick", self.svc.accent)
        self.query_one(".modal-title", Static).styles.color = self.svc.accent
        ok = self.query_one("#ok", Button)
        ok.styles.background = self.svc.accent
        ok.styles.color = "#11111b"

    def action_cancel(self) -> None:
        """Escape discards edits - dismiss(None) means the caller's callback
        sees a falsy result and leaves the existing config untouched."""
        self.dismiss(None)

    def on_button_pressed(self, event: Button.Pressed) -> None:
        if event.button.id == "cancel":
            self.dismiss(None)
            return
        out: dict[str, Any] = {}
        for flag in self.svc.advanced_flags:
            try:
                w = self.query_one(f"#adv-{flag}")
            except Exception:                            # noqa: BLE001
                continue
            if isinstance(w, Checkbox):
                if w.value:
                    out[flag] = True
            elif isinstance(w, Input) and w.value.strip():
                out[flag] = w.value.strip()
        self.dismiss(out)


class ConfigScreen(Screen):
    """Universal options up top, then a row per selected service."""

    BINDINGS = [("escape", "app.pop_screen", "Back")]

    def compose(self) -> ComposeResult:
        yield Header()
        with VerticalScroll(id="config-root"):
            yield Static("Universal install options", classes="section")
            yield Label("venv root")
            yield Input(placeholder="~/seren-venvs", id="u-venv")
            yield Checkbox("corporate TLS / intercepting proxy (--corp)", id="u-corp")
            yield Checkbox("install from PyPI (--pypi)", value=True, id="u-pypi")
            yield Label("or pin a GitHub release tag (--ref, blank = PyPI)")
            yield Input(placeholder="v1.5.0", id="u-ref")
            yield Rule()
            # Name on its own line, controls beneath. A single horizontal row
            # needed 107 columns for Loci (it has the extra 'vector' extra) and
            # pushed Configure clean off the screen. Headless boxes over SSH are
            # routinely 80 wide, which is the whole audience for a TUI installer.
            for name in self.app.selected:               # type: ignore[attr-defined]
                svc = self.app.svc_map[name]             # type: ignore[attr-defined]
                with Vertical(classes="cfg-row"):
                    nm = Static(svc.display, classes="cfg-name")
                    if svc.accent:
                        nm.styles.color = svc.accent
                    yield nm
                    with Horizontal(classes="cfg-controls"):
                        with RadioSet(id=f"mode-{name}"):
                            yield RadioButton("Default", value=True)
                            yield RadioButton("Advanced")
                        for flag in INLINE_FLAGS:
                            if flag in svc.flags:
                                yield Checkbox(flag, id=f"f-{name}-{flag}")
                        btn = Button("Configure", id=f"adv-{name}",
                                     classes="cfg-adv", variant="default")
                        if svc.accent:
                            btn.styles.color = svc.accent
                        yield btn
            yield Static("", id="cfg-warn")
        with Horizontal(id="actions"):
            yield Button("Back", id="back", variant="default")
            yield Button("Install", id="go", variant="primary")
        yield Footer()

    def on_button_pressed(self, event: Button.Pressed) -> None:
        bid = event.button.id or ""
        if bid == "back":
            self.app.pop_screen()
        elif bid.startswith("adv-"):
            name = bid[4:]
            svc = self.app.svc_map[name]                 # type: ignore[attr-defined]
            cur = self.app.per_service.get(name, {})     # type: ignore[attr-defined]
            self.app.push_screen(AdvancedModal(svc, cur),
                                 lambda res, n=name: self._save_adv(n, res))
        elif bid == "go":
            self._collect()
            warn = port_conflicts(self.app.selected, self.app.svc_map,       # type: ignore[attr-defined]
                                  self.app.per_service)                      # type: ignore[attr-defined]
            if warn:
                self.query_one("#cfg-warn", Static).update(
                    "  ".join(warn) + "  — change a port under Configure")
                return
            self.app.jobs = [                                  # type: ignore[attr-defined]
                Job(label=self.app.svc_map[n].display,         # type: ignore[attr-defined]
                    cmd=build_command(self.app.svc_map[n],     # type: ignore[attr-defined]
                                      self.app.per_service.get(n, {}),  # type: ignore[attr-defined]
                                      self.app.universal))     # type: ignore[attr-defined]
                for n in self.app.selected                     # type: ignore[attr-defined]
            ]
            self.app.push_screen(InstallScreen())

    def _save_adv(self, name: str, result: Optional[dict]) -> None:
        if result:
            self.app.per_service.setdefault(name, {}).update(result)  # type: ignore[attr-defined]

    def _collect(self) -> None:
        u: dict[str, Any] = {}
        if self.query_one("#u-venv", Input).value.strip():
            u["venv"] = self.query_one("#u-venv", Input).value.strip()
        if self.query_one("#u-corp", Checkbox).value:
            u["corp"] = True
        ref = self.query_one("#u-ref", Input).value.strip()
        if ref:
            u["ref"] = ref                       # a tag beats PyPI
        elif self.query_one("#u-pypi", Checkbox).value:
            u["pypi"] = True
        self.app.universal = u                   # type: ignore[attr-defined]

        for name in self.app.selected:           # type: ignore[attr-defined]
            svc = self.app.svc_map[name]         # type: ignore[attr-defined]
            cfg = self.app.per_service.setdefault(name, {})   # type: ignore[attr-defined]
            for flag in INLINE_FLAGS:
                if flag in svc.flags:
                    cfg[flag] = self.query_one(f"#f-{name}-{flag}", Checkbox).value


class PrepareNodeScreen(Screen):
    """Prepare THIS machine: OS prereqs, CUDA, llama/kokoro/comfy/chroma/coral.

    Deliberately not the service grid with different cards. The pieces here
    aren't peers:
      - foundation is not optional; it's the prerequisite, always runs, and is
        the thing the phase-state tracking exists for. It's a status line, not
        a checkbox.
      - coral is hardware-gated and excluded from --all on purpose.
      - prebuilts/build is a MODE, not a component.
    """

    BINDINGS = [("escape", "app.pop_screen", "Back")]

    def compose(self) -> ComposeResult:
        node: Optional[NodeDef] = self.app.node          # type: ignore[attr-defined]
        yield Header()
        with VerticalScroll(id="config-root"):
            if node is None:
                yield Static("Node preparation unavailable", classes="section")
                yield Static(self.app.node_problem or "unknown",  # type: ignore[attr-defined]
                             id="cfg-warn")
            else:
                plat = node.platform or "not detected"
                detail = f"{node.jp_family or '?'}, CUDA arch {node.cuda_arch or '?'}"
                yield Static(f"Platform: {plat}   ({detail})", classes="section")
                yield Static(f"hostname {node.hostname}  ·  foundation phases "
                             "run first and skip when already done",
                             classes="modal-sub")
                if node.platform is None:
                    yield Static("Could not identify this machine. Pick one:",
                                 classes="modal-sub")
                    with RadioSet(id="force-platform"):
                        for p in (node.platforms or ["xavier", "nano", "spark"]):
                            yield RadioButton(p)
                yield Rule()
                yield Static("Components", classes="section")
                for c in node.components:
                    cb = Checkbox(f"{c.display} — {c.description}",
                                  id=f"nc-{c.name}", disabled=not c.available)
                    yield cb
                    if not c.available:
                        why = ("no hardware detected / not supported on this platform"
                               if c.hardware_gated else "no module for this platform")
                        yield Static(f"    unavailable: {why}", classes="card-req")
                yield Rule()
                yield Static("Install source", classes="section")
                if node.supports("build"):
                    with RadioSet(id="mode"):
                        yield RadioButton("prebuilts (download)", value=True)
                        yield RadioButton("build from source (hours)")
                if node.supports("tag"):
                    yield Label("pin a prebuilt release tag (blank = latest)")
                    yield Input(placeholder="2026.04.29-xavier", id="np-tag")

                yield Rule()
                yield Static("Options", classes="section")
                if node.supports("hostname"):
                    yield Label("hostname override (blank = auto-derived)")
                    yield Input(placeholder=node.hostname or "auto",
                                id="np-hostname")
                if node.supports("user"):
                    yield Label("target user (blank = the invoking user)")
                    yield Input(placeholder=os.environ.get("USER", "") or "you",
                                id="np-user")
                if node.supports("no-max-power"):
                    # Jetsons default to a power-capped profile; prep flips them
                    # to MAXN + jetson_clocks. Worth being able to decline on a
                    # box with marginal cooling or a small PSU.
                    yield Checkbox("skip max-power profile (MAXN + jetson_clocks)",
                                   id="np-nomaxpower")
                yield Static("", id="cfg-warn")
        with Horizontal(id="actions"):
            yield Button("Back", id="back", variant="default")
            yield Button("Prepare", id="go", variant="primary")
        yield Footer()

    def on_mount(self) -> None:
        node = self.app.node                             # type: ignore[attr-defined]
        if node is None:
            self.query_one("#go", Button).disabled = True
            return
        # Sudo up front, never mid-run: a password prompt during prep goes to a
        # terminal this TUI owns and reads as a hang.
        if not sudo_ready():
            self.query_one("#cfg-warn", Static).update(
                "sudo is not currently authorised. Run `sudo -v` in another "
                "terminal first — prep cannot prompt from inside the TUI.")

    def on_radio_set_changed(self, event: RadioSet.Changed) -> None:
        """Choosing a platform has to RE-QUERY, not just remember a name.

        Which components exist depends on which platform's modules are present
        (spark has no coral.sh), so without this the picker was decorative:
        every checkbox stayed disabled and there was nothing to select.
        """
        if (event.radio_set.id or "") != "force-platform":
            return
        chosen = str(event.pressed.label) if event.pressed else ""
        if not chosen:
            return
        node, problem = discover_node(platform_override=chosen)
        warn = self.query_one("#cfg-warn", Static)
        if node is None:
            warn.update(f"could not describe as '{chosen}': {problem}")
            return
        self.app.node = node                             # type: ignore[attr-defined]
        self._forced_platform = chosen
        for c in node.components:
            try:
                cb = self.query_one(f"#nc-{c.name}", Checkbox)
            except Exception:                            # noqa: BLE001
                continue
            cb.disabled = not c.available
            if not c.available:
                cb.value = False
        avail = [c.name for c in node.components if c.available]
        warn.update(f"treating this node as '{chosen}' - available: "
                    + (", ".join(avail) if avail else "nothing"))

    def on_button_pressed(self, event: Button.Pressed) -> None:
        if event.button.id == "back":
            self.app.pop_screen()
            return
        node: Optional[NodeDef] = self.app.node          # type: ignore[attr-defined]
        if node is None:
            return
        warn = self.query_one("#cfg-warn", Static)

        chosen = [c for c in node.components
                  if c.available
                  and self.query_one(f"#nc-{c.name}", Checkbox).value]
        if not chosen:
            warn.update("nothing selected - pick at least one component")
            return

        cmd = ["bash", str(node.script)]
        FLAG = {"llama": "--llama", "kokoro": "--kokoro", "comfyui": "--comfyui",
                "chromadb": "--chromadb", "coral": "--coral"}
        for c in chosen:
            cmd.append(FLAG[c.name])

        forced = getattr(self, "_forced_platform", "")
        if forced:
            cmd += ["--platform", forced]
        elif node.platform is None:
            warn.update("platform could not be detected - choose one above")
            return

        # Each option is read only if the screen actually rendered it, which in
        # turn only happened if --describe advertised the flag. A helper rather
        # than a pile of try/except: an option that isn't on screen must
        # contribute nothing, silently and without a traceback.
        def field(wid: str, kind: type):
            try:
                return self.query_one(wid, kind)
            except Exception:                            # noqa: BLE001
                return None

        mode = field("#mode", RadioSet)
        if mode is not None and mode.pressed_index == 1:
            cmd.append("--build")
        for wid, flag in (("#np-tag", "--tag"), ("#np-hostname", "--hostname"),
                          ("#np-user", "--user")):
            w = field(wid, Input)
            if w is not None and w.value.strip():
                cmd += [flag, w.value.strip()]
        nmp = field("#np-nomaxpower", Checkbox)
        if nmp is not None and nmp.value:
            cmd.append("--no-max-power")

        events = Path(tempfile.gettempdir()) / f"seren-prep-{os.getpid()}.jsonl"
        try:
            events.unlink()
        except OSError:
            pass
        cmd += ["--events", str(events)]

        self.app.jobs = [Job(label=f"prepare node ({node.platform or 'forced'})",  # type: ignore[attr-defined]
                             cmd=cmd, events_file=events)]
        self.app.push_screen(InstallScreen())


class InstallScreen(Screen):
    """Sequential runner. Progress from the done events, log from stderr.

    SEQUENTIAL, not parallel, deliberately: these create venvs, pip-install and
    register system services. Running them concurrently interleaves the output
    into something unreadable and invites two installers racing on the same
    path. Ordering already matters for dependencies; serial makes it free.
    """

    def compose(self) -> ComposeResult:
        yield Header()
        with Vertical(id="install-root"):
            yield Static("Ready", id="current")
            yield ProgressBar(total=100, show_eta=False, id="bar")
            yield RichLog(highlight=False, markup=True, wrap=True, id="log")
        with Horizontal(id="actions"):
            yield Button("Back", id="back", variant="default")
            yield Button("Run", id="run", variant="primary")
        yield Footer()

    def on_mount(self) -> None:
        log = self.query_one("#log", RichLog)
        for p in self.app.problems:                      # type: ignore[attr-defined]
            log.write(f"[yellow]discovery: {p}[/]")
        jobs = self.app.jobs                             # type: ignore[attr-defined]
        log.write("[dim]order: " + " -> ".join(j.label for j in jobs) + "[/]")

    def on_button_pressed(self, event: Button.Pressed) -> None:
        if event.button.id == "back":
            self.app.pop_screen()
        elif event.button.id == "run":
            self.query_one("#run", Button).disabled = True
            self.run_all()

    def run_all(self) -> None:
        asyncio.create_task(self._run_all())

    async def _run_all(self) -> None:
        log = self.query_one("#log", RichLog)
        bar = self.query_one("#bar", ProgressBar)
        cur = self.query_one("#current", Static)
        jobs: list[Job] = list(self.app.jobs)            # type: ignore[attr-defined]
        bar.update(total=max(1, len(jobs)), progress=0)
        failures = 0
        for i, job in enumerate(jobs, 1):
            cur.update(f"[{i}/{len(jobs)}]  {job.label}")
            log.write(f"[bold]$ {' '.join(job.cmd)}[/]")
            rc = await self._run_one(job, log)
            if rc != 0:
                failures += 1
                log.write(f"[red]{job.label} failed (exit {rc}) - stopping[/]")
                # Stop on failure: later services may depend on this one, and
                # cascading a broken dependency produces a confusing pile of
                # errors instead of one clear cause.
                break
            bar.advance(1)
        cur.update("Done" if not failures else "Stopped on failure")
        log.write("[green]Rip it and win. 🌭🔧[/]" if not failures
                  else "[red]Fix the above and run again.[/]")
        self.query_one("#run", Button).disabled = False

    def _render_event(self, label: str, ev: dict, log: RichLog) -> None:
        """One vocabulary for both halves of the stack."""
        kind = ev.get("event")
        if kind == "done":
            log.write(f"[green]✓ {label} → {ev.get('url','')}"
                      f"{'  (autostart)' if ev.get('autostart') else ''}[/]")
        elif kind == "error":
            log.write(f"[red]✗ {ev.get('msg','')}[/]")
        elif kind == "warn":
            log.write(f"[yellow]! {ev.get('msg','')}[/]")
        elif kind == "step":
            log.write(f"[blue]==> {ev.get('msg','')}[/]")
        elif kind == "ok":
            log.write(f"  ✓ {ev.get('msg','')}")
        elif kind == "info":
            log.write(f"[dim]  {ev.get('msg','')}[/]")
        elif kind == "phase_start":
            # tracked=false means the phase always reinstalls - say so, rather
            # than letting a tick imply "ensure it's there".
            note = "" if ev.get("tracked", True) else "  [dim](reinstalls)[/]"
            log.write(f"[blue]==> {ev.get('label','')}[/]{note}")
        elif kind == "phase_skip":
            log.write(f"[dim]  - {ev.get('label','')} (already done)[/]")
        elif kind == "phase_done":
            log.write(f"  ✓ {ev.get('label','')}")

    async def _run_one(self, job: Job, log: RichLog) -> int:
        label = job.label
        try:
            proc = await asyncio.create_subprocess_exec(
                *job.cmd, stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE)
        except FileNotFoundError as e:
            log.write(f"[red]cannot run {job.cmd[0]}: {e}[/]")
            return 127

        async def pump_events() -> None:
            # Service installers stream JSON on stdout. Node prep can't - it
            # redirects stdout and stderr into its own log file - so it writes
            # to job.events_file and we tail that instead. Same event
            # vocabulary either way, so _render_event handles both.
            if job.events_file is not None:
                assert proc.stdout
                async for raw in proc.stdout:               # human text on fd 3
                    text = raw.decode(errors="replace").rstrip()
                    if text:
                        log.write(Text.from_ansi(text))
                return
            assert proc.stdout
            async for raw in proc.stdout:
                line = raw.decode(errors="replace").strip()
                if not line:
                    continue
                try:
                    ev = json.loads(line)
                except json.JSONDecodeError:
                    log.write(f"[dim]{label}: {line}[/]")   # tolerate stray output
                    continue
                self._render_event(label, ev, log)

        async def tail_events_file() -> None:
            """Follow the events file while the process runs.

            Opened lazily and tolerant of it not existing yet - the script
            creates it when it emits its first event, which may be a second or
            two in. Reads incrementally so a long prep run shows progress
            rather than a wall of text at the end.
            """
            if job.events_file is None:
                return
            pos = 0
            buf = ""
            while True:
                try:
                    if job.events_file.exists():
                        with open(job.events_file, "r", encoding="utf-8",
                                  errors="replace") as fh:
                            fh.seek(pos)
                            chunk = fh.read()
                            pos = fh.tell()
                        if chunk:
                            buf += chunk
                            *lines, buf = buf.split("\n")
                            for line in lines:
                                line = line.strip()
                                if not line:
                                    continue
                                try:
                                    self._render_event(label, json.loads(line), log)
                                except json.JSONDecodeError:
                                    pass
                except Exception:                            # noqa: BLE001
                    pass
                if proc.returncode is not None and not chunk:
                    return
                await asyncio.sleep(0.25)

        async def pump_human() -> None:
            # stderr carries the installers' own colored output. Text.from_ansi
            # TRANSLATES the escape sequences into Rich styling rather than
            # dumping "\x1b[0;32m" into the pane as literal text (which is what
            # a plain write does) or flattening the colors away entirely. The
            # log ends up looking like the script does in a terminal.
            assert proc.stderr
            async for raw in proc.stderr:
                text = raw.decode(errors="replace").rstrip()
                if text:
                    log.write(Text.from_ansi(text))

        await asyncio.gather(pump_events(), pump_human(), tail_events_file())
        return await proc.wait()


# ═══════════════════════════════════════════════════════════════════════
#  App
# ═══════════════════════════════════════════════════════════════════════
class StarwrightApp(App):
    CSS = """
    Screen { background: #1e1e2e; }
    /* width:90 was wider than an 80-column terminal, which pushed the Install
       button clean off screen on exactly the headless SSH session this TUI
       exists for. 100% with a max keeps the art roomy on a wide terminal and
       usable on a narrow one. */
    #splash { width: 100%; max-width: 92; align: center middle; padding: 2; }
    #banner { color: #997256; text-align: center; }
    #tagline { color: #6c7086; text-align: center; padding-bottom: 2; }
    #splash Button { width: 100%; margin: 1 0; }
    #splash-note { color: #6c7086; text-align: center; padding-top: 1; }
    #select-root { padding: 1 2; }
    /* Explicit height:auto all the way down. Without it on the GROUP and the
       CARDS row, the outer container fixed its height first and clipped the
       bottom line off every card whose description wrapped - the border landed
       mid-sentence ("The bridge between Loci and"). */
    .group { border: round #45475a; padding: 0 1 1 1; margin: 1 0;
             height: auto; width: auto; }
    .group-head { color: #cba6f7; text-style: bold; }
    .cards { height: auto; width: auto; }
    .card { border: round #313244; width: 34; height: auto; min-height: 8;
            padding: 0 1; margin: 0 1; }
    .card-desc { color: #a6adc8; height: auto; }
    .card-req { color: #f9e2af; height: auto; }

    #config-root { padding: 1 2; }
    .section { color: #cba6f7; text-style: bold; padding: 1 0 0 0; }
    /* Inputs sat flush against their labels and each other. */
    #config-root Input { margin: 0 0 1 0; }
    #config-root > Label { padding: 1 0 0 0; }
    #config-root > Checkbox { margin: 0 0 1 0; }
    .cfg-row { height: auto; border-bottom: solid #313244; padding: 1 0 1 0; }
    .cfg-name { text-style: bold; padding: 0 0 0 1; }
    .cfg-controls { height: auto; align: left middle; }
    /* 13 truncated the labels to "Defaul..." / "Advanc...". 15 is the width
       that fits "Advanced" plus the radio glyph, and still leaves Configure
       on screen at 80 columns - measured, not guessed. */
    .cfg-controls RadioSet { width: 15; height: auto; border: none;
                             background: transparent; margin: 0 1; }
    /* Left-margin only. Symmetric margins cost a column on each side of every
       control, which at three checkboxes (Loci) was the 2 columns that pushed
       Configure past an 80-wide terminal. */
    .cfg-controls Checkbox { width: auto; min-width: 0; margin: 0 0 0 1;
                             padding: 0; }
    /* min-width:0 is the load-bearing bit. Textual's Button carries a default
       min-width of 16, which silently overrode `width: 13` and was the real
       reason Configure overflowed - not the margins I blamed first. */
    .cfg-adv { width: auto; min-width: 0; height: 3; margin: 0 0 0 1; }
    #actions { height: auto; align: center middle; padding: 1; }
    #actions Button { margin: 0 2; }
    #dep-note, #cfg-warn { color: #f9e2af; padding: 1 2; }
    /* ModalScreen's own DEFAULT_CSS dims the backdrop (background: $background
       60%) - but `Screen { background: #1e1e2e; }` above ALSO matches this
       screen, and app-level CSS outranks a widget's DEFAULT_CSS. So my own
       opaque rule was quietly cancelling the dim. Restating it here with an
       explicit alpha wins it back; the trailing percentage is the alpha.
       `align` is what actually centres the dialog - ModalScreen dims for you
       but does not position anything. */
    AdvancedModal { align: center middle; background: #11111b 65%; }
    #modal { background: #181825; border: thick #cba6f7; padding: 1 2;
             width: 62; height: auto; max-height: 85%; }
    .modal-title { text-style: bold; }
    .modal-sub { color: #6c7086; padding: 0 0 1 0; }
    /* height:auto on the dialog + 1fr here means the frame hugs its contents
       for a short form and only scrolls once there are too many fields -
       instead of always being 80% tall with dead space underneath. */
    #modal-body { height: auto; max-height: 100%; }
    #modal-actions { height: auto; align: right middle; padding: 1 0 0 0; }
    #modal-actions Button { min-width: 0; width: auto; margin: 0 0 0 2; }
    #log { height: 1fr; border: round #313244; }
    #current { color: #89b4fa; text-style: bold; padding: 1 2; }
    #install-root { height: 1fr; }
    """
    TITLE = "Seren Starwright"

    def __init__(self, services: list[ServiceDef], problems: list[str]) -> None:
        super().__init__()
        self.services = services
        self.problems = problems
        self.svc_map = {s.name: s for s in services}
        self.selected: list[str] = []
        self.per_service: dict[str, dict] = {}
        self.universal: dict = {}
        self.jobs: list[Job] = []
        self.node: Optional[NodeDef] = None
        self.node_problem: Optional[str] = None

    def on_mount(self) -> None:
        # Ask the machine what it is before drawing the splash, so the Prepare
        # Node button can be honestly enabled or disabled. Cheap (a --describe
        # with zero side effects) and it means the splash never offers a door
        # that leads nowhere.
        self.node, self.node_problem = discover_node()
        self.push_screen(SplashScreen())


def main() -> None:
    services, problems = discover()

    if "--dump" in sys.argv:
        print(f"# scripts root: {BASE_DIR}"
              + ("  (unpacked from the archive - edit these freely, they're real files)"
                 if IS_BUNDLED else ""))
        for s in services:
            print(f"{s.group:10} {s.name:24} :{s.default_port:<6} "
                  f"extras={s.extras} requires={s.requires}")
        for p in problems:
            print(f"PROBLEM: {p}", file=sys.stderr)
        if not services:
            # Silence here used to read as "everything's fine, nothing to do",
            # which is the wrong answer to "I can't find any installers".
            sys.exit(f"no installers found under {BASE_DIR} "
                     f"- set $SEREN_STARWRIGHT_ROOT to a directory "
                     f"containing {ROOT_MARKER}")
        return

    if not services:
        sys.exit(f"No installers found under {_installer_dir()}\n"
                 f"(repo root resolved to {BASE_DIR})\n"
                 "Set $SEREN_STARWRIGHT_ROOT to a directory containing "
                 f"{ROOT_MARKER}.\n"
                 + "\n".join(problems))

    StarwrightApp(services, problems).run()


if __name__ == "__main__":
    main()
