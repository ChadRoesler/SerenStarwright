#!/usr/bin/env python3
"""
test-starwright.py  -  regression suite for Seren Starwright.

Drives the REAL TUI headless via Textual's pilot: clicks the actual buttons,
reads the actual rendered geometry. Not a mock in sight - every assertion here
is about what the app does when a person uses it.

Each test names the bug it was written for. They all shipped at least once.

    python3 test-starwright.py          # needs textual
    bash starwright.sh --selftest       # same thing, via the bootstrap venv

Exit 0 = all passed. Non-zero = number of failures.
"""
from __future__ import annotations

import asyncio
import importlib.util
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
TUI = HERE / "seren_starwright" / "seren-starwright.py"

try:
    from textual.widgets import Button, Checkbox, Input, Static
except ImportError:
    sys.exit("ERROR: textual is required.  pip install textual")

spec = importlib.util.spec_from_file_location("sw", TUI)
sw = importlib.util.module_from_spec(spec)
sys.modules["sw"] = sw          # dataclasses resolve types via sys.modules
spec.loader.exec_module(sw)     # type: ignore[union-attr]

PASS: list[str] = []
FAIL: list[str] = []


def ok(msg: str) -> None:
    PASS.append(msg)
    print(f"  PASS  {msg}")


def bad(msg: str) -> None:
    FAIL.append(msg)
    print(f"  FAIL  {msg}")


def check(cond: bool, msg: str) -> None:
    ok(msg) if cond else bad(msg)


async def test_discovery() -> None:
    print("\n== Discovery")
    services, problems = sw.discover()
    check(len(services) > 0, f"discovered {len(services)} installer(s)")
    for p in problems:
        bad(f"discovery problem: {p}")
    for s in services:
        check(bool(s.name and s.display), f"{s.name}: has name + display")
        check(s.default_port > 0, f"{s.name}: port {s.default_port}")
        check(bool(s.accent), f"{s.name}: accent {s.accent or '(missing)'}")


async def test_nothing_dropped() -> None:
    """seren-probe declared group 'infra', which wasn't in Starwright's GROUPS
    list, so it was discovered and then silently never rendered. A service that
    fails to appear is indistinguishable from one that doesn't exist."""
    print("\n== No service silently dropped")
    services, problems = sw.discover()
    app = sw.StarwrightApp(services, problems)
    async with app.run_test(size=(120, 60)) as pilot:
        await pilot.click("#install")
        await pilot.pause()
        shown = {c.svc.name for c in app.screen.query(sw.ServiceCard)}
        missing = {s.name for s in services} - shown
        check(not missing, f"all {len(services)} rendered"
                           + (f" - MISSING {sorted(missing)}" if missing else ""))


async def test_dependencies() -> None:
    """Corpus Callosum writes a config pre-wired to memory:7420 + loci:7422.
    Selecting it alone installs a bridge to nothing."""
    print("\n== Dependency resolution + install order")
    services, problems = sw.discover()
    app = sw.StarwrightApp(services, problems)
    async with app.run_test(size=(120, 60)) as pilot:
        await pilot.click("#install")
        await pilot.pause()
        scc = "seren-corpus-callosum"
        if scc not in app.svc_map:
            return ok("corpus-callosum absent, skipped")
        app.screen.query_one(f"#svc-{scc}", Checkbox).value = True
        await pilot.pause()
        note = str(app.screen.query_one("#dep-note", Static).content)
        check("memory" in note and "loci" in note, f"dep note names both: {note!r}")
        await pilot.click("#next")
        await pilot.pause()
        order = app.selected
        check(order.index("seren-memory") < order.index(scc), "memory before scc")
        check(order.index("seren-loci") < order.index(scc), "loci before scc")


async def test_group_cascade() -> None:
    print("\n== Group checkbox cascades to its children")
    services, problems = sw.discover()
    app = sw.StarwrightApp(services, problems)
    async with app.run_test(size=(120, 60)) as pilot:
        await pilot.click("#install")
        await pilot.pause()
        brain = [s.name for s in services if s.group == "brain"]
        if not brain:
            return ok("no brain group, skipped")
        app.screen.query_one("#grp-brain", Checkbox).value = True
        await pilot.pause()
        vals = [app.screen.query_one(f"#svc-{n}", Checkbox).value for n in brain]
        check(all(vals), f"all {len(brain)} brain services ticked")


