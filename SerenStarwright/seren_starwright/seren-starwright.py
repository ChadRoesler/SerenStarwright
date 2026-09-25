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
import re
import time
import shutil
import subprocess
import sys
import tempfile
import zipfile
from dataclasses import dataclass, field, asdict
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
    from textual.containers import (Horizontal, Vertical, VerticalScroll, Center, Grid)
    from textual.screen import ModalScreen, Screen
    from textual.widgets import (Button, Checkbox, Footer, Header, Input, Label, Select,
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
UNIVERSAL_FLAGS = {"corp", "pypi", "ref", "repo", "wheel", "venv", "local"}

# What a card that predates the `switches` key in --describe is assumed to
# take without a value. Only consulted when the card reports no switches.
LEGACY_SWITCHES = {"corp", "pypi", "mcp", "vector", "stagehand", "service", "gen-token",
                   "no-updates", "local-system", "st", "trim-os", "wipe-nvme"}

# Shown as inline checkboxes on the config row rather than buried in Advanced.
#
# The test for membership here is "would someone decide this while looking at
# the grid?" - not "is it an extra". `service` is not an extra at all and has
# always been inline, because autostart-or-not is a decision you make about the
# box in front of you. `stagehand` is the same shape: it decides whether this
# node can START builds or only watch them, which is a per-node role, not a
# packaging detail. Burying a role behind Configure makes it look optional in
# the sense of "obscure" rather than "opt-in".
#
# `st` is Memory's: sentence-transformers (and torch) for a named embedding
# model. It sat in Advanced, where an opt-in that pulls in torch looked like an
# obscure setting instead of the decision it is - leave it off on a Nano, the
# default embedder is torch-free ONNX. Its label says what it costs.
#
# Width: rendering is `for flag in INLINE_FLAGS: if flag in svc.flags`, so a
# service only widens by the flags it actually declares. Loci and Memory are
# the widest cards at three (mcp + vector + service, mcp + st + service);
# Theatre draws two.
INLINE_FLAGS = ["mcp", "vector", "st", "stagehand", "service"]

# What an inline checkbox reads as, where the flag name alone is jargon, and
# the tooltip that says why you would tick it.
INLINE_LABELS = {"st": "st+torch"}
INLINE_TIPS = {
    "st": "sentence-transformers and torch, for a storage.embedding_model you name. "
          "Not needed for the default embedder (ONNX, no torch); heavy on a Nano.",
}

# Service IDENTITY - who the installed service logs on as.
#
# Machine-shaped like --corp (one box, one answer), but ALSO per-service
# overridable, which is exactly why these are not in UNIVERSAL_FLAGS: that set
# means "asked once, never per-service", and identity needs both.
#
# They are kept out of the generic Advanced renderer too, and that part is not
# cosmetic. That renderer turns any unknown flag into a text Input, and
# `local-system` is a SWITCH - build_command would emit
# `-LocalSystem <whatever you typed>`, which PowerShell rejects outright
# because a switch takes no positional argument. A checkbox is the only
# correct widget for it.
IDENTITY_FLAGS = {"service-user", "local-system"}

# The password is NOT in that set and is NOT a flag at all. It reaches the
# installers through the process environment - see Job.env and _run_one.
SERVICE_PASSWORD_ENV = "SEREN_SERVICE_PASSWORD"


def default_service_account() -> str:
    """A sensible prefill for the service logon, spelled the way the OS wants.

    Windows needs DOMAIN\\user or .\\user. A bare username is ambiguous, and
    nssm will accept one happily and then leave you with a service that won't
    start. On a non-domain box USERDOMAIN is just the machine name, where
    '.\\' says the same thing more clearly.
    """
    if IS_WINDOWS:
        user = os.environ.get("USERNAME", "")
        if not user:
            return ""
        domain = os.environ.get("USERDOMAIN", "")
        machine = os.environ.get("COMPUTERNAME", "")
        if domain and domain.lower() != machine.lower():
            return f"{domain}\\{user}"
        return f".\\{user}"
    return os.environ.get("USER", "") or ""


# ── secrets ────────────────────────────────────────────────────────────────
# Two separate mechanisms doing two separate jobs, and conflating them would
# leave a real hole:
#
#   Job.env keeps the password OFF the command line. On Windows any process can
#   read another process's arguments through WMI, so a --password flag is
#   exposed no matter how clean the log is. No amount of redaction fixes that.
#
#   SecretRegistry keeps secrets out of the LOG PANE. Different leak, different
#   cause - and it catches one that argv-avoidance never could: the installers
#   print "Bearer token: <value>", and under --json every Write-Host is shadowed
#   onto stderr, which this screen pumps straight into the log. Tokens have been
#   landing in here all along.
_SECRET_LINE = re.compile(r"((?:bearer\s+)?token\s*[:=]\s*)(\S+)", re.IGNORECASE)
_MASK = "••••••••"


class SecretRegistry:
    """Known secret strings, plus a pattern for secrets we can't know up front."""

    def __init__(self) -> None:
        self._values: set[str] = set()

    def add(self, value: Optional[str]) -> None:
        # Very short values are skipped deliberately. A 1-3 character "secret"
        # would match all over ordinary output and turn the log into confetti;
        # any real password or token is comfortably longer, so nothing worth
        # hiding is lost by the floor.
        if value and len(value) >= 4:
            self._values.add(value)

    def redact(self, text: str) -> str:
        # Longest first, so a secret containing another secret as a substring is
        # masked whole instead of leaving a readable tail behind.
        for value in sorted(self._values, key=len, reverse=True):
            if value in text:
                text = text.replace(value, _MASK)
        return _SECRET_LINE.sub(lambda m: m.group(1) + _MASK, text)


class RedactingLog:
    """The ONLY way anything reaches the install log.

    A wrapper rather than a RichLog subclass, on purpose: there is exactly one
    write path, and no way to reach the widget's own .write() by habit and slip
    past the redaction.
    """

    def __init__(self, log: RichLog, secrets: SecretRegistry) -> None:
        self._log = log
        self._secrets = secrets

    def write(self, content: Any) -> None:
        if isinstance(content, Text):
            plain = content.plain
            cleaned = self._secrets.redact(plain)
            # Only rebuild when something actually changed: rebuilding discards
            # the ANSI styling Text.from_ansi just parsed. That's a fair price
            # on a redacted line and a pointless one on every other line.
            self._log.write(Text(cleaned) if cleaned != plain else content)
            return
        self._log.write(self._secrets.redact(str(content)))


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
    # Flags that take no value, from --describe's `switches` (bash derives it
    # from `shift ;;` branches, PowerShell from [switch] parameters). An older
    # card that does not report it falls back to the switches every card in
    # the family has always had, so the modal never turns one into a text box.
    switches: list[str] = field(default_factory=list)
    script: Path = Path()

    def is_switch(self, flag: str) -> bool:
        return flag in self.switches or (not self.switches and flag in LEGACY_SWITCHES)

    @property
    def advanced_flags(self) -> list[str]:
        """Everything that isn't universal, inline, or plumbing."""
        skip = (UNIVERSAL_FLAGS | set(INLINE_FLAGS) | IDENTITY_FLAGS
                | {"describe", "json", "help"})
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
    # Has this MACHINE ever completed a prep run? Read from state kept on the
    # node itself, so unlike the old per-checkout state file it is not reset by
    # a fresh clone or a .pyz rebuild. Drives whether this screen OFFERS prep or
    # merely permits it.
    provisioned: bool = False
    provisioned_at: str = ""
    # The name seren itself set, if it ever did - so the screen can say who
    # chose the current hostname instead of implying nobody did.
    hostname_managed: str = ""
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
    # Extra environment for this job's subprocess, merged over os.environ.
    # This is how the service password travels: never as an argument, because
    # command lines are readable by other processes on Windows and this screen
    # echoes every command it runs into the log.
    env: Optional[dict[str, str]] = None


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
            provisioned=bool(d.get("provisioned", False)),
            provisioned_at=str(d.get("provisioned_at") or ""),
            hostname_managed=str(d.get("hostname_managed") or ""),
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
                params=dict(d.get("params", {})),
                switches=list(d.get("switches", [])), script=script))
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


# ══════════════════════════════════════════════════════════════════════════
#  The install ledger - what is already on this box
# ══════════════════════════════════════════════════════════════════════════
#
# Every installer records what it put where in ~/.seren/installed/
# <service>[@<instance>].json (seren_record_install / Write-SerenInstallRecord).
# Installs that predate the ledger are DERIVED by scanning ~/seren-*/ for the
# launcher every card has always written (run-<service>.sh / .ps1): the launcher
# names the venv and the config, the config names the port, the directory's
# suffix is the instance. Nothing here is declared twice, and nothing here
# reads a token.


@dataclass
class InstalledRecord:
    service: str
    instance: str = ""
    host: str = ""
    port: int = 0
    venv: str = ""
    config: str = ""
    app_dir: str = ""
    version: str = ""
    source: str = ""
    installed_at: str = ""
    derived: bool = False          # True = scanned, not recorded by the installer
    path: str = ""                 # the record file, or the scanned directory
    source_ref: str = ""            # the wheelhouse folder / tag / wheel it came from
    autostart: bool = False
    service_user: str = ""          # the account it runs as, when not LocalSystem
    local_system: Optional[bool] = None   # None = not known
    os_service: str = ""            # the systemd unit / Windows service it is
    extras: dict = field(default_factory=dict)   # mcp / corp / vector / st, as installed
    setup: str = ""                # the setup this install belongs to ("" = none named)

    @property
    def label(self) -> str:
        return f"{self.service}@{self.instance}" if self.instance else self.service

    @property
    def url(self) -> str:
        host = self.host or "127.0.0.1"
        return f"http://{'127.0.0.1' if host == '0.0.0.0' else host}:{self.port}"


def ledger_dir(home: Optional[Path] = None) -> Path:
    env = os.environ.get("SEREN_INSTALLED_DIR")
    return Path(env).expanduser() if env else (home or Path.home()) / ".seren" / "installed"


_LAUNCHER_RE = re.compile(r"run-(seren-[a-z0-9-]+)\.(sh|ps1)$")
_PY_RE = re.compile(r'"([^"]*?python(?:\.exe)?)"|(\S*?/bin/python\b)')
_CFG_RE = re.compile(r'--config\s+"?([^"\s]+)"?')
_MOD_RE = re.compile(r"-m\s+([A-Za-z_][A-Za-z0-9_.]*)")


def _yaml_server(text: str) -> tuple[str, int]:
    """host and port from the config's server block, without a yaml parser
    (the ledger must work before this venv has one). First match wins; the
    server block is at the top of every card's generated config."""
    host = ""
    port = 0
    for line in text.splitlines():
        m = re.match(r"^\s*host:\s*['\"]?([^'\"#\s]+)", line)
        if m and not host:
            host = m.group(1)
        m = re.match(r"^\s*port:\s*['\"]?(\d+)", line)
        if m and not port:
            port = int(m.group(1))
        if host and port:
            break
    return host, port


def _venv_version(venv: str, package: str) -> str:
    """The installed version, read off the dist-info directory name. No
    interpreter is run: a dozen venvs would take seconds, a glob takes none."""
    if not venv or not package:
        return ""
    stem = package.replace("-", "_")
    roots = [Path(venv) / "Lib" / "site-packages"] + sorted((Path(venv) / "lib").glob("python*/site-packages"))
    for root in roots:
        for d in sorted(root.glob(f"{stem}-*.dist-info")) if root.is_dir() else []:
            return d.name[len(stem) + 1:-len(".dist-info")]
    return ""


def derive_install(app_dir: Path) -> Optional[InstalledRecord]:
    """One ~/seren-<x><instance>/ directory -> a record, from the launcher
    and the config it names. None when the directory is not an install."""
    launchers = [f for f in app_dir.iterdir() if f.is_file() and _LAUNCHER_RE.search(f.name)] \
        if app_dir.is_dir() else []
    if not launchers:
        return None
    launcher = sorted(launchers, key=lambda f: (f.suffix != (".ps1" if IS_WINDOWS else ".sh"), f.name))[0]
    service = _LAUNCHER_RE.search(launcher.name).group(1)
    try:
        text = launcher.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return None
    venv = ""
    m = _PY_RE.search(text)
    if m:
        py = Path(m.group(1) or m.group(2))
        venv = str(py.parent.parent)
    cfg = ""
    m = _CFG_RE.search(text)
    if m:
        cfg = m.group(1)
    else:
        for f in app_dir.glob(f"{service}.yaml"):
            cfg = str(f)
    host, port = "", 0
    if cfg and Path(cfg).is_file():
        try:
            host, port = _yaml_server(Path(cfg).read_text(encoding="utf-8", errors="replace"))
        except OSError:
            pass
    instance = app_dir.name[len(service):] if app_dir.name.startswith(service) else ""
    m = _MOD_RE.search(text)
    package = (m.group(1).split(".")[0].replace("_", "-") if m else service)
    return InstalledRecord(service=service, instance=instance, host=host, port=port, venv=venv,
                           config=cfg, app_dir=str(app_dir), version=_venv_version(venv, package),
                           source="", installed_at="", derived=True, path=str(app_dir))


def os_service_name(rec: "InstalledRecord") -> str:
    """The unit / service the service wrappers create: seren-memory<instance>
    on systemd, SerenMemory<instance> on Windows (NSSM)."""
    if IS_WINDOWS:
        short = rec.service.replace("seren-", "", 1)
        return "Seren" + "".join(w.capitalize() for w in short.split("-")) + rec.instance
    return f"{rec.service}{rec.instance}.service"


def os_services() -> dict[str, dict]:
    """Every seren service the OS has, with its start mode and account. One
    query per box, bounded; an answer that cannot be had is an empty map."""
    out: dict[str, dict] = {}
    try:
        if IS_WINDOWS:
            ps = ("Get-CimInstance Win32_Service -Filter \"Name like 'Seren%'\" | "
                  "Select-Object Name,StartMode,StartName | ConvertTo-Json -Compress")
            p = subprocess.run(["powershell", "-NoProfile", "-NonInteractive", "-Command", ps],
                               capture_output=True, text=True, timeout=20)
            data = json.loads(p.stdout or "[]") if (p.stdout or "").strip() else []
            for d in ([data] if isinstance(data, dict) else data):
                out[str(d.get("Name"))] = {"autostart": str(d.get("StartMode")) == "Auto",
                                           "account": str(d.get("StartName") or "")}
        elif shutil.which("systemctl"):
            p = subprocess.run(["systemctl", "list-unit-files", "--type=service", "--no-legend", "--no-pager",
                                "seren-*.service"], capture_output=True, text=True, timeout=20)
            for line in (p.stdout or "").splitlines():
                parts = line.split()
                if len(parts) < 2:
                    continue
                u = subprocess.run(["systemctl", "show", "-p", "User", "--value", parts[0]],
                                   capture_output=True, text=True, timeout=10)
                out[parts[0]] = {"autostart": parts[1] == "enabled", "account": (u.stdout or "").strip()}
    except Exception:  # noqa: BLE001 - the OS view is a bonus, never a failure
        return {}
    return out


def apply_os_services(records: list["InstalledRecord"], services: dict[str, dict]) -> None:
    """Autostart and identity from the OS for every record it knows: the
    truth now, whatever the install said, and the only source for installs
    the ledger never recorded."""
    for r in records:
        name = os_service_name(r)
        info = services.get(name)
        if info is None:
            continue
        r.os_service = name
        r.autostart = bool(info["autostart"])
        acct = info.get("account", "")
        if acct.lower() == "localsystem":
            r.local_system, r.service_user = True, ""
        elif acct:
            r.local_system, r.service_user = False, acct


def installed_ledger(home: Optional[Path] = None, probe_os: Optional[bool] = None) -> list[InstalledRecord]:
    """Every install on this box: the ledger's records first, then anything
    under ~/seren-*/ the ledger does not know about (installed before it
    existed). Read-only, tolerant of every malformed file."""
    # Decided BEFORE home is defaulted: a caller that passes a home (a test)
    # never has this box's services applied to its records.
    probe = probe_os if probe_os is not None else home is None
    home = home or Path.home()
    out: list[InstalledRecord] = []
    known_dirs: set[str] = set()
    ld = ledger_dir(home)
    if ld.is_dir():
        for f in sorted(ld.glob("*.json")):
            try:
                d = json.loads(f.read_text(encoding="utf-8-sig"))
                rec = InstalledRecord(
                    service=str(d.get("service") or ""), instance=str(d.get("instance") or ""),
                    host=str(d.get("host") or ""), port=int(d.get("port") or 0),
                    venv=str(d.get("venv") or ""), config=str(d.get("config") or ""),
                    app_dir=str(d.get("app_dir") or ""), version=str(d.get("version") or ""),
                    source=str(d.get("source") or ""), installed_at=str(d.get("installed_at") or ""),
                    derived=bool(d.get("derived", False)), path=str(f),
                    extras={k: bool(v) for k, v in (d.get("extras") or {}).items()} if isinstance(d.get("extras"), dict) else {},
                    source_ref=str(d.get("source_ref") or ""),
                    service_user=str(d.get("service_user") or ""),
                    local_system=(bool(d["local_system"]) if "local_system" in d else None),
                    autostart=bool(d.get("autostart", False)),
                    setup=str(d.get("setup") or ""))
            except (OSError, ValueError, TypeError):
                continue
            if not rec.service:
                continue
            if not rec.version and rec.venv:
                rec.version = _venv_version(rec.venv, str(d.get("package") or rec.service))
            out.append(rec)
            if rec.app_dir:
                known_dirs.add(os.path.normcase(os.path.normpath(rec.app_dir)))
    for d in sorted(home.glob("seren-*")):
        if not d.is_dir() or d.name in ("seren-venvs", "seren-logs"):
            continue
        if os.path.normcase(os.path.normpath(str(d))) in known_dirs:
            continue
        rec = derive_install(d)
        if rec:
            out.append(rec)
    if probe:
        apply_os_services(out, os_services())
    out.sort(key=lambda r: (r.service, r.instance))
    return out


# ── setups: a named set of installs that belong together ──────────────────
#
# "If I have you, and a local, and both set with their own memory and loci and
# corpus..." A SETUP is a name (who or what the installs are for; the date
# when nobody says), the instance name its new members take, a port base
# (each service sits at base + its family offset, so two setups never touch),
# and the members it has. Choosing one on the select screen turns the run
# into "alter this setup": existing members reinstall in place with their
# flags prefilled, new members get the instance, the port and their wiring
# filled in. Recorded in ~/.seren/setups/<name>.json; each ledger record
# also names its setup.

FAMILY_BASE = 7420          # memory 7420, margin 7421, loci 7422, callosum 7423, hippocampus 7424, ...
FAMILY_BAND = 20


@dataclass
class Setup:
    name: str
    instance: str = ""
    base_port: int = FAMILY_BASE
    created_at: str = ""
    members: list = field(default_factory=list)      # record labels: service or service@instance
    path: str = ""

    @property
    def is_default(self) -> bool:
        return self.base_port == FAMILY_BASE and not self.instance


def setups_dir(home: Optional[Path] = None) -> Path:
    env = os.environ.get("SEREN_SETUPS_DIR")
    return Path(env).expanduser() if env else (home or Path.home()) / ".seren" / "setups"


def sanitize_instance(name: str) -> str:
    out = re.sub(r"[^a-z0-9-]+", "-", (name or "").strip().lower()).strip("-")
    return out[:40]


def band_offset(svc: ServiceDef) -> Optional[int]:
    """Where this service sits in the family band, or None for a service
    outside it (Observatory 7777, Probe 7430...)."""
    if FAMILY_BASE <= svc.default_port < FAMILY_BASE + FAMILY_BAND:
        return svc.default_port - FAMILY_BASE
    return None


def suggest_base(installed: list[InstalledRecord], setups: Optional[list["Setup"]] = None) -> int:
    """The first band above the family's with no installed port and no setup in it."""
    taken = {r.port for r in installed if r.port} | {s.base_port for s in (setups or [])}
    base = FAMILY_BASE + FAMILY_BAND
    while base < 7900:
        if not any(base <= p < base + FAMILY_BAND for p in taken):
            return base
        base += FAMILY_BAND
    return base


def load_setups(home: Optional[Path] = None, installed: Optional[list[InstalledRecord]] = None) -> list[Setup]:
    """Every setup on this box: the files, plus a setup implied by ledger
    records that name one the files do not know (an installer run from the
    shell with SEREN_SETUP set)."""
    out: dict[str, Setup] = {}
    d = setups_dir(home)
    if d.is_dir():
        for f in sorted(d.glob("*.json")):
            try:
                j = json.loads(f.read_text(encoding="utf-8-sig"))
                st = Setup(name=str(j.get("name") or f.stem), instance=str(j.get("instance") or ""),
                           base_port=int(j.get("base_port") or FAMILY_BASE), created_at=str(j.get("created_at") or ""),
                           members=[str(m) for m in (j.get("members") or [])], path=str(f))
            except (OSError, ValueError, TypeError):
                continue
            if st.name:
                out[st.name] = st
    for r in installed or []:
        if r.setup:
            st = out.get(r.setup)
            if st is None:
                st = out[r.setup] = Setup(name=r.setup, instance=r.instance, base_port=r.port or FAMILY_BASE)
            if r.label not in st.members:
                st.members.append(r.label)
    return sorted(out.values(), key=lambda x: x.name)


def save_setup(setup: Setup, home: Optional[Path] = None) -> Path:
    d = setups_dir(home)
    d.mkdir(parents=True, exist_ok=True)
    f = d / f"{setup.name}.json"
    setup.created_at = setup.created_at or time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    f.write_text(json.dumps({"schema_version": 1, "name": setup.name, "instance": setup.instance,
                             "base_port": setup.base_port, "created_at": setup.created_at,
                             "members": sorted(set(setup.members))}, indent=2), encoding="utf-8")
    setup.path = str(f)
    return f


def record_found(records: list[InstalledRecord], setup_name: str, home: Optional[Path] = None) -> list[Path]:
    """The transition: installs the scan found but nobody recorded, written
    into the ledger under a setup name. Only the records handed in - the rest
    stay found-and-ignored. A recorded install that names no setup gets one."""
    d = ledger_dir(home)
    d.mkdir(parents=True, exist_ok=True)
    out: list[Path] = []
    for r in records:
        f = d / f"{r.label}.json"
        body: dict = {}
        if not r.derived and Path(r.path).is_file():
            try:
                body = json.loads(Path(r.path).read_text(encoding="utf-8-sig"))
            except (OSError, ValueError):
                body = {}
        body.update({
            "schema_version": 1, "service": r.service, "instance": r.instance,
            "package": body.get("package") or r.service, "version": r.version or body.get("version", ""),
            "host": r.host or body.get("host", "127.0.0.1"), "port": r.port, "url": r.url,
            "venv": r.venv, "config": r.config, "app_dir": r.app_dir,
            "launcher": body.get("launcher") or "", "autostart": body.get("autostart", False),
            "has_token": body.get("has_token", False), "extras": body.get("extras") or r.extras or {},
            "source": body.get("source") or "scan", "source_ref": body.get("source_ref", ""),
            "installed_at": body.get("installed_at") or "", "recorded_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "installer": body.get("installer") or "seren-starwright (recorded from scan)",
            "platform": body.get("platform") or ("Windows" if IS_WINDOWS else "unix"),
            "derived": False, "setup": setup_name,
        })
        f.write_text(json.dumps(body, indent=2), encoding="utf-8")
        r.derived = False
        r.setup = setup_name
        r.path = str(f)
        out.append(f)
    return out


def planned_config(svc: ServiceDef, cfg: dict, home: Optional[Path] = None) -> str:
    """Where THIS run will write the service's config, by the convention
    every card follows: ~/seren-<name><instance>/<name>.yaml."""
    inst = str(cfg.get("instance") or "")
    return str((home or Path.home()) / f"{svc.name}{inst}" / f"{svc.name}.yaml")


def apply_setup(setup: Setup, selected: list[str], svcs: dict[str, ServiceDef],
                per_service: dict[str, dict], installed: list[InstalledRecord]) -> None:
    """Fill each selected service in from the setup. A member already in the
    setup reinstalls in place (its instance, its port, its extras ticked); a
    new member takes the setup's instance and base + its family offset.
    Nothing the person already typed is overwritten."""
    by_label = {r.label: r for r in installed}
    for n in selected:
        cfg = per_service.setdefault(n, {})
        svc = svcs[n]
        member = next((by_label[m] for m in setup.members if m in by_label and by_label[m].service == n), None)
        if member is not None:
            if member.instance:
                cfg.setdefault("instance", member.instance)
            if member.port:
                cfg.setdefault("port", member.port)
            for flag, on in (member.extras or {}).items():
                if on and flag in svc.flags:
                    cfg.setdefault(flag, True)
        else:
            if setup.instance:
                cfg.setdefault("instance", setup.instance)
            off = band_offset(svc)
            if off is not None and not setup.is_default:
                cfg.setdefault("port", setup.base_port + off)