async def test_layout(cols: int, rows: int) -> None:
    """Two shipped layout bugs: cards clipped their own border off when a
    description wrapped, and Configure fell off the right edge because
    Textual's Button carries a default min-width of 16 that silently beat the
    width I set. 80 columns is a normal SSH session - the whole audience."""
    print(f"\n== Layout at {cols}x{rows}")
    services, problems = sw.discover()
    app = sw.StarwrightApp(services, problems)
    async with app.run_test(size=(cols, rows)) as pilot:
        await pilot.click("#install")
        await pilot.pause()
        clipped = [c.svc.name for c in app.screen.query(sw.ServiceCard)
                   if sum(x.outer_size.height for x in c.children) > c.content_size.height]
        check(not clipped, f"no card clipped{' - ' + str(clipped) if clipped else ''}")
        for s in services:
            app.screen.query_one(f"#svc-{s.name}", Checkbox).value = True
        await pilot.pause()
        await pilot.click("#next")
        await pilot.pause()
        off = [b.id for b in app.screen.query(".cfg-adv") if b.region.right > cols]
        widest = max((b.region.right for b in app.screen.query(".cfg-adv")), default=0)
        check(not off, f"Configure on screen (widest right={widest} of {cols})")


async def test_modal() -> None:
    """The modal rendered flush top-left because ModalScreen dims the backdrop
    but does not centre the dialog for you. And pre-filling defaults meant
    opening it and pressing Okay added flags nobody chose."""
    print("\n== Advanced modal")
    services, problems = sw.discover()
    app = sw.StarwrightApp(services, problems)

    async def open_modal(name: str) -> sw.AdvancedModal | None:
        app.screen.query_one(f"#adv-{name}", Button).press()
        for _ in range(20):
            await pilot.pause()
            for scr in reversed(app.screen_stack):
                if isinstance(scr, sw.AdvancedModal):
                    return scr
        return None

    async with app.run_test(size=(110, 44)) as pilot:
        await pilot.click("#install")
        await pilot.pause()
        target = "seren-loci" if "seren-loci" in app.svc_map else services[0].name
        app.screen.query_one(f"#svc-{target}", Checkbox).value = True
        await pilot.pause()
        await pilot.click("#next")
        await pilot.pause()

        m = await open_modal(target)
        check(m is not None, "modal opened")
        if m is None:
            return
        d = m.query_one("#modal")
        centred = abs(d.region.x - (110 - d.region.width) // 2) <= 1
        check(centred, f"centred horizontally (x={d.region.x}, w={d.region.width})")
        check(d.region.height < 44, f"hugs content (h={d.region.height} < 44)")
        if m.svc.accent:
            check(str(d.styles.border.top[1]).lower() != "none", "border tinted with accent")

        # no-op visit must not invent flags
        m.query_one("#ok", Button).press()
        await pilot.pause()
        check(not app.per_service.get(target), "opening + Okay saves nothing unchanged")

        # a real edit round-trips
        m = await open_modal(target)
        check(m is not None, "modal reopened for edit")
        if m is None:
            return
        m.query_one("#adv-port", Input).value = "9999"
        m.query_one("#ok", Button).press()
        await pilot.pause()
        check(app.per_service.get(target, {}).get("port") == "9999", "edited port saved")

        # escape discards
        m = await open_modal(target)
        check(m is not None, "modal reopened for cancel")
        if m is None:
            return
        m.query_one("#adv-port", Input).value = "1234"
        await pilot.press("escape")
        await pilot.pause()
        check(app.per_service.get(target, {}).get("port") == "9999",
              "Escape cancels without clobbering")


async def test_node_describe() -> None:
    """nodes/seren-prepare-node.sh --describe must be valid JSON with zero side
    effects, and must stay valid when the platform can't be identified - a
    front-end needs to say 'I can't tell what this is', not render nothing."""
    print("\n== Node --describe")
    node, problem = sw.discover_node()
    if problem and "not available on Windows" in problem:
        return ok("windows, node prep n/a - skipped")
    check(problem is None or node is not None,
          f"describe answered{'' if node else f' - {problem}'}")
    for plat in ("xavier", "nano", "spark"):
        n, p = sw.discover_node(platform_override=plat)
        check(n is not None, f"--platform {plat} describes"
                             + (f" - {p}" if n is None else ""))
        if n:
            avail = [c.name for c in n.components if c.available]
            check(bool(avail), f"{plat}: {len(avail)} component(s) available")
            if plat == "spark":
                coral = [c for c in n.components if c.name == "coral"]
                check(bool(coral) and not coral[0].available,
                      "spark correctly has no coral module")


async def test_node_screen() -> None:
    """The platform picker used to be decorative: when detection failed every
    checkbox was disabled, and choosing a platform didn't re-enable anything
    because availability depends on which platform's modules exist."""
    print("\n== Prepare Node screen")
    services, problems = sw.discover()
    app = sw.StarwrightApp(services, problems)
    async with app.run_test(size=(110, 60)) as pilot:
        if app.node is None and app.node_problem and "Windows" in app.node_problem:
            return ok("windows, skipped")
        check(not app.screen.query_one("#prep", Button).disabled,
              "Prepare Node enabled on the splash")
        await pilot.click("#prep")
        await pilot.pause()
        scr = app.screen
        check(isinstance(scr, sw.PrepareNodeScreen), "screen opened")
        boxes = list(scr.query(Checkbox))
        check(len(boxes) >= 4, f"{len(boxes)} component checkbox(es)")

        if app.node and app.node.platform is None:
            rs = scr.query_one("#force-platform")
            for rb in rs.query("RadioButton"):
                if str(rb.label) == "spark":
                    rb.value = True
                    break
            await pilot.pause()
            await pilot.pause()
            enabled = [c.id for c in scr.query(Checkbox) if not c.disabled]
            check(bool(enabled), f"picking a platform enables components: {enabled}")
            check("nc-coral" not in enabled, "coral stays disabled on spark")

            scr.query_one("#nc-llama", Checkbox).value = True
            await pilot.pause()
            await pilot.click("#go")
            await pilot.pause()
            check(isinstance(app.screen, sw.InstallScreen), "reaches InstallScreen")
            check(len(app.jobs) == 1, "one node job queued")
            j = app.jobs[0]
            check("--llama" in j.cmd, "selected component in the command")
            check("--platform" in j.cmd and "spark" in j.cmd, "forced platform passed")
            check(j.events_file is not None, "events file wired (node uses --events)")


async def test_node_flags_derived() -> None:
    """Node --describe must ADVERTISE its flags, derived from the dispatcher's
    own case branches. Without this the TUI has to hardcode what the script
    accepts - a second source of truth, and the drift bug we killed four times
    in the service layer wearing a different hat."""
    print("\n== Node flags are derived, not assumed")
    node, problem = sw.discover_node(platform_override="nano")
    if node is None:
        return ok(f"node describe unavailable, skipped ({problem})")
    check(bool(node.flags), f"{len(node.flags)} flag(s) advertised")
    for expect in ("llama", "build", "tag", "user", "no-max-power", "hostname"):
        check(node.supports(expect), f"advertises '{expect}'")


async def test_node_options_roundtrip() -> None:
    """Every option the screen shows must reach the command line, and an option
    the dispatcher does NOT advertise must not be rendered at all - offering a
    flag that doesn't exist is worse than hiding one that does."""
    print("\n== Node options round-trip into the command")
    services, problems = sw.discover()
    app = sw.StarwrightApp(services, problems)
    async with app.run_test(size=(110, 70)) as pilot:
        if app.node is None:
            return ok("node prep unavailable, skipped")
        await pilot.click("#prep")
        await pilot.pause()
        scr = app.screen

        if app.node.platform is None:
            rs = scr.query_one("#force-platform")
            for rb in rs.query("RadioButton"):
                if str(rb.label) == "nano":
                    rb.value = True
                    break
            await pilot.pause()
            await pilot.pause()

        scr.query_one("#nc-llama", Checkbox).value = True
        for wid, val in (("#np-tag", "2026.04.29-nano"),
                         ("#np-hostname", "nano-edge"),
                         ("#np-user", "testuser")):
            w = scr.query_one(wid, Input)
            w.value = val
        scr.query_one("#np-nomaxpower", Checkbox).value = True
        await pilot.pause()
        await pilot.click("#go")
        await pilot.pause()
        cmd = app.jobs[0].cmd
        for frag in ("--llama", "--tag", "2026.04.29-nano", "--hostname",
                     "nano-edge", "--user", "testuser", "--no-max-power"):
            check(frag in cmd, f"'{frag}' in the command")

    # negative: a node advertising nothing renders no option fields
    app2 = sw.StarwrightApp(services, problems)
    async with app2.run_test(size=(110, 70)) as pilot:
        if app2.node is None:
            return
        stripped = sw.NodeDef(
            platform="nano", jp_family="jp6", cuda_arch="87", hostname="x",
            components=app2.node.components, modes=["prebuilts"],
            platforms=["nano"], flags=["llama"], script=app2.node.script)
        app2.node = stripped
        await pilot.click("#prep")
        await pilot.pause()
        ids = {w.id for w in app2.screen.query(Input)}
        check("np-tag" not in ids, "unadvertised --tag is not rendered")
        check("np-user" not in ids, "unadvertised --user is not rendered")
        cbs = {c.id for c in app2.screen.query(Checkbox)}
        check("np-nomaxpower" not in cbs,
              "unadvertised --no-max-power is not rendered")


async def test_version() -> None:
    """A .pyz on a Jetson has no repo to interrogate, so "which build is this?"
    is unanswerable unless the answer ships inside the archive. And --version
    must survive the dependency being missing, because that is precisely when
    someone asks it."""
    print("\n== Version reporting")
    v = sw.resolve_version()
    check(bool(v.strip()), f"resolve_version() answers: {v}")
    check(not v.startswith("v(") and "\n" not in v, "single clean line")

    # --version handled above the textual import, so it works without it
    src = Path(sw.__file__).read_text(encoding="utf-8")
    ver_at = src.find('"--version" in sys.argv')
    tex_at = src.find("from textual.app import")
    check(ver_at != -1 and ver_at < tex_at,
          "--version is handled BEFORE the textual import")

    # the splash shows a short form, not the explanatory tail
    services, problems = sw.discover()
    app = sw.StarwrightApp(services, problems)
    async with app.run_test(size=(110, 40)) as pilot:
        note = str(app.screen.query_one("#splash-note", Static).content)
        check("(" not in note.split("·")[0],
              f"splash shows a short version, not the tail: {note!r}")


async def test_command_building() -> None:
    print("\n== Command building")
    services, problems = sw.discover()
    app = sw.StarwrightApp(services, problems)
    svc = app.svc_map.get("seren-memory") or services[0]
    cmd = sw.build_command(svc, {"mcp": True, "port": "7999"}, {"corp": True})
    check("--json" in cmd or "-Json" in cmd, "always asks for the event stream")
    joined = " ".join(cmd)
    check("7999" in joined, "per-service override present")
    # a flag the service does not accept must be dropped, not passed
    cmd2 = sw.build_command(svc, {}, {"pypi": True})
    check(("--pypi" in cmd2) == ("pypi" in svc.flags),
          "unsupported universal flag filtered out")


async def main() -> int:
    await test_discovery()
    await test_nothing_dropped()
    await test_group_cascade()
    await test_dependencies()
    for c, r in ((80, 24), (100, 40), (140, 50)):
        await test_layout(c, r)
    await test_modal()
    await test_node_describe()
    await test_node_screen()
    await test_node_flags_derived()
    await test_node_options_roundtrip()
    await test_version()
    await test_command_building()

    print("\n" + "=" * 46)
    if FAIL:
        print(f"  {len(FAIL)} FAILED / {len(PASS)} passed")
        for f in FAIL:
            print(f"    - {f}")
        return len(FAIL)
    print(f"  ALL {len(PASS)} CHECKS PASSED")
    print("  Rip it and win.")
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