def wire_dependencies(selected: list[str], svcs: dict[str, ServiceDef], per_service: dict[str, dict],
                      installed: list[InstalledRecord], setup: Optional[Setup] = None,
                      home: Optional[Path] = None) -> None:
    """Anything that depends on another service gets that service's output
    fed to it. Preference: a card that takes <short>-config is handed the
    sibling's CONFIG PATH (url and bearer read by the card itself, no token
    on argv); one that only takes <short>-url gets the url. The sibling is,
    in order: one installed in this run (its planned config), a member of the
    setup, or the one installed instance on the box. Two candidates and no
    setup means the person chooses."""
    by_label = {r.label: r for r in installed}
    for n in selected:
        svc = svcs[n]
        cfg = per_service.setdefault(n, {})
        for req in svc.requires:
            short = req.replace("seren-", "", 1)
            cfg_flag, url_flag = f"{short}-config", f"{short}-url"
            if cfg.get(cfg_flag) or cfg.get(url_flag):
                continue
            path = url = ""
            if req in selected and req in svcs:
                path = planned_config(svcs[req], per_service.get(req, {}), home)
                port = per_service.get(req, {}).get("port") or svcs[req].default_port
                url = f"http://127.0.0.1:{port}"
            else:
                cands = [by_label[m] for m in (setup.members if setup else []) if m in by_label and by_label[m].service == req]
                if not cands and not setup:
                    cands = installed_for(req, installed)
                if len(cands) == 1:
                    path, url = cands[0].config, cands[0].url
            if not (path or url):
                continue
            if cfg_flag in svc.flags and path:
                cfg[cfg_flag] = path
            elif url_flag in svc.flags and url:
                cfg[url_flag] = url


def satisfied_dependencies(pulled: set[str], installed: list[InstalledRecord],
                           setup: Optional[Setup] = None) -> dict[str, list[InstalledRecord]]:
    """Which pulled-in dependencies are ALREADY on the box, and by what.
    Ticking the hippocampus used to drag a fresh default Memory into the run
    even when one was installed. A dependency the box already has is
    satisfied by it and wired, not reinstalled. With a setup chosen only its
    own members count; without one, any installed instance does."""
    by_label = {r.label: r for r in installed}
    out: dict[str, list[InstalledRecord]] = {}
    for n in pulled:
        if setup is not None:
            cands = [by_label[m] for m in setup.members if m in by_label and by_label[m].service == n]
        else:
            cands = installed_for(n, installed)
        if cands:
            out[n] = cands
    return out


def venv_prefix(rec: InstalledRecord) -> str:
    """What --venv was for this install. Every card names its venv
    <venv><instance>, so an instance install's prefix is its venv with the
    instance cut off. A default install used the card's own default: ""."""
    if rec.venv and rec.instance and rec.venv.endswith(rec.instance):
        return rec.venv[: -len(rec.instance)]
    return ""


def config_value(path: str, block: str, key: str) -> str:
    """One scalar out of an installed config, block.key, without a yaml
    parser (Starwright's own venv has none). Top-level blocks only."""
    try:
        text = Path(path).read_text(encoding="utf-8-sig", errors="replace")
    except OSError:
        return ""
    inside = False
    for line in text.splitlines():
        if re.match(rf"^{re.escape(block)}:\s*(#.*)?$", line):
            inside = True
            continue
        if inside and re.match(r"^[^\s#]", line):
            break
        if inside:
            m = re.match(rf"^\s+{re.escape(key)}:\s*(.*?)\s*(#.*)?$", line)
            if m:
                return m.group(1).strip().strip('"').strip("'")
    return ""


def prefill_reinstall(selected: list[str], svcs: dict[str, ServiceDef], per_service: dict[str, dict],
                      installed: list[InstalledRecord]) -> dict[str, InstalledRecord]:
    """A service installed again in place starts from how it is installed:
    its port and host, its venv, its autostart, the account it runs as, and
    the values in its config the card takes as flags (the hippocampus's
    model url...). Nothing the person already set is replaced. Its bearer is
    NOT read here - the card keeps the existing one itself unless told to
    generate or set another. Returns {service: the record it reinstalls}."""
    out: dict[str, InstalledRecord] = {}
    for n in selected:
        svc = svcs[n]
        cfg = per_service.setdefault(n, {})
        inst = str(cfg.get("instance") or "")
        rec = next((r for r in installed if r.service == n and r.instance == inst), None)
        if rec is None:
            continue
        out[n] = rec
        if rec.port and "port" in svc.flags:
            cfg.setdefault("port", rec.port)
        if rec.host and rec.host != svc.default_host and "host" in svc.flags:
            cfg.setdefault("host", rec.host)
        pre = venv_prefix(rec)
        if pre and "venv" in svc.flags:
            cfg.setdefault("venv", pre)
        if "service" in svc.flags and (rec.os_service or not rec.derived):
            cfg.setdefault("service", bool(rec.autostart))
        if rec.local_system is True and "local-system" in svc.flags:
            cfg.setdefault("local-system", True)
        elif rec.service_user and "service-user" in svc.flags:
            cfg.setdefault("service-user", rec.service_user)
        for extra, on in (rec.extras or {}).items():
            if on and extra in svc.flags:
                cfg.setdefault(extra, True)
        if rec.config:
            if "host" in svc.flags and "host" not in cfg:
                h = config_value(rec.config, "server", "host")
                if h and h != svc.default_host:
                    cfg["host"] = h
            for flag in svc.flags:
                if not flag.endswith("-url") or flag in cfg:
                    continue
                block = flag[: -len("-url")]
                if f"seren-{block}" in svc.requires:
                    continue                          # a dependency is wired, not copied
                v = config_value(rec.config, block, "url")
                if v:
                    cfg[flag] = v
    return out


def inherited_options(records: list[InstalledRecord]) -> dict:
    """The install options the records being built on agree about: where the
    wheels came from (the dev wheelhouse, a release tag), corporate TLS, and
    autostart. Adding a hippocampus to a brain installed from the dev
    wheelhouse as services should not start from PyPI and no autostart.
    Only what EVERY record says; a scanned record says nothing about source."""
    recs = [r for r in records if r.source and r.source not in ("scan",)]
    out: dict = {}
    if recs:
        pairs = {(r.source, r.source_ref) for r in recs}
        if len(pairs) == 1:
            src, ref = pairs.pop()
            if src == "local" and ref:
                out["local"] = ref
            elif src == "release" and ref:
                out["ref"] = ref
            elif src == "pypi":
                out["pypi"] = True
        if all(r.extras.get("corp") for r in recs):
            out["corp"] = True
    known = [r for r in records if r.os_service or not r.derived]
    if known and all(r.autostart for r in known):
        out["service"] = True
    prefixes = {venv_prefix(r) for r in records if r.instance}
    if len(prefixes) == 1 and "" not in prefixes:
        out["venv"] = prefixes.pop()
    ids = [r for r in records if r.local_system is not None]
    if ids and all(r.local_system for r in ids):
        out["local-system"] = True
    elif ids and len({r.service_user for r in ids}) == 1 and ids[0].service_user:
        out["service-user"] = ids[0].service_user
    return out


def wired_dependencies(svc: ServiceDef, cfg: dict) -> dict[str, str]:
    """The dependencies Starwright has already wired for this service:
    {"memory": "<config path or url>"}. Their flags need no answer."""
    out: dict[str, str] = {}
    for req in svc.requires:
        short = req.replace("seren-", "", 1)
        target = cfg.get(f"{short}-config") or cfg.get(f"{short}-url")
        if target:
            out[short] = str(target)
    return out


def dependency_notes(selected: list[str], svcs: dict[str, ServiceDef], per_service: dict[str, dict],
                     installed: list[InstalledRecord]) -> list[str]:
    """What each dependent will be wired to, or why it could not be."""
    out: list[str] = []
    for n in selected:
        short_n = n.replace("seren-", "", 1)
        for req in svcs[n].requires:
            short = req.replace("seren-", "", 1)
            cfg = per_service.get(n, {})
            target = cfg.get(f"{short}-config") or cfg.get(f"{short}-url")
            if req in selected:
                out.append(f"{short_n}: {short} is installed in this run and wired to it")
            elif target:
                out.append(f"{short_n}: wired to the installed {short} ({target})")
            else:
                cands = installed_for(req, installed)
                if len(cands) > 1:
                    out.append(f"{short_n}: {len(cands)} {short} instances installed ("
                               + ", ".join(installed_summary(r) for r in cands)
                               + f") - continue a setup that has one, or set {short}-config under Configure")
    return out


def setup_status(setup: Setup, svcs: dict[str, ServiceDef], installed: list[InstalledRecord]) -> str:
    have = sorted({r.service.replace("seren-", "", 1) for r in installed if r.label in setup.members})
    brain = [n for n, x in svcs.items() if x.group == "brain"]
    missing = sorted(x.replace("seren-", "", 1) for x in brain
                     if not any(r.service == x and r.label in setup.members for r in installed))
    return (f"setup '{setup.name}': base :{setup.base_port}" + (f", instance '{setup.instance}'" if setup.instance else "")
            + (" - has " + ", ".join(have) if have else " - no members yet")
            + (" - missing " + ", ".join(missing) if missing else ""))


def previous_install_data(installed: list[InstalledRecord], setups: list["Setup"],
                          picked: Optional["Setup"], svcs: dict[str, "ServiceDef"],
                          chosen: set[str]) -> list[str]:
    """Everything the box already has that bears on this run, in one place.

    Chad, 25 Sept: this was split between the top of the screen, the bottom
    and some of the cards. Continuing a setup shows that setup and nothing
    else - other installs are not called out unless this run adds a service
    that will be wired to one. Not continuing shows the whole box, by setup."""
    def line(r: InstalledRecord) -> str:
        return (f"  {r.service.replace('seren-', '', 1)} {installed_summary(r)}"
                + ("  (found, not recorded)" if r.derived else ""))

    out: list[str] = []
    if picked is not None:
        out.append(setup_status(picked, svcs, installed))
        out += [line(r) for r in installed if r.label in picked.members]
    elif installed:
        in_setup = {m: st.name for st in setups for m in st.members}
        groups: dict[str, list[InstalledRecord]] = {}
        for r in installed:
            groups.setdefault(in_setup.get(r.label, ""), []).append(r)
        for name in sorted(groups, key=lambda k: (k == "", k)):
            out.append(f"setup '{name}':" if name else "not in any setup:")
            out += [line(r) for r in groups[name]]
    else:
        out.append("nothing installed by Starwright on this box yet")

    pulled = resolve_dependencies(chosen, svcs) - chosen
    sat = satisfied_dependencies(pulled, installed, picked)
    for n, recs in sorted(sat.items()):
        out.append(f"will be used: {n.replace('seren-', '', 1)} "
                   f"({', '.join(installed_summary(r) for r in recs)})")
    missing = sorted(x.replace("seren-", "", 1) for x in pulled if x not in sat)
    if missing:
        out.append("pulled in as dependencies: " + ", ".join(missing))
    return out


def requirement_lines(members: list["ServiceDef"], svcs: dict[str, "ServiceDef"],
                      installed: list[InstalledRecord], picked: Optional["Setup"],
                      chosen: set[str]) -> list[str]:
    """'Hippocampus requires Memory to be installed', for each service in a
    group whose requirements are not met yet. Met = installed (in the picked
    setup, when there is one) or ticked in this run."""
    have = {r.service for r in installed if picked is None or r.label in picked.members}
    out = []
    for s in members:
        unmet = [r for r in s.requires if r not in have and r not in chosen]
        if unmet:
            names = [svcs[r].display if r in svcs else r.replace("seren-", "", 1) for r in unmet]
            out.append(f"{s.display} requires {' and '.join(names)} to be installed")
    return out


def installed_for(service: str, installed: list[InstalledRecord]) -> list[InstalledRecord]:
    return [r for r in installed if r.service == service]


def installed_summary(rec: InstalledRecord) -> str:
    v = f" v{rec.version}" if rec.version else ""
    port = f" :{rec.port}" if rec.port else ""
    inst = f"@{rec.instance}" if rec.instance else ""
    return f"{inst}{v}{port}".strip() or "installed"


def prefill_from_installed(svc: ServiceDef, cfg: dict, installed: list[InstalledRecord]) -> dict:
    """A service that needs another one gets that one's address filled in
    from the ledger - when exactly one instance is installed. The hippocampus
    needs Memory; if the box has one Memory, --memory-url is its url. Two
    Memories means the person chooses, so nothing is guessed."""
    for req in svc.requires:
        flag = req.replace("seren-", "", 1) + "-url"
        if flag in svc.flags and not cfg.get(flag):
            recs = [r for r in installed_for(req, installed) if r.port]
            if len(recs) == 1:
                cfg[flag] = recs[0].url
    return cfg


def reinstall_notes(selected: list[str], overrides: dict[str, dict],
                    installed: list[InstalledRecord], beside: bool = True) -> list[str]:
    """Which of the chosen services are already here, and whether this run
    lands on top of one (same instance) or beside it (a new instance).
    beside=False (continuing a setup) leaves the other installs out: they are
    not this setup's business."""
    out: list[str] = []
    for n in selected:
        recs = installed_for(n, installed)
        if not recs:
            continue
        inst = str(overrides.get(n, {}).get("instance") or "")
        same = [r for r in recs if r.instance == inst]
        others = [r for r in recs if r.instance != inst]
        short = n.replace("seren-", "", 1)
        if same:
            out.append(f"{short}: already installed here ({installed_summary(same[0])}) - this run re-installs it "
                       f"in place (the config is backed up); set an instance name under Advanced to install side by side")
        elif others and beside:
            out.append(f"{short}: installing instance '{inst}' beside " +
                       ", ".join(installed_summary(r) for r in others))
    return out


def port_conflicts(selected: list[str], svcs: dict[str, ServiceDef],
                   overrides: dict[str, dict],
                   installed: Optional[list[InstalledRecord]] = None) -> list[str]:
    """Catch two services landing on one port BEFORE anything is installed.

    Starwright is the only thing that can see this: each installer knows only
    its own port and can't warn about a neighbour it never hears about. With
    the ledger it also sees what is ALREADY on the box: a port held by an
    installed instance is taken, unless this run is that same instance
    re-installing itself.
    """
    seen: dict[int, str] = {}
    out: list[str] = []
    for n in selected:
        port = int(overrides.get(n, {}).get("port") or svcs[n].default_port)
        if port in seen:
            out.append(f"port {port}: {seen[port]} and {n} collide")
        else:
            seen[port] = n
        inst = str(overrides.get(n, {}).get("instance") or "")
        for rec in installed or []:
            if rec.port == port and not (rec.service == n and rec.instance == inst):
                out.append(f"port {port}: {n} would collide with installed {rec.label}")
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

    # LocalSystem and a named account are exclusive. The per-service answer
    # beats the universal one: a reinstall of a LocalSystem service keeps
    # LocalSystem even when the universal account box holds a user.
    if cfg.get("local-system"):
        merged.pop("service-user", None)
    elif cfg.get("service-user"):
        merged.pop("local-system", None)
    elif merged.get("local-system"):
        merged.pop("service-user", None)

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
# The wordmark: a lit lantern, then SEREN, then STARWRIGHT under it.
# Letterforms are the ASCII font called Medium.
#
# ONE BANNER, ON PURPOSE. There used to be a wide 96-column variant with a
# width<90 switch to this one, and it had gone quietly unreachable: compose()
# yielded the narrow art and on_mount only ever "switched" to the same thing,
# so the wide version rendered at no terminal size at all. Worse, four numbers
# that had to agree didn't - the art was 96 wide, the comment said 85, the
# switch fired at 90, and #splash was pinned to 92. Restoring it would have
# put 96 columns of art into a 92-column box, which IS the bug that once
# shoved the Install button off the side of an SSH session.
#
# This one is 38 columns. It fits the 80-column headless terminal this whole
# tool exists to be used from, so there is nothing left to switch between and
# no threshold left to drift.
BANNER = r"""
 ╭====╮  ╓─────┐ ╥──┐ ╥──┐ ╥──┐ ╓──┐
 ╱╮..╭╲  ║       ╟─   ╟─┬┘ ╟─   ║  │
 │(ᶓᶔ)│  ╙─────┐ ╨──┘ ╨ ┴  ╨──┘ ╨  ┴
╭│─ᴽᴽ─│╮       │                    
╰──────╯ ╙─────┘ S T A R W R I G H T
"""


class SplashScreen(Screen):
    """Mode selector. Node work and Install Services share almost no config
    surface, so they get separate doors rather than one overloaded grid.

    NODE WORK IS TWO DOORS, NOT ONE. There used to be a single "Prepare Node",
    and one door meant one screen that had to offer everything - foundation prep,
    a hostname field, components - with nothing but a checkbox between "add
    Ms.MoE to a working box" and "rebuild this machine and rename it".

    The two paths are genuinely different acts on genuinely different machines:

      INSTALL  a box that is not set up yet. Base prep runs, because that IS the
               job; you may name the machine; you pick components.
      MODIFY   a box that already works. Components only. Prep and rename are
               not on the screen at all, so neither can happen by accident.

    Choosing before any control renders is the point - a mode picked afterwards
    still has to draw the dangerous widgets.
    """

    def compose(self) -> ComposeResult:
        yield Header()
        with Center():
            with Vertical(id="splash"):
                yield Static(BANNER, id="banner")
                yield Static("build the vessel · sail by the lodestar",
                             id="tagline")
                yield Static("", id="splash-note")
                with Horizontal(id="splash-node-row"):
                    yield Button("Install Node", id="install-node",
                                 variant="default")
                    yield Button("Modify Node", id="modify-node",
                                 variant="default")
                yield Button("Install Services", id="install", variant="primary")
                yield Button("Exit", id="exit", variant="error")
        yield Footer()

    def on_mount(self) -> None:
        node = self.app.node                            # type: ignore[attr-defined]
        # Honest about what isn't available: node prep is bash-only, so on
        # Windows both doors say so instead of failing when pressed.
        self.query_one("#install-node", Button).disabled = node is None
        # MODIFY IS GATED ON THE NODE ACTUALLY BEING PREPARED, because Modify
        # cannot prep - it has no such control by design. Offering it on a bare
        # box would hand someone a component install onto a machine with no CUDA,
        # no Python and no NVMe, which fails somewhere far from the cause. The
        # note below names Install as the way in.
        self.query_one("#modify-node", Button).disabled = (
            node is None or not node.provisioned)

        n = len(self.app.services)                      # type: ignore[attr-defined]
        # First token only. resolve_version() appends an explanatory tail
        # ("(from git)", "(no build stamp, not a git checkout)") which is right
        # for --version and far too long for a splash line. No "v" prefix -
        # tags already carry one and "vunknown" reads like a typo.
        note = f"{resolve_version().split(' ')[0]}  ·  {n} installer(s) discovered"
        # The node's prep state belongs HERE, on the screen where you choose a
        # door, not two screens later. It is the fact that decides which door.
        if node is not None:
            note += f" · {node.platform or 'platform?'}"
            if node.provisioned:
                note += " · prepared"
                if node.provisioned_at:
                    note += f" {node.provisioned_at.split('T')[0]}"
            else:
                note += " · never prepared - use Install"
        if self.app.problems:                           # type: ignore[attr-defined]
            note += f" · {len(self.app.problems)} problem(s) - see Install"
        self.query_one("#splash-note", Static).update(note)

        # No banner switch here any more - see the note above BANNER. There is
        # one wordmark, it is 38 columns, and it fits everywhere this runs.

    def on_button_pressed(self, event: Button.Pressed) -> None:
        if event.button.id == "install":
            self.app.push_screen(SelectScreen())
        elif event.button.id == "install-node":
            self.app.push_screen(PrepareNodeScreen(mode="install"))
        elif event.button.id == "modify-node":
            self.app.push_screen(PrepareNodeScreen(mode="modify"))
        elif event.button.id == "exit":
            self.app.exit()


class ServiceCard(Vertical):
    """One selectable service: a checkbox and a description, one size.
    What is installed lives in the Previous install data panel and what a
    service needs lives under its group - not on the card."""

    def __init__(self, svc: ServiceDef, installed: Optional[list[InstalledRecord]] = None) -> None:
        super().__init__(classes="card")
        self.svc = svc
        self.installed = list(installed or [])

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
        desc = Static(self.svc.description, classes="card-desc")
        desc.tooltip = self.svc.description          # clamped to two lines on the card
        yield desc


class SelectScreen(Screen):
    """The grid. Groups with a parent checkbox that toggles its children."""

    BINDINGS = [("escape", "app.pop_screen", "Back")]

    def compose(self) -> ComposeResult:
        yield Header()
        with VerticalScroll(id="select-root"):
            # -- the setup: who or what this install is for ----------------
            app = self.app                                                  # type: ignore[assignment]
            found = [r for r in app.installed if r.derived]                 # type: ignore[attr-defined]
            setup_box = Vertical(id="setup-box")
            setup_box.border_title = "Setup"
            with setup_box:
                with Horizontal(classes="setup-row"):
                    yield Checkbox("continue a previous setup", id="use-setup",
                                   disabled=not app.setups)                 # type: ignore[attr-defined]
                    yield Select([(f"{st.name}  (base :{st.base_port}, {len(st.members)} member{'s' if len(st.members) != 1 else ''})", st.name)
                                  for st in app.setups],                     # type: ignore[attr-defined]
                                 prompt="previous setup", id="setup-pick", disabled=True)
                with Horizontal(classes="setup-row", id="setup-fields"):
                    yield Label("name")
                    yield Input(value=time.strftime("%Y-%m-%d"), id="setup-name")
                    yield Label("port base")
                    # The family's own band by default: adding a hippocampus to what is
                    # already here should not quietly become a side-by-side instance
                    # named after today. A new band is a choice, so it is a hint.
                    # Digits only: a port is a number, and a stray letter used to
                    # fall back to the default band without a word.
                    yield Input(value=str(FAMILY_BASE), id="setup-base", restrict=r"[0-9]*", max_length=5)
                yield Static("", id="setup-warn")
                prev = Vertical(id="prev-box")
                prev.border_title = "Previous install data"
                with prev:
                    yield Static("", id="setup-note", classes="card-inst")
                    if app.installed:                                            # type: ignore[attr-defined]
                        yield Static(f"port base {FAMILY_BASE} = the default instance; for a separate set beside it, "
                                     f"the next free band is {suggest_base(app.installed, app.setups)}",   # type: ignore[attr-defined]
                                     classes="modal-sub")
                    if found:
                        yield Button(f"record {len(found)} found install{'s' if len(found) != 1 else ''}...", id="record-found",
                                     variant="default")
            for key, title in _ordered_groups(self.app.services):          # type: ignore[attr-defined]
                members = [s for s in self.app.services if s.group == key]  # type: ignore[attr-defined]
                if not members:
                    continue
                group = Vertical(classes="group")
                group.border_title = title
                with group:
                    yield Checkbox("all of these", id=f"grp-{key}", classes="group-head")
                    # A grid, not a row: a row never wraps, so the brain's five
                    # cards ran off the right edge. At most three across; fewer
                    # when the terminal is narrow (see _fit_columns).
                    with Grid(classes="cards"):
                        for svc in members:
                            yield ServiceCard(svc, installed_for(svc.name, self.app.installed))  # type: ignore[attr-defined]
                    yield Static("", id=f"req-{key}", classes="card-req")
            yield Static("", id="dep-note")
        with Horizontal(id="actions"):
            yield Button("Quit", id="quit", variant="error")
            yield Button("Back", id="back", variant="default")
            yield Button("Next", id="next", variant="primary")
        yield Footer()

    CARD_CELL = 36                                   # card width 34 + a 2-column gutter

    def on_mount(self) -> None:
        self._refresh_panel()

    def on_resize(self, event) -> None:              # noqa: ANN001 - textual's Resize
        self._fit_columns(event.size.width)

    def _fit_columns(self, width: int) -> None:
        """At most three cards across, and never more than fit: 80 columns
        takes two. The 8 is the screen's and the group's padding and borders;
        the last card needs no gutter after it, hence + 2."""
        n = max(1, min(3, (width - 8 + 2) // self.CARD_CELL))
        for g in self.query(".cards"):
            g.styles.grid_size_columns = n

    def _refresh_panel(self) -> None:
        """The Previous install data panel and each group's requirement lines,
        from what is installed, the setup picked and what is ticked."""
        app = self.app
        picked, chosen = self._picked_setup(), self._selected()
        try:
            self.query_one("#setup-note", Static).update("\n".join(previous_install_data(
                app.installed, app.setups, picked, app.svc_map, chosen)))   # type: ignore[attr-defined]
        except Exception:                                # noqa: BLE001 - not composed yet
            return
        for key, _ in _ordered_groups(app.services):     # type: ignore[attr-defined]
            members = [s for s in app.services if s.group == key]   # type: ignore[attr-defined]
            try:
                self.query_one(f"#req-{key}", Static).update("\n".join(requirement_lines(
                    members, app.svc_map, app.installed, picked, chosen)))   # type: ignore[attr-defined]
            except Exception:                            # noqa: BLE001 - a group with no members has no line
                pass

    def _name_clash(self) -> Optional[str]:
        """A NEW setup may not take an existing setup's name: saving it would
        overwrite that setup's record."""
        if self._picked_setup() is not None:
            return None
        name = (self.query_one("#setup-name", Input).value or "").strip()
        clash = next((st.name for st in self.app.setups if st.name.lower() == name.lower()), None)   # type: ignore[attr-defined]
        return clash

    def on_input_changed(self, event: Input.Changed) -> None:
        if (event.input.id or "") != "setup-name":
            return
        clash = self._name_clash()
        self.query_one("#setup-warn", Static).update(
            f"a setup named '{clash}' already exists - tick 'continue a previous setup' to add to it, "
            f"or pick another name" if clash else "")

    # -- the setup picker ---------------------------------------------------
    def _picked_setup(self) -> Optional[Setup]:
        try:
            if not self.query_one("#use-setup", Checkbox).value:
                return None
            v = self.query_one("#setup-pick", Select).value
        except Exception:                                # noqa: BLE001
            return None
        if not isinstance(v, str) or not v:
            return None                              # blank, whatever this Textual spells it
        return next((st for st in self.app.setups if st.name == v), None)   # type: ignore[attr-defined]

    def on_select_changed(self, event: Select.Changed) -> None:
        if (event.select.id or "") != "setup-pick":
            return
        st = self._picked_setup()
        name, base = self.query_one("#setup-name", Input), self.query_one("#setup-base", Input)
        if st is None:
            name.disabled = False; base.disabled = False
            self._refresh_panel()
            return
        name.value, base.value = st.name, str(st.base_port)
        name.disabled = True; base.disabled = True
        self.query_one("#setup-warn", Static).update("")
        self._refresh_panel()

    def current_setup(self) -> Setup:
        """The setup this run installs into: the one picked, or a new one
        named on this screen (the date when nobody typed a name). A new
        setup on the family's own band is the default instance; any other
        band makes the name the instance, so it lives beside."""
        st = self._picked_setup()
        if st is not None:
            return st
        name = (self.query_one("#setup-name", Input).value or "").strip() or time.strftime("%Y-%m-%d")
        try:
            base = int((self.query_one("#setup-base", Input).value or "").strip() or FAMILY_BASE)
        except ValueError:
            base = FAMILY_BASE
        inst = "" if base == FAMILY_BASE else sanitize_instance(name)
        return Setup(name=name, instance=inst, base_port=base)

    # -- group checkbox toggles its children ------------------------------
    def on_checkbox_changed(self, event: Checkbox.Changed) -> None:
        cid = event.checkbox.id or ""
        if cid == "use-setup":
            pick = self.query_one("#setup-pick", Select)
            pick.disabled = not event.value
            if not event.value:
                # clear(), not `value = Select.BLANK`: the sentinel's spelling
                # differs across Textual versions and the bundled runner raised
                # "Illegal select value False" on the assignment.
                try:
                    pick.clear()
                except Exception:                    # noqa: BLE001
                    pass
                self.query_one("#setup-name", Input).disabled = False
                self.query_one("#setup-base", Input).disabled = False
            self._refresh_panel()
            return
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
        self.query_one("#dep-note", Static).update("")
        self._refresh_panel()

    def _after_record(self, result: Optional[dict]) -> None:
        if not result:
            return
        self.app.setups = load_setups(installed=self.app.installed)      # type: ignore[attr-defined]
        try:
            self._refresh_panel()
            self.query_one("#setup-warn", Static).update(
                f"recorded {result.get('count', 0)} install(s) into setup '{result.get('name', '')}'")
            self.query_one("#use-setup", Checkbox).disabled = not self.app.setups   # type: ignore[attr-defined]
            pick = self.query_one("#setup-pick", Select)
            pick.set_options([(f"{st.name}  (base :{st.base_port}, {len(st.members)} member{'s' if len(st.members) != 1 else ''})", st.name)
                              for st in self.app.setups])                  # type: ignore[attr-defined]
            btn = self.query_one("#record-found", Button)
            left = [r for r in self.app.installed if r.derived]            # type: ignore[attr-defined]
            btn.label = f"record {len(left)} found install{'s' if len(left) != 1 else ''}..."
            btn.disabled = not left
        except Exception:                                # noqa: BLE001
            pass

    def on_button_pressed(self, event: Button.Pressed) -> None:
        if event.button.id == "quit":
            self.app.exit()
        elif event.button.id == "back":
            self.app.pop_screen()
        elif event.button.id == "record-found":
            found = [r for r in self.app.installed if r.derived]           # type: ignore[attr-defined]
            self.app.push_screen(RecordFoundModal(found, (self.query_one("#setup-name", Input).value or "").strip()),
                                 self._after_record)
        elif event.button.id == "next":
            chosen = self._selected()
            if not chosen:
                self.query_one("#dep-note", Static).update(
                    "nothing selected - pick at least one service")
                return
            clash = self._name_clash()
            if clash:
                self.query_one("#dep-note", Static).update(
                    f"a setup named '{clash}' already exists - continue it, or pick another name")
                return
            full = resolve_dependencies(chosen, self.app.svc_map)   # type: ignore[attr-defined]
            st = self.current_setup()
            picked = self._picked_setup()
            self.app.continuing = picked is not None                        # type: ignore[attr-defined]
            # A dependency the box already has is satisfied by it: wired, not
            # reinstalled. Only a missing one joins the run.
            sat = satisfied_dependencies(full - chosen, self.app.installed, picked)   # type: ignore[attr-defined]
            full -= set(sat)
            self.app.selected = install_order(full, self.app.svc_map)  # type: ignore[attr-defined]
            # The setup fills the run in: instance, ports, extras of existing
            # members; a service installed again in place starts from how it
            # IS installed; then every dependent is wired to the sibling it
            # needs (its config path when the card can read one).
            self.app.setup = st                                             # type: ignore[attr-defined]
            apply_setup(st, self.app.selected, self.app.svc_map, self.app.per_service, self.app.installed)  # type: ignore[attr-defined]
            self.app.reinstalls = prefill_reinstall(self.app.selected, self.app.svc_map,  # type: ignore[attr-defined]
                                                    self.app.per_service, self.app.installed)  # type: ignore[attr-defined]
            wire_dependencies(self.app.selected, self.app.svc_map, self.app.per_service,   # type: ignore[attr-defined]
                              self.app.installed, picked)                   # type: ignore[attr-defined]
            # What this run is built on - the installs satisfying its
            # dependencies, the picked setup's members, and what it reinstalls -
            # sets the defaults of everything new in it.
            base = [r for recs in sat.values() for r in recs]
            if picked is not None:
                base += [r for r in self.app.installed if r.label in picked.members and r not in base]   # type: ignore[attr-defined]
            base += [r for r in self.app.reinstalls.values() if r not in base]   # type: ignore[attr-defined]
            self.app.inherited = inherited_options(base)                  # type: ignore[attr-defined]
            for n in self.app.selected:                                    # type: ignore[attr-defined]
                if n in self.app.reinstalls:                               # type: ignore[attr-defined]
                    continue
                cfg = self.app.per_service.setdefault(n, {})              # type: ignore[attr-defined]
                flags = self.app.svc_map[n].flags                          # type: ignore[attr-defined]
                if self.app.inherited.get("service") and "service" in flags:   # type: ignore[attr-defined]
                    cfg.setdefault("service", True)
                if self.app.inherited.get("venv") and "venv" in flags and cfg.get("instance"):   # type: ignore[attr-defined]
                    cfg.setdefault("venv", self.app.inherited["venv"])     # type: ignore[attr-defined]
            self.app.push_screen(ConfigScreen())


class RecordFoundModal(ModalScreen[dict]):
    """Installs the scan found and nobody recorded: tick the ones to put in
    the ledger under a setup name. The rest stay found-and-ignored."""

    BINDINGS = [("escape", "dismiss(None)", "Cancel")]

    def __init__(self, found: list[InstalledRecord], setup_name: str = "") -> None:
        super().__init__()
        self.found = found
        self.setup_name = setup_name or time.strftime("%Y-%m-%d")

    def compose(self) -> ComposeResult:
        with Vertical(id="modal"):
            yield Static("Record found installs", classes="modal-title")
            yield Static("These were found under ~/seren-*/ but no installer recorded them. "
                         "Tick the ones that belong together and give the setup a name; the "
                         "others are left alone.", classes="modal-sub")
            # The list scrolls; the name and the buttons never leave the screen.
            # Ten found installs on one box is normal, and the first cut put the
            # Record button below the bottom edge.
            with VerticalScroll(id="modal-body"):
                yield Checkbox("tick all", id="rec-all")
                for i, r in enumerate(self.found):
                    yield Checkbox(f"{r.label}  {installed_summary(r)}  ({r.app_dir})", id=f"rec-{i}")
            yield Label("setup name (who or what these are for)")
            yield Input(value=self.setup_name, id="rec-name")
            with Horizontal(id="modal-actions"):
                yield Button("Cancel", id="cancel", variant="default")
                yield Button("Record ticked as this setup", id="ok", variant="primary")

    def on_checkbox_changed(self, event: Checkbox.Changed) -> None:
        if (event.checkbox.id or "") == "rec-all":
            for i in range(len(self.found)):
                self.query_one(f"#rec-{i}", Checkbox).value = event.value

    def on_button_pressed(self, event: Button.Pressed) -> None:
        if event.button.id == "cancel":
            self.dismiss(None)
            return
        name = (self.query_one("#rec-name", Input).value or "").strip() or time.strftime("%Y-%m-%d")
        picked = [r for i, r in enumerate(self.found) if self.query_one(f"#rec-{i}", Checkbox).value]
        if not picked:
            self.dismiss(None)
            return
        record_found(picked, name)
        setups = {st.name: st for st in self.app.setups}                  # type: ignore[attr-defined]
        st = setups.get(name) or Setup(name=name, base_port=min((r.port for r in picked if r.port), default=FAMILY_BASE))
        for r in picked:
            if r.label not in st.members:
                st.members.append(r.label)
        save_setup(st)
        self.dismiss({"name": name, "count": len(picked)})


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

    def __init__(self, svc: ServiceDef, current: dict,
                 identity_defaults: Optional[dict] = None,
                 current_password: str = "") -> None:
        super().__init__()
        self.svc = svc
        self.current = dict(current)
        # What the universal section answered. Shown as PLACEHOLDER text on the
        # identity fields, so "leave it alone" visibly means "same as the rest"
        # rather than looking like an empty, unanswered box.
        self.identity_defaults = dict(identity_defaults or {})
        self.current_password = current_password

    def compose(self) -> ComposeResult:
        with Vertical(id="modal"):
            yield Static(f"Advanced · {self.svc.display}", classes="modal-title")
            yield Static(f"{self.svc.package}  ·  default port "
                         f"{self.svc.default_port}", classes="modal-sub")
            with VerticalScroll(id="modal-body"):
                # -- service identity ---------------------------------------
                # A hand-built group rather than letting these fall through the
                # generic loop below, for two reasons that both produce broken
                # commands otherwise: `local-system` is a SWITCH and the generic
                # loop would render it as a text box (emitting `-LocalSystem
                # <text>`, which PowerShell refuses), and the password must be
                # masked and must never become a flag at all.
                svc_identity = [f for f in IDENTITY_FLAGS if f in self.svc.flags]
                if svc_identity:
                    yield Static("Service identity", classes="section")
                    yield Static("blank = use the universal answer",
                                 classes="modal-sub")
                    if "local-system" in svc_identity:
                        yield Checkbox("run as LocalSystem (no password)",
                                       value=bool(self.current.get("local-system")),
                                       id="adv-local-system")
                    if "service-user" in svc_identity:
                        yield Label("service account")
                        yield Input(
                            value=str(self.current.get("service-user", "")),
                            placeholder=str(self.identity_defaults.get(
                                "service-user", "")) or "(universal)",
                            id="adv-service-user")
                        if IS_WINDOWS:
                            yield Label("password")
                            yield Input(value=self.current_password,
                                        password=True,
                                        placeholder="(universal)",
                                        id="adv-service-password")
                    yield Rule()
                # A dependency Starwright already wired needs no answer: one
                # line says where it points, its url / token / config boxes
                # stay folded away unless the person asks to set it by hand.
                rec = (getattr(self.app, "reinstalls", {}) or {}).get(self.svc.name)
                if rec is not None:
                    yield Static(f"reinstalling {rec.label} in place ({installed_summary(rec)}): its existing "
                                 f"bearer token is kept - tick 'generate a bearer token' only to rotate it",
                                 classes="card-inst")
                wired = wired_dependencies(self.svc, self.current)
                folded = {f for short in wired for f in self.svc.advanced_flags
                          if f.startswith(f"{short}-")}
                for short, target in wired.items():
                    yield Static(f"{short}: wired to the installed {short} ({target}) - its url and "
                                 f"bearer are read from its own config", classes="card-inst")
                    yield Checkbox(f"set {short} by hand", id=f"adv-manual-{short}")
                    with Vertical(id=f"adv-grp-{short}", classes="adv-folded"):
                        for flag in [f for f in self.svc.advanced_flags if f in folded and f.startswith(f"{short}-")]:
                            yield Label(flag)
                            yield Input(value=str(self.current.get(flag, "")), placeholder="(unset)",
                                        id=f"adv-{flag}")
                    yield Rule()
                for flag in self.svc.advanced_flags:
                    if flag in folded:
                        continue
                    if flag in ("gen-token",):
                        yield Checkbox("generate a bearer token",
                                       value=bool(self.current.get(flag)),
                                       id=f"adv-{flag}")
                        continue
                    if self.svc.is_switch(flag):
                        # A switch is a check box. As a text box it produced
                        # `--no-updates yes`, which every card refuses: the
                        # flag takes no value, and the card said so via
                        # --describe's `switches`.
                        yield Checkbox(flag, value=bool(self.current.get(flag)),
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

    def on_checkbox_changed(self, event: Checkbox.Changed) -> None:
        cid = event.checkbox.id or ""
        if cid.startswith("adv-manual-"):
            try:
                self.query_one(f"#adv-grp-{cid[len('adv-manual-'):]}").display = bool(event.value)
            except Exception:                            # noqa: BLE001
                pass

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
        # Every rendered flag reports, a cleared one as None. The screen used to
        # merge only what was set, so a value could be added but never taken
        # back: an instance name typed once stuck for the rest of the session,
        # and an unticked box changed nothing. None means "remove it".
        out: dict[str, Any] = {}
        for flag in self.svc.advanced_flags:
            try:
                w = self.query_one(f"#adv-{flag}")
            except Exception:                            # noqa: BLE001
                continue
            if isinstance(w, Checkbox):
                out[flag] = True if w.value else None
            elif isinstance(w, Input):
                out[flag] = w.value.strip() or None

        # Identity, read explicitly - the widgets aren't uniform, so the loop
        # above can't collect them. Each lookup is guarded because a given
        # installer may not declare the flag at all, in which case the widget
        # was never composed.
        try:
            out["local-system"] = True if self.query_one("#adv-local-system", Checkbox).value else None
        except Exception:                            # noqa: BLE001
            pass
        try:
            w = self.query_one("#adv-service-user", Input)
            out["service-user"] = w.value.strip() or None
        except Exception:                            # noqa: BLE001
            pass
        try:
            # Reserved key. The caller POPS this before anything is merged into
            # per_service - that dict is handed straight to build_command, so a
            # password left in it would become a command-line argument, which is
            # the exact thing this whole design avoids.
            out["_password"] = self.query_one("#adv-service-password", Input).value
        except Exception:                            # noqa: BLE001
            pass
        self.dismiss(out)


class ConfigScreen(Screen):
    """Universal options up top, then a row per selected service."""

    BINDINGS = [("escape", "app.pop_screen", "Back")]

    def on_mount(self) -> None:
        """Start from how the installs this run builds on were done: their
        wheel source, their TLS, and say so - rather than PyPI and defaults,
        which would quietly install the new piece from somewhere else."""
        inh = getattr(self.app, "inherited", {}) or {}
        said = []
        try:
            if inh.get("local"):
                self.query_one("#u-local", Input).value = inh["local"]
                self.query_one("#u-pypi", Checkbox).value = False
                said.append(f"dev wheelhouse {inh['local']}")
            elif inh.get("ref"):
                self.query_one("#u-ref", Input).value = inh["ref"]
                self.query_one("#u-pypi", Checkbox).value = False
                said.append(f"release {inh['ref']}")
            if inh.get("corp"):
                self.query_one("#u-corp", Checkbox).value = True
                said.append("corporate TLS")
            if inh.get("service"):
                said.append("autostart")
            if inh.get("venv"):
                self.query_one("#u-venv", Input).value = inh["venv"]
                said.append(f"venv {inh['venv']}")
            if inh.get("local-system"):
                try:
                    self.query_one("#u-local-system", Checkbox).value = True
                    said.append("LocalSystem")
                except Exception:                    # noqa: BLE001 - off Windows there is no such box
                    pass
            elif inh.get("service-user"):
                self.query_one("#u-service-user", Input).value = inh["service-user"]
                said.append(f"account {inh['service-user']}")
            re_ = getattr(self.app, "reinstalls", {}) or {}
            if re_:
                said.append("reinstalling in place: " + ", ".join(n.replace("seren-", "") for n in re_)
                            + " (their bearer tokens are kept)")
            if said:
                self.query_one("#cfg-inherited", Static).update(
                    "taken from the installs this builds on: " + ", ".join(said) + " (change any of it here)")
        except Exception:                                # noqa: BLE001
            pass

    def compose(self) -> ComposeResult:
        yield Header()
        with VerticalScroll(id="config-root"):
            prev = Vertical(id="cfg-prev-box")
            prev.border_title = "Previous install data"
            with prev:
                yield Static("", id="cfg-inherited", classes="card-inst")
                yield Static("\n".join(
                    reinstall_notes(self.app.selected, self.app.per_service, self.app.installed,   # type: ignore[attr-defined]
                                    beside=not getattr(self.app, "continuing", False))
                    + dependency_notes(self.app.selected, self.app.svc_map, self.app.per_service,   # type: ignore[attr-defined]
                                       self.app.installed)),                                        # type: ignore[attr-defined]
                    id="cfg-installed", classes="card-inst")
            yield Static("Universal install options", classes="section")
            yield Label("venv root")
            yield Input(placeholder="~/seren-venvs", id="u-venv")
            yield Checkbox("corporate TLS / intercepting proxy (--corp)", id="u-corp")
            yield Checkbox("install from PyPI (--pypi)", value=True, id="u-pypi")
            yield Label("or pin a GitHub release tag (--ref, blank = PyPI)")
            yield Input(placeholder="v1.5.0", id="u-ref")
            # The dev loop: seren-dev-publish builds every checkout into one
            # wheelhouse; a card pointed at it installs the dev wheel and pins
            # the other seren-* dev wheels alongside. A folder on this box, or
            # the URL --serve prints on the dev box. Beats a tag and PyPI.
            yield Label("or a dev wheelhouse from seren-dev-publish (--local: a folder, "
                        "or http://devbox:8765 - beats a tag and PyPI)")
            yield Input(placeholder="../.dev-wheelhouse", id="u-local")

            # -- service identity -------------------------------------------
            # Asked once here and inherited by every service; override one
            # service under its Configure button. Only has any effect on
            # services you tick 'service' on.
            #
            # Windows-only for the password and the LocalSystem box: a systemd
            # unit's User= is just a name, there is no credential to collect,
            # and LocalSystem has no counterpart (running as root is simply
            # --service-user root).
            yield Static("Service account", classes="section")
            yield Static(
                "Used by any service installed with 'service' ticked. A service "
                "running as the wrong account resolves ~ to a different profile - "
                "it comes up healthy and its data store looks empty.",
                classes="modal-sub")
            if IS_WINDOWS:
                yield Checkbox("run services as LocalSystem (no password)",
                               id="u-local-system")
            yield Label("service account")
            yield Input(value=default_service_account(), id="u-service-user")
            if IS_WINDOWS:
                yield Label("password (never logged, never on a command line)")
                yield Input(password=True, id="u-service-password")
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
                                box = Checkbox(INLINE_LABELS.get(flag, flag),
                                               value=bool(self.app.per_service.get(name, {}).get(flag)),  # type: ignore[attr-defined]
                                               id=f"f-{name}-{flag}")
                                if flag in INLINE_TIPS:
                                    box.tooltip = INLINE_TIPS[flag]
                                yield box
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
            # Refresh the universal answers BEFORE opening the dialog, so its
            # identity placeholders show what's currently typed on this screen
            # rather than whatever was there the last time Install was pressed.
            self._collect()
            cur = self.app.per_service.get(name, {})     # type: ignore[attr-defined]
            self.app.push_screen(
                AdvancedModal(svc, cur, self.app.universal,          # type: ignore[attr-defined]
                              self.app.service_passwords.get(name, "")),  # type: ignore[attr-defined]
                lambda res, n=name: self._save_adv(n, res))
        elif bid == "go":
            self._collect()
            warn = port_conflicts(self.app.selected, self.app.svc_map,       # type: ignore[attr-defined]
                                  self.app.per_service, self.app.installed)  # type: ignore[attr-defined]
            if warn:
                self.query_one("#cfg-warn", Static).update(
                    "  ".join(warn) + "  - change a port under Configure")
                return
            st = getattr(self.app, "setup", None)
            if st is not None:
                # The setup file knows its members before the first card runs,
                # so a run that dies halfway still leaves the set named.
                for n in self.app.selected:                                    # type: ignore[attr-defined]
                    inst = str(self.app.per_service.get(n, {}).get("instance") or "")   # type: ignore[attr-defined]
                    label = f"{n}@{inst}" if inst else n
                    if label not in st.members:
                        st.members.append(label)
                try:
                    save_setup(st)
                except OSError:
                    pass
            self.app.jobs = [                                  # type: ignore[attr-defined]
                Job(label=self.app.svc_map[n].display,         # type: ignore[attr-defined]
                    cmd=build_command(self.app.svc_map[n],     # type: ignore[attr-defined]
                                      self.app.per_service.get(n, {}),  # type: ignore[attr-defined]
                                      self.app.universal),     # type: ignore[attr-defined]
                    env=self._job_env(n))
                for n in self.app.selected                     # type: ignore[attr-defined]
            ]
            self.app.push_screen(InstallScreen())

    # -- identity plumbing -----------------------------------------------
    def on_checkbox_changed(self, event: Checkbox.Changed) -> None:
        """LocalSystem and a user/password pair are mutually exclusive.

        Disabling rather than hiding, deliberately: the fields stay visible so
        it's obvious WHY they no longer apply, instead of the form silently
        losing two rows and looking like it forgot something.
        """
        if (event.checkbox.id or "") != "u-local-system":
            return
        for wid in ("#u-service-user", "#u-service-password"):
            try:
                self.query_one(wid, Input).disabled = event.value
            except Exception:                            # noqa: BLE001
                pass

    def _job_env(self, name: str) -> dict[str, str]:
        """The extra environment one installer subprocess gets.

        SEREN_NONINTERACTIVE is set unconditionally. Starwright always runs
        installers with their stdout on a pipe, so a credential prompt would
        hang forever behind a TUI that owns the terminal. Stating it outright
        beats making the scripts infer it: they refuse with instructions
        instead of stalling with no output at all.

        A per-service password beats the universal one; either is passed by
        ENVIRONMENT, never as an argument.
        """
        env = {"SEREN_NONINTERACTIVE": "1"}
        st = getattr(self.app, "setup", None)
        if st is not None and st.name:
            env["SEREN_SETUP"] = st.name                 # the ledger record names its setup
        pw = (self.app.service_passwords.get(name)       # type: ignore[attr-defined]
              or self.app.service_password)              # type: ignore[attr-defined]
        if pw:
            env[SERVICE_PASSWORD_ENV] = pw
        return env

    def _save_adv(self, name: str, result: Optional[dict]) -> None:
        if result is None:
            return                                       # Cancel / Escape: untouched
        # Pop the password out BEFORE anything reaches per_service. That dict is
        # handed straight to build_command, so a key left in it here becomes a
        # command-line argument - the one outcome this design exists to prevent.
        pw = result.pop("_password", None)
        if pw is not None:
            self.app.service_passwords[name] = pw        # type: ignore[attr-defined]
            self.app.secrets.add(pw)                     # type: ignore[attr-defined]
        cfg = self.app.per_service.setdefault(name, {})  # type: ignore[attr-defined]
        for k, v in result.items():
            if v in (None, "", False):
                cfg.pop(k, None)                         # cleared in the dialog: gone
            else:
                cfg[k] = v

    def _collect(self) -> None:
        u: dict[str, Any] = {}
        if self.query_one("#u-venv", Input).value.strip():
            u["venv"] = self.query_one("#u-venv", Input).value.strip()
        if self.query_one("#u-corp", Checkbox).value:
            u["corp"] = True
        local = self.query_one("#u-local", Input).value.strip()
        ref = self.query_one("#u-ref", Input).value.strip()
        if local:
            u["local"] = local                   # the dev house beats everything
        elif ref:
            u["ref"] = ref                       # a tag beats PyPI
        elif self.query_one("#u-pypi", Checkbox).value:
            u["pypi"] = True

        # -- identity. Note what goes where: the ACCOUNT is a flag and lands in
        # `universal` (build_command will render it as an argument, which is
        # correct and harmless). The PASSWORD goes onto the app object instead,
        # because everything in `universal` becomes argv.
        local_system = False
        try:
            local_system = self.query_one("#u-local-system", Checkbox).value
        except Exception:                            # noqa: BLE001
            pass                                     # not rendered off-Windows
        if local_system:
            u["local-system"] = True
        else:
            try:
                acct = self.query_one("#u-service-user", Input).value.strip()
                if acct:
                    u["service-user"] = acct
            except Exception:                        # noqa: BLE001
                pass
        self.app.universal = u                   # type: ignore[attr-defined]

        pw = ""
        try:
            pw = self.query_one("#u-service-password", Input).value
        except Exception:                            # noqa: BLE001
            pass
        # LocalSystem needs no credential, so drop any password that was typed
        # before the box was ticked rather than shipping it to a run that will
        # ignore it.
        self.app.service_password = "" if local_system else pw   # type: ignore[attr-defined]
        self.app.secrets.add(self.app.service_password)          # type: ignore[attr-defined]

        for name in self.app.selected:           # type: ignore[attr-defined]
            svc = self.app.svc_map[name]         # type: ignore[attr-defined]
            cfg = self.app.per_service.setdefault(name, {})   # type: ignore[attr-defined]
            for flag in INLINE_FLAGS:
                if flag in svc.flags:
                    cfg[flag] = self.query_one(f"#f-{name}-{flag}", Checkbox).value


class ConfirmWipeModal(ModalScreen[bool]):
    """Type the device name to allow a disk to be wiped.

    A checkbox is one keystroke; a disk is not. The dialog names the device,
    says what happens to it, and only returns True when the operator has typed
    the device name back. Escape, Cancel, or a wrong word all mean no - and
    the checkbox that opened this is put back to unchecked by the caller.
    """

    BINDINGS = [("escape", "cancel", "Cancel")]

    def __init__(self, device: str = "nvme0n1") -> None:
        super().__init__()
        self.device = device

    def compose(self) -> ComposeResult:
        with Vertical(id="modal"):
            yield Static("Wipe the NVMe?", classes="modal-title")
            yield Static(
                f"If /dev/{self.device} is not already an ext4 data disk, prep will "
                f"wipe every signature on it, repartition it and format it. Everything "
                f"on it is lost. An ext4 disk is left alone either way.",
                classes="modal-sub")
            yield Label(f"type  {self.device}  to allow it")
            yield Input(placeholder=self.device, id="wipe-confirm")
            with Horizontal(id="actions"):
                yield Button("Cancel", id="cancel", variant="default")
                yield Button("Allow wipe", id="ok", variant="error")

    def _typed_ok(self) -> bool:
        return self.query_one("#wipe-confirm", Input).value.strip() == self.device

    def on_button_pressed(self, event: Button.Pressed) -> None:
        if event.button.id == "ok":
            self.dismiss(self._typed_ok())
        else:
            self.dismiss(False)

    def on_input_submitted(self, event: Input.Submitted) -> None:
        self.dismiss(self._typed_ok())

    def action_cancel(self) -> None:
        self.dismiss(False)


class PrepareNodeScreen(Screen):
    """Prepare THIS machine: OS prereqs, CUDA, llama/kokoro/comfy/chroma/coral.

    Deliberately not the service grid with different cards. The pieces here
    aren't peers:
      - base prep (OS trim, CUDA, NVMe, sudoers) is machine-wide and SLOW, and
        it is a checkbox now rather than a status line - see below.
      - coral is hardware-gated and excluded from --all on purpose.
      - prebuilts/build is a MODE, not a component.

    WHY PREP IS A CHECKBOX NOW. This docstring used to call foundation "not
    optional; the prerequisite, always runs", and the screen told the operator as
    much: "foundation phases run first and skip when already done". Both halves
    were wrong, and the cost was real time and one real hostname:

      - "skip when already done" leaned on phase state kept in a gitignored file
        inside the CHECKOUT, so it was missing on every fresh clone and after
        every .pyz rebuild. Foundation re-ran in full.
      - the hostname rode along with it, derived from the ticked components, so
        adding Ms.MoE to a working brain node renamed the box as a side effect.

    Prep is its own act now, and so is renaming. The dispatcher picks the default
    from state kept ON the node, which is what `provisioned` reports here.
    """

    BINDINGS = [("escape", "app.pop_screen", "Back")]

    def __init__(self, mode: str = "install") -> None:
        """mode is "install" or "modify" - see SplashScreen for what each means.

        Defaulted to "install" rather than being required, because that is the
        superset: it renders every control. A caller that forgets to say gets the
        screen that can do everything, not one silently missing the prep it came
        for.
        """
        super().__init__()
        self.mode = "modify" if mode == "modify" else "install"

    @property
    def is_modify(self) -> bool:
        return self.mode == "modify"

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
                # The old line promised "foundation phases run first and skip
                # when already done" - something the checkout-local state file
                # could not deliver. Report what is true of THIS machine.
                if node.provisioned:
                    prep_state = "prepared"
                    if node.provisioned_at:
                        prep_state += f" {node.provisioned_at}"
                else:
                    prep_state = "never prepared"
                who = ""
                if node.hostname_managed and node.hostname_managed != node.hostname:
                    who = f" (seren set {node.hostname_managed})"
                yield Static(f"hostname {node.hostname}{who}  ·  {prep_state}",
                             classes="modal-sub")
                if self.is_modify:
                    yield Static("MODIFY - components only. This screen cannot "
                                 "run base prep and cannot rename the node.",
                                 classes="section")
                else:
                    yield Static("INSTALL - base prep will run, then the "
                                 "components you pick.", classes="section")
                    if node.provisioned:
                        # Install on a box that is already built is a legitimate
                        # thing to want and an expensive thing to do by accident,
                        # so it says so and names the cheaper door.
                        yield Static(
                            "    this node is already prepared - Install re-runs "
                            "every foundation phase. To just add a component, go "
                            "back and choose Modify.", classes="card-req")
                if node.platform is None:
                    yield Static("Could not identify this machine. Pick one:",
                                 classes="modal-sub")
                    with RadioSet(id="force-platform"):
                        for p in (node.platforms or ["xavier", "nano", "spark"]):
                            yield RadioButton(p)
                yield Rule()
                # NO PREP CHECKBOX, and no section for one. An earlier pass put
                # a checkbox here, defaulted from the prep history, and a checkbox
                # is the wrong control for this: it left "rebuild the foundation of
                # this machine" one keystroke from "add a component", on the same
                # screen, under the same button. The door you came through decides
                # it now, so Modify has no way to express prep at all - which is
                # the whole point.
                yield Static("Components", classes="section")
                for c in node.components:
                    cb = Checkbox(f"{c.display} - {c.description}",
                                  id=f"nc-{c.name}", disabled=not c.available)
                    yield cb
                    if not c.available:
                        why = ("no hardware detected / not supported on this platform"
                               if c.hardware_gated else "no module for this platform")
                        yield Static(f"    unavailable: {why}", classes="card-req")
                yield Rule()
                yield Static("Install source", classes="section")
                # ALWAYS composed, then enabled/disabled by _apply_modes().
                #
                # Composing conditionally looked right and was wrong: compose()
                # runs once at mount, while the platform is still undetected, so
                # modes is only ["prebuilts"] and the build option would never
                # be created - even on Xavier, which has a build path. The
                # platform picker re-queries afterwards, and you cannot
                # retroactively add a widget that was never composed.
                if node.supports("build"):
                    with RadioSet(id="mode"):
                        yield RadioButton("prebuilts (download)", value=True)
                        yield RadioButton("build from source (hours)",
                                          id="mode-build")
                    yield Static("", id="mode-note", classes="card-req")
                if node.supports("tag"):
                    yield Label("pin a prebuilt release tag (blank = latest)")
                    yield Input(placeholder="20260916_xavier-jp5", id="np-tag")

                yield Rule()
                yield Static("Options", classes="section")
                # INSTALL ONLY. Naming a machine belongs to building it, so a
                # Modify run must not be able to touch the identity of the node.
                # Not rendered, rather than rendered and ignored. Blank still
                # means keep, for the Install case where you are re-running on a
                # box that already has the name you want.
                if node.supports("rename") and not self.is_modify:
                    yield Label("rename this node (blank = keep the current name)")
                    yield Input(placeholder=f"keep {node.hostname}" if node.hostname
                                else "leave blank to keep the current name",
                                id="np-rename")
                if node.supports("user"):
                    yield Label("target user (blank = the invoking user)")
                    yield Input(placeholder=os.environ.get("USER", "") or "you",
                                id="np-user")
                # Install only, and not for tidiness: --no-max-power suppresses
                # phase_max_power, which is a FOUNDATION phase. Under Modify no
                # foundation phase runs, so the control would be a switch wired
                # to nothing.
                if node.supports("no-max-power") and not self.is_modify:
                    # Jetsons default to a power-capped profile; prep flips them
                    # to MAXN + jetson_clocks. Worth being able to decline on a
                    # box with marginal cooling or a small PSU.
                    yield Checkbox("skip max-power profile (Jetson only: MAXN + jetson_clocks)",
                                   id="np-nomaxpower")
                # THE TWO THINGS PREP CANNOT UNDO, each its own box, Install only.
                # Prep used to do both silently. The trim is what a dedicated
                # node is for, so it is offered ticked - but it is ON SCREEN,
                # named, and one click from off. The wipe is never pre-ticked
                # and ticking it opens a dialog that wants the device name typed.
                if not self.is_modify:
                    if node.supports("trim-os"):
                        yield Checkbox("trim the OS: remove the desktop, docker and snap "
                                       "(this becomes a headless node)",
                                       value=True, id="np-trimos")
                    if node.supports("wipe-nvme"):
                        yield Checkbox("wipe and format the NVMe if it is not already ext4 "
                                       "(asks you to type the device name)",
                                       value=False, id="np-wipenvme")
                yield Static("", id="cfg-warn")
        with Horizontal(id="actions"):
            yield Button("Back", id="back", variant="default")
            # The button names the act, matching the door. "Prepare" was
            # accurate when there was one path and is ambiguous now that there
            # are two - the whole point is that the operator can tell which one
            # they are about to run without reading the controls.
            yield Button("Modify" if self.is_modify else "Install",
                         id="go", variant="primary")
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
                "terminal first - prep cannot prompt from inside the TUI.")

    def on_checkbox_changed(self, event: Checkbox.Changed) -> None:
        if (event.checkbox.id or "") != "np-wipenvme" or not event.value:
            return
        if getattr(self, "_wipe_confirmed", False):
            return
        # Untick immediately; the dialog's answer re-ticks it. A cancelled
        # dialog therefore leaves the box exactly where a "no" should.
        event.checkbox.value = False

        def _answer(allowed: bool | None) -> None:
            cb = self.query_one("#np-wipenvme", Checkbox)
            self._wipe_confirmed = bool(allowed)
            cb.value = bool(allowed)
            if not allowed:
                self.query_one("#cfg-warn", Static).update(
                    "NVMe wipe not allowed - the device name was not typed. "
                    "A non-ext4 NVMe will stop the run instead.")
            else:
                self.query_one("#cfg-warn", Static).update("")
            self._wipe_confirmed = bool(allowed)

        self.app.push_screen(ConfirmWipeModal("nvme0n1"), _answer)

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
        self._apply_modes(node)
        avail = [c.name for c in node.components if c.available]
        warn.update(f"treating this node as '{chosen}' - available: "
                    + (", ".join(avail) if avail else "nothing"))

    def _apply_modes(self, node: NodeDef) -> None:
        """Enable the build option only where a build path actually exists.

        The Spark ACCEPTS the build flag - the dispatcher parses it - but ships
        no build.sh, so the run would refuse itself. `flags` says what is
        accepted; `modes` says what is possible. This reads modes.
        """
        try:
            btn = self.query_one("#mode-build", RadioButton)
            note = self.query_one("#mode-note", Static)
        except Exception:                                # noqa: BLE001
            return
        can_build = "build" in node.modes
        btn.disabled = not can_build
        if not can_build:
            btn.value = False
            note.update("  prebuilts only - this platform ships no "
                        "source-build path")
        else:
            note.update("")

    def on_button_pressed(self, event: Button.Pressed) -> None:
        if event.button.id == "back":
            self.app.pop_screen()
            return
        node: Optional[NodeDef] = self.app.node          # type: ignore[attr-defined]
        if node is None:
            return
        warn = self.query_one("#cfg-warn", Static)

        def field(wid: str, kind: type):
            """A control the screen did not render must contribute nothing.

            Every option here is composed only if --describe advertised the flag,
            so reading one has to tolerate its absence. A helper rather than a
            pile of try/except, and defined before first use because the prep
            checkbox is now read in the guard below, not just when building the
            command.
            """
            try:
                return self.query_one(wid, kind)
            except Exception:                            # noqa: BLE001
                return None

        # THE DOOR IS THE DECISION. Install preps, Modify does not; there is no
        # widget to read, which is what stops a Modify run from ever preparing or
        # renaming regardless of what is on screen.
        want_prep = not self.is_modify

        # Modify must not be reachable on an unprepared box - the splash disables
        # it - but the screen re-checks rather than trusting that. app.node is
        # reassigned by the platform picker below, so the state this screen acts
        # on is not necessarily the state the splash saw.
        if self.is_modify and not node.provisioned:
            warn.update("this node has no prep record - go back and choose "
                        "Install. Modify cannot prepare a box.")
            return

        chosen = [c for c in node.components
                  if c.available
                  and self.query_one(f"#nc-{c.name}", Checkbox).value]
        if not chosen:
            if self.is_modify:
                # Modify with nothing ticked is genuinely nothing to do: it has
                # no other act available to it.
                warn.update("nothing selected - pick at least one component")
                return
            # Install with nothing ticked is "prepare the box, install nothing",
            # which the dispatcher accepts as --prep on its own. A real request
            # when commissioning hardware you have not chosen a role for yet.
            warn.update("")

        cmd = ["bash", str(node.script)]
        # DERIVED, NOT MAPPED. This was a dict of five entries, every one of
        # them the identity - "llama" -> "--llama" and so on - which made it a
        # hand-maintained copy of something the describe already states. Adding
        # a component to seren-prepare-node.sh put a checkbox on this screen and
        # then raised KeyError the moment somebody ticked it: the UI offered a
        # thing the button could not run.
        #
        # NodeDef's own docstring promises the opposite - "a flag added to the
        # script surfaces with no UI edit" - and it was true for rendering and
        # false for launching. Both ends read the same derived list now.
        unknown = [c.name for c in chosen if not node.supports(c.name)]
        if unknown:
            # A SENTENCE, NOT A TRACEBACK. A component the dispatcher does not
            # take is a real mismatch worth seeing, and the person who needs to
            # see it is looking at this screen, not at a crash dump.
            warn.update(
                f"the prep script does not accept: {', '.join(unknown)} - "
                f"its --describe lists {', '.join(node.flags) or '(nothing)'}")
            return
        for c in chosen:
            cmd.append(f"--{c.name}")

        forced = getattr(self, "_forced_platform", "")
        if forced:
            cmd += ["--platform", forced]
        elif node.platform is None:
            warn.update("platform could not be detected - choose one above")
            return

        mode = field("#mode", RadioSet)
        if mode is not None and mode.pressed_index == 1:
            cmd.append("--build")

        # ALWAYS SAY WHICH, never let the dispatcher's default decide. Given
        # neither flag it infers prep from the node's own state, which is right
        # for someone typing a command and wrong here: the operator picked a door,
        # and that choice must survive into the command rather than being
        # re-derived from state that may have changed since the splash read it.
        # It also puts the intent in the command line InstallScreen echoes to the
        # log, so the transcript says which door was used.
        if node.supports("prep"):
            cmd.append("--prep" if want_prep else "--no-prep")

        for wid, flag in (("#np-tag", "--tag"), ("#np-user", "--user")):
            w = field(wid, Input)
            if w is not None and w.value.strip():
                cmd += [flag, w.value.strip()]

        # --rename is emitted from its own widget rather than the loop above, and
        # that widget only exists under Install. Two independent things therefore
        # have to be true before a rename can happen: the right door, and a name
        # actually typed. It used to be "--hostname" fed from a field whose BLANK
        # value meant "derive one from the components", which is how installing a
        # component became a rename.
        if not self.is_modify:
            rename = field("#np-rename", Input)
            if rename is not None and rename.value.strip():
                cmd += ["--rename", rename.value.strip()]
        nmp = field("#np-nomaxpower", Checkbox)
        if nmp is not None and nmp.value:
            cmd.append("--no-max-power")
        # Consent flags. Each is emitted only from its own box, which only
        # exists under Install; the dispatcher refuses to do either without
        # the flag, so a Modify run structurally cannot trim or wipe.
        trim = field("#np-trimos", Checkbox)
        if trim is not None and trim.value:
            cmd.append("--trim-os")
        wipe = field("#np-wipenvme", Checkbox)
        if wipe is not None and wipe.value and getattr(self, "_wipe_confirmed", False):
            cmd.append("--wipe-nvme")

        events = Path(tempfile.gettempdir()) / f"seren-prep-{os.getpid()}.jsonl"
        try:
            events.unlink()
        except OSError:
            pass
        cmd += ["--events", str(events)]

        what = ", ".join(c.name for c in chosen) if chosen else "base prep only"
        verb = "modify" if self.is_modify else "install"
        self.app.jobs = [Job(label=f"{verb} node ({node.platform or 'forced'}): {what}",  # type: ignore[attr-defined]
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
        log = RedactingLog(self.query_one("#log", RichLog),
                           self.app.secrets)             # type: ignore[attr-defined]
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
        # Wrapped once, here, and passed down. Every write below - the echoed
        # command line, the JSON events, the raw stderr - goes through it.
        log = RedactingLog(self.query_one("#log", RichLog),
                           self.app.secrets)             # type: ignore[attr-defined]
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

    def _render_event(self, label: str, ev: dict, log: "RedactingLog") -> None:
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

    async def _run_one(self, job: Job, log: "RedactingLog") -> int:
        label = job.label
        try:
            # env=None inherits, which is what every job without a secret wants.
            # When there IS one we merge OVER os.environ rather than replacing
            # it: a bare dict would strip PATH, SystemRoot and friends, and the
            # installer would fail somewhere far away from the actual cause.
            job_env = {**os.environ, **job.env} if job.env else None
            proc = await asyncio.create_subprocess_exec(
                *job.cmd, stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE, env=job_env)
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
    #splash { width: 100%; max-width: 92; align: center middle; padding: 1 2; }
    #banner { color: #997256; text-align: center; }
    #tagline { color: #6c7086; text-align: center; padding-bottom: 1; }
    /* Bottom margin only. A symmetric vertical margin collapses to nothing
       between siblings in some layouts and to double elsewhere; one side is
       predictable, and it is the row that let Exit back onto an 80x24 screen. */
    #splash Button { width: 100%; margin: 0 0 1 0; }
    /* The node pair shares a row - see the note in SplashScreen.compose. The
       height must be auto or the Horizontal stretches and eats the rows the
       row was added to save. */
    #splash-node-row { height: auto; width: 100%; }
    #splash-node-row Button { width: 1fr; margin: 0 1 1 1; }
    #splash-note { color: #6c7086; text-align: center; padding-bottom: 1; }
    #select-root { padding: 1 2; }
    /* Explicit height:auto all the way down. Without it on the GROUP and the
       CARDS row, the outer container fixed its height first and clipped the
       bottom line off every card whose description wrapped - the border landed
       mid-sentence ("The bridge between Loci and"). */
    .group { border: round #45475a; border-title-color: #cba6f7; border-title-style: bold;
             padding: 0 1; margin: 1 0; height: auto; width: auto; }
    .group-head { color: #6c7086; }
    /* Two columns until on_resize sets the real count (at most three). One
       row height for every card: a checkbox and two lines of description. */
    .cards { layout: grid; grid-size: 2; grid-columns: 34; grid-rows: 7;
             grid-gutter: 0 2; height: auto; width: auto; }
    .card { border: round #313244; width: 34; height: 7; padding: 0 1; margin: 0; }
    .card-desc { color: #a6adc8; height: auto; max-height: 2; overflow: hidden; }
    .card-req { color: #f9e2af; height: auto; padding: 0 0 0 1; }
    .card-inst { color: #a6e3a1; height: auto; }
    #setup-box, #prev-box, #cfg-prev-box { border: round #45475a; border-title-color: #cba6f7;
                                           border-title-style: bold; height: auto; padding: 0 1; }
    #setup-box { margin: 1 0; }
    #prev-box { margin: 1 0 0 0; }
    #cfg-prev-box { margin: 1 0; }
    /* the room Chad asked for between the continue row and name / port */
    #setup-fields { margin: 1 0 0 0; }
    #setup-warn { color: #f38ba8; height: auto; }
    .adv-folded { display: none; height: auto; }
    .setup-row { height: auto; }
    .setup-row Label { padding: 1 1 0 0; width: auto; }
    .setup-row Input { width: 24; }
    .setup-row Select { width: 60; }

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
    /* Same frame, wider: a found install's line carries its directory. */
    RecordFoundModal { align: center middle; background: #11111b 65%; }
    RecordFoundModal #modal { width: 96; max-width: 100%; }
    #modal { background: #181825; border: thick #cba6f7; padding: 1 2;
             width: 62; height: 85%; max-height: 85%; }
    .modal-title { text-style: bold; }
    .modal-sub { color: #6c7086; padding: 0 0 1 0; }
    /* Keep actions visible: body takes remaining space and scrolls, rather
       than growing until it shoves Cancel/Okay out of frame. */
    #modal-body { height: 1fr; overflow-y: auto; }
    #modal-actions { height: auto; align: right middle; padding: 1 0 0 0; }
    #modal-actions Button { min-width: 0; width: auto; margin: 0 0 0 2; }
    #log { height: 1fr; border: round #313244; }
    #current { color: #89b4fa; text-style: bold; padding: 1 2; }
    #install-root { height: 1fr; }
    """
    TITLE = "Seren Starwright"

    def __init__(self, services: list[ServiceDef], problems: list[str],
                 installed: Optional[list[InstalledRecord]] = None) -> None:
        super().__init__()
        self.services = services
        self.problems = problems
        self.installed: list[InstalledRecord] = list(installed or [])
        self.setups: list[Setup] = load_setups(installed=self.installed) if installed is not None else []
        self.setup: Optional[Setup] = None           # the setup this run installs into
        self.inherited: dict = {}                    # install options taken from what the run builds on
        self.reinstalls: dict = {}                   # service -> the installed record this run reinstalls in place
        self.continuing: bool = False                # a previous setup was picked on the select screen
        self.svc_map = {s.name: s for s in services}
        self.selected: list[str] = []
        self.per_service: dict[str, dict] = {}
        self.universal: dict = {}
        self.jobs: list[Job] = []
        self.node: Optional[NodeDef] = None
        self.node_problem: Optional[str] = None
        # Passwords live HERE and deliberately NOT in `universal` or
        # `per_service`. Those two dicts are precisely what build_command turns
        # into a command line, so anything put in them becomes an argument -
        # which is the one place a password must never be.
        self.service_password: str = ""
        self.service_passwords: dict[str, str] = {}
        self.secrets = SecretRegistry()

    def on_mount(self) -> None:
        # Ask the machine what it is before drawing the splash, so the Prepare
        # Node button can be honestly enabled or disabled. Cheap (a --describe
        # with zero side effects) and it means the splash never offers a door
        # that leads nowhere.
        self.node, self.node_problem = discover_node()
        self.push_screen(SplashScreen())


def print_installed(installed: list[InstalledRecord], as_json: bool = False) -> None:
    if as_json:
        print(json.dumps([asdict(r) for r in installed], indent=2))
        return
    if not installed:
        print("nothing installed on this box (no ledger records, no ~/seren-*/ launchers)")
        return
    print(f"{'service':26} {'instance':14} {'version':12} {'url':28} {'source':10} how")
    for r in installed:
        print(f"{r.service:26} {r.instance or '-':14} {r.version or '?':12} {r.url:28} "
              f"{r.source or '-':10} {'found by scan' if r.derived else 'ledger'}")


def main() -> None:
    if "--installed" in sys.argv:
        print_installed(installed_ledger(), as_json="--json" in sys.argv)
        return

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

    StarwrightApp(services, problems, installed=installed_ledger()).run()


if __name__ == "__main__":
    main()