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
import json
import os
import shutil
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
TUI = HERE / "seren_starwright" / "seren-starwright.py"

try:
    from textual.widgets import Button, Checkbox, Input, Static, Select
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


def widget_text(widget) -> str:
    """The visible text of a Static, across textual versions.

    Textual <=7 had .renderable; 8.x renamed it to .content. CI installs the
    current textual, so an assertion pinned to either spelling breaks on the
    other - and it breaks as an AttributeError mid-run, which aborts the whole
    suite rather than failing one check.
    """
    for attr in ("content", "renderable", "visual"):
        if hasattr(widget, attr):
            try:
                return str(getattr(widget, attr))
            except Exception:                                # noqa: BLE001
                continue
    return ""


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



async def settled_modal(pilot, app) -> "sw.AdvancedModal | None":
    """Wait for the Advanced modal to be on the stack AND laid out. Returning
    it the tick it appears was enough on an idle box and flaky under load:
    the dialog's region was still 0x0 and its inputs not yet composed."""
    for _ in range(40):
        await pilot.pause()
        for scr in reversed(app.screen_stack):
            if isinstance(scr, sw.AdvancedModal):
                try:
                    if scr.query_one("#modal").region.width > 0 and scr.query("Input"):
                        return scr
                except Exception:  # noqa: BLE001 - not composed yet
                    pass
    return None

async def test_modal() -> None:
    """The modal rendered flush top-left because ModalScreen dims the backdrop
    but does not centre the dialog for you. And pre-filling defaults meant
    opening it and pressing Okay added flags nobody chose."""
    print("\n== Advanced modal")
    services, problems = sw.discover()
    app = sw.StarwrightApp(services, problems)

    async def open_modal(name: str) -> sw.AdvancedModal | None:
        app.screen.query_one(f"#adv-{name}", Button).press()
        return await settled_modal(pilot, app)

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
        before = dict(app.per_service.get(target, {}))
        m.query_one("#ok", Button).press()
        await pilot.pause()
        check(app.per_service.get(target, {}) == before,
              "opening + Okay saves no new config")

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
        check(not app.screen.query_one("#install-node", Button).disabled,
              "Install Node enabled on the splash")
        await pilot.click("#install-node")
        await pilot.pause()
        scr = app.screen
        check(isinstance(scr, sw.PrepareNodeScreen), "screen opened")
        boxes = [c for c in scr.query(Checkbox) if (c.id or "").startswith("nc-")]
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
    for expect in ("llama", "build", "tag", "user", "no-max-power",
                   "prep", "no-prep", "rename"):
        check(node.supports(expect), f"advertises '{expect}'")
    # -H/--hostname is REJECTED by the dispatcher now, and the rejection lives in
    # the catch-all rather than in a case branch of its own precisely so it does
    # not show up here. A branch for it would advertise the flag back into the
    # screen, which would render the auto-derive input all over again.
    check(not node.supports("hostname"),
          "retired 'hostname' is NOT advertised")


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
        await pilot.click("#install-node")
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
                         ("#np-rename", "nano-edge"),
                         ("#np-user", "testuser")):
            w = scr.query_one(wid, Input)
            w.value = val
        scr.query_one("#np-nomaxpower", Checkbox).value = True
        await pilot.pause()
        await pilot.click("#go")
        await pilot.pause()
        cmd = app.jobs[0].cmd
        for frag in ("--llama", "--tag", "2026.04.29-nano", "--rename",
                     "nano-edge", "--user", "testuser", "--no-max-power"):
            check(frag in cmd, f"'{frag}' in the command")
        check("--hostname" not in cmd, "retired '--hostname' never emitted")

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
        await pilot.click("#install-node")
        await pilot.pause()
        ids = {w.id for w in app2.screen.query(Input)}
        check("np-tag" not in ids, "unadvertised --tag is not rendered")
        check("np-user" not in ids, "unadvertised --user is not rendered")
        check("np-rename" not in ids, "unadvertised --rename is not rendered")
        cbs = {c.id for c in app2.screen.query(Checkbox)}
        check("np-nomaxpower" not in cbs,
              "unadvertised --no-max-power is not rendered")
        # A node script too old to advertise --prep must not have prep forced on
        # it either: the command builder gates that on node.supports("prep"), so
        # a stripped node gets neither --prep nor --no-prep.
        check("np-prep" not in cbs, "no prep checkbox exists on any screen now")


async def _open(app, pilot, node, mode="install"):
    """Put a known NodeDef on screen in a chosen mode, without the splash.

    The splash DISABLES its node buttons when app.node is None, and on_mount has
    already run by the time a test can assign one - so clicking is a no-op, the
    screen never changes, and every assertion afterwards passes vacuously against
    the splash. Pushing directly is what lets these run on a non-Jetson.
    """
    app.node = node
    app.push_screen(sw.PrepareNodeScreen(mode=mode))
    await pilot.pause()
    await pilot.pause()
    return app.screen


def _node(provisioned: bool, script, components, **kw):
    """A NodeDef with a chosen prep history.

    Synthesised rather than read off this machine, on purpose: the behaviour under
    test BRANCHES on provisioned state, and a test that only exercises whichever
    state the developer box happens to be in proves half of it.
    """
    return sw.NodeDef(
        platform=kw.get("platform", "nano"), jp_family="jp6", cuda_arch="87",
        hostname=kw.get("hostname", "nano-brain"), components=components,
        modes=["prebuilts"], platforms=["nano"],
        provisioned=provisioned,
        provisioned_at="2026-09-01T10:00:00Z" if provisioned else "",
        hostname_managed=kw.get("hostname_managed", ""),
        flags=["llama", "kokoro", "prep", "no-prep", "rename", "user", "tag",
               "no-max-power", "trim-os", "wipe-nvme"],
        script=script)


def _fixture():
    node0, _ = sw.discover_node(platform_override="nano")
    script = node0.script if node0 else Path("nodes/seren-prepare-node.sh")
    comps = [sw.NodeComponent(name="llama", display="llama.cpp", description="x"),
             sw.NodeComponent(name="kokoro", display="Kokoro", description="y")]
    services, problems = sw.discover()
    return services, problems, script, comps


async def test_two_doors_on_splash() -> None:
    """Node work used to be ONE door, so one screen had to offer foundation prep,
    a hostname field and components together - with a checkbox as the only thing
    between "add Ms.MoE to a working box" and "rebuild this machine and rename
    it". Install and Modify are separate doors now, and Modify is not offered at
    all on a box with no prep record, because Modify cannot prepare one."""
    print("\n== Splash offers Install and Modify, gated on prep state")
    services, problems, script, comps = _fixture()

    for provisioned, modify_enabled in ((True, True), (False, False)):
        app = sw.StarwrightApp(services, problems)
        async with app.run_test(size=(110, 70)) as pilot:
            app.node = _node(provisioned, script, comps)
            # Re-push so on_mount reads the node we just supplied.
            app.push_screen(sw.SplashScreen())
            await pilot.pause()
            await pilot.pause()
            scr = app.screen
            ins = scr.query_one("#install-node", Button)
            mod = scr.query_one("#modify-node", Button)
            check(not ins.disabled,
                  "provisioned=%s: Install Node enabled" % provisioned)
            check(mod.disabled != modify_enabled,
                  "provisioned=%s: Modify Node %s"
                  % (provisioned, "enabled" if modify_enabled else "disabled"))
            note = widget_text(scr.query_one("#splash-note", Static))
            want = "prepared" if provisioned else "never prepared"
            check(want in note, "splash note states prep state: %r" % note)


async def test_modify_cannot_prep_or_rename() -> None:
    """THE FOOLPROOFING. Modify is components only: it must not be able to run
    base prep or rename the box - and not because it chooses not to, but because
    neither control is on the screen, so there is nothing to mis-set.

    Its command must say --no-prep explicitly rather than relying on the
    dispatcher inferring it from node state, which can change under us."""
    print("\n== Modify cannot prep and cannot rename")
    services, problems, script, comps = _fixture()

    app = sw.StarwrightApp(services, problems)
    async with app.run_test(size=(110, 70)) as pilot:
        scr = await _open(app, pilot, _node(True, script, comps), mode="modify")
        ids = {w.id for w in scr.query(Input)}
        cbs = {c.id for c in scr.query(Checkbox)}
        check("np-rename" not in ids, "Modify renders no rename field")
        check("np-prep" not in cbs, "Modify renders no prep checkbox")
        check("np-nomaxpower" not in cbs, "Modify renders no max-power switch")
        check(str(scr.query_one("#go", Button).label) == "Modify",
              "action button reads Modify")

        scr.query_one("#nc-llama", Checkbox).value = True
        await pilot.pause()
        await pilot.click("#go")
        await pilot.pause()
        cmd = app.jobs[0].cmd
        check("--no-prep" in cmd, "Modify emits --no-prep")
        check("--prep" not in cmd, "Modify never emits --prep")
        check("--rename" not in cmd, "Modify never emits --rename")
        check("--hostname" not in cmd, "and never the retired --hostname")
        check("nano-brain" not in cmd, "the current name is not passed as an arg")
        check("--llama" in cmd, "Modify still installs the component")
        check("modify node" in app.jobs[0].label,
              "job label names the door: %r" % app.jobs[0].label)


async def test_modify_refuses_unprepared_node() -> None:
    """The splash disables Modify on a box with no prep record, but the screen
    re-checks rather than trusting that: app.node is REASSIGNED by the platform
    picker, so the state this screen acts on is not always the state the splash
    saw. Modify onto a bare box would install a component against missing CUDA,
    Python and NVMe, and fail somewhere far from the cause."""
    print("\n== Modify refuses a node with no prep record")
    services, problems, script, comps = _fixture()

    app = sw.StarwrightApp(services, problems)
    async with app.run_test(size=(110, 70)) as pilot:
        scr = await _open(app, pilot, _node(False, script, comps), mode="modify")
        scr.query_one("#nc-llama", Checkbox).value = True
        await pilot.pause()
        await pilot.click("#go")
        await pilot.pause()
        check(isinstance(app.screen, sw.PrepareNodeScreen),
              "stays on the screen instead of running")
        msg = widget_text(scr.query_one("#cfg-warn", Static))
        check("Install" in msg, "and points at Install: %r" % msg)


async def test_install_preps_and_may_rename() -> None:
    """Install is the other half of the contract: prep runs because that IS the
    job, and a rename happens only when a name was actually typed. Blank must
    stay blank - the old field said "blank = auto-derived" and derived a name from
    the ticked components."""
    print("\n== Install preps, and renames only when asked")
    services, problems, script, comps = _fixture()

    # blank rename field -> prep, no rename
    app = sw.StarwrightApp(services, problems)
    async with app.run_test(size=(110, 70)) as pilot:
        scr = await _open(app, pilot, _node(False, script, comps), mode="install")
        check(str(scr.query_one("#go", Button).label) == "Install",
              "action button reads Install")
        scr.query_one("#nc-llama", Checkbox).value = True
        await pilot.pause()
        await pilot.click("#go")
        await pilot.pause()
        cmd = app.jobs[0].cmd
        check("--prep" in cmd, "Install emits --prep")
        check("--no-prep" not in cmd, "Install does not suppress prep")
        check("--rename" not in cmd, "blank rename field emits no --rename")
        check("install node" in app.jobs[0].label,
              "job label names the door: %r" % app.jobs[0].label)

    # a typed name travels
    app = sw.StarwrightApp(services, problems)
    async with app.run_test(size=(110, 70)) as pilot:
        scr = await _open(app, pilot, _node(False, script, comps), mode="install")
        scr.query_one("#nc-llama", Checkbox).value = True
        scr.query_one("#np-rename", Input).value = "nano-edge"
        await pilot.pause()
        await pilot.click("#go")
        await pilot.pause()
        cmd = app.jobs[0].cmd
        check("--rename" in cmd and "nano-edge" in cmd,
              "a typed rename reaches the command")

    # Install with nothing ticked is prep-only, which the dispatcher accepts
    app = sw.StarwrightApp(services, problems)
    async with app.run_test(size=(110, 70)) as pilot:
        await _open(app, pilot, _node(False, script, comps), mode="install")
        await pilot.click("#go")
        await pilot.pause()
        check(isinstance(app.screen, sw.InstallScreen),
              "Install with no components is allowed (prep only)")
        if isinstance(app.screen, sw.InstallScreen):
            cmd = app.jobs[0].cmd
            check("--prep" in cmd, "prep-only emits --prep")
            check("--llama" not in cmd, "prep-only installs no component")
            check("base prep only" in app.jobs[0].label,
                  "job label says what it is: %r" % app.jobs[0].label)


async def test_consent_flags() -> None:
    """The two irreversible things prep does are behind consent flags, and the
    TUI has to carry that shape: the trim is offered ticked but visible, the
    wipe is never pre-ticked and needs the device name TYPED, and neither box
    exists under Modify - a component install must not be able to reformat
    the disk it is installing onto."""
    print("\n== Consent flags (trim-os / wipe-nvme)")
    services, problems, script, comps = _fixture()

    app = sw.StarwrightApp(services, problems)
    async with app.run_test(size=(110, 60)) as pilot:
        scr = await _open(app, pilot, _node(False, script, comps), mode="install")
        trim = scr.query_one("#np-trimos", Checkbox)
        wipe = scr.query_one("#np-wipenvme", Checkbox)
        check(trim.value is True, "trim-os offered ticked on Install")
        check(wipe.value is False, "wipe-nvme starts unticked")

        # tick the wipe box, then cancel the dialog: the box goes back to off
        wipe.value = True
        await pilot.pause(); await pilot.pause()
        check(isinstance(app.screen, sw.ConfirmWipeModal), "ticking wipe opens the typed dialog")
        await pilot.click("#cancel")
        await pilot.pause(); await pilot.pause()
        check(scr.query_one("#np-wipenvme", Checkbox).value is False,
              "cancelling the dialog unticks the box")

        # tick again, type the wrong thing: still off
        scr.query_one("#np-wipenvme", Checkbox).value = True
        await pilot.pause(); await pilot.pause()
        app.screen.query_one("#wipe-confirm", Input).value = "nope"
        await pilot.click("#ok")
        await pilot.pause(); await pilot.pause()
        check(scr.query_one("#np-wipenvme", Checkbox).value is False,
              "the wrong word does not allow the wipe")

        # and the right word does
        scr.query_one("#np-wipenvme", Checkbox).value = True
        await pilot.pause(); await pilot.pause()
        app.screen.query_one("#wipe-confirm", Input).value = "nvme0n1"
        await pilot.click("#ok")
        await pilot.pause(); await pilot.pause()
        check(scr.query_one("#np-wipenvme", Checkbox).value is True,
              "typing the device name allows it")

        scr.query_one("#nc-llama", Checkbox).value = True
        await pilot.pause()
        await pilot.click("#go")
        await pilot.pause()
        cmd = app.jobs[0].cmd
        check("--trim-os" in cmd and "--wipe-nvme" in cmd,
              "both consent flags reach the command only after consent")

    app = sw.StarwrightApp(services, problems)
    async with app.run_test(size=(110, 60)) as pilot:
        scr = await _open(app, pilot, _node(True, script, comps), mode="modify")
        check(not scr.query("#np-trimos") and not scr.query("#np-wipenvme"),
              "Modify renders neither consent box")
        scr.query_one("#nc-llama", Checkbox).value = True
        await pilot.pause()
        await pilot.click("#go")
        await pilot.pause()
        cmd = app.jobs[0].cmd
        check("--trim-os" not in cmd and "--wipe-nvme" not in cmd,
              "and its command carries neither flag")

    # A node whose describe does not advertise the flags gets no boxes.
    old = _node(False, script, comps)
    old.flags = [f for f in old.flags if f not in ("trim-os", "wipe-nvme")]
    app = sw.StarwrightApp(services, problems)
    async with app.run_test(size=(110, 60)) as pilot:
        scr = await _open(app, pilot, old, mode="install")
        check(not scr.query("#np-trimos") and not scr.query("#np-wipenvme"),
              "an older dispatcher that lacks the flags gets no consent boxes")


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
    # --local is a universal source like --ref: it reaches every card that
    # declares it (all of them, via the shared library), carries its value,
    # and never shows up as an Advanced text box.
    cmd3 = sw.build_command(svc, {}, {"local": "http://devbox:8765"})
    check("local" in svc.flags, "%s declares --local" % svc.name)
    check(("--local" in cmd3 or "-Local" in cmd3) and "http://devbox:8765" in cmd3,
          "--local rendered with its wheelhouse")
    check("local" not in svc.advanced_flags, "--local is universal, not Advanced")
    missing = [s.name for s in services if "local" not in s.flags]
    check(not missing, "every card declares --local (missing: %s)" % missing)


async def test_switches_are_check_boxes() -> None:
    """A flag that takes no value must never be a text box. Every card has
    --no-updates, and the Advanced modal rendered it as an Input: whatever the
    operator typed became `--no-updates <text>`, which the card refused as an
    unknown flag. --describe now says which flags are switches and the modal
    draws those as check boxes; Memory's new --st rides on the same rail."""
    print("\n== Switches render as check boxes")
    services, problems = sw.discover()
    mem = next((s for s in services if s.name == "seren-memory"), None)
    check(mem is not None, "memory card present")
    if mem is None:
        return
    check("no-updates" in mem.switches and "st" in mem.switches,
          "--describe reports no-updates and st as switches: %s" % mem.switches)
    check("port" not in mem.switches and "token" not in mem.switches,
          "flags that take a value are not switches")
    for svc in services:
        check("no-updates" in svc.switches, "%s reports --no-updates as a switch" % svc.name)

    app = sw.StarwrightApp(services, problems)
    async with app.run_test(size=(110, 50)) as pilot:
        await pilot.click("#install")
        await pilot.pause()
        app.screen.query_one("#svc-seren-memory", Checkbox).value = True
        await pilot.pause()
        await pilot.click("#next")
        await pilot.pause()
        app.screen.query_one("#adv-seren-memory", Button).press()
        modal = await settled_modal(pilot, app)
        check(modal is not None, "modal opened")
        if modal is None:
            return
        check(isinstance(modal.query_one("#adv-no-updates"), Checkbox), "no-updates is a check box")
        check(isinstance(modal.query_one("#adv-st"), Checkbox), "st is a check box")
        check(isinstance(modal.query_one("#adv-port"), Input), "port is still a text box")
        modal.query_one("#adv-st", Checkbox).value = True
        await pilot.pause()
        await pilot.click("#ok")
        await pilot.pause(); await pilot.pause()
        cfg = app.per_service.get("seren-memory", {})
        check(cfg.get("st") is True, "a ticked switch collects as True: %r" % cfg.get("st"))
        cmd = sw.build_command(mem, cfg, {})
        idx = next((i for i, c in enumerate(cmd) if c in ("--st", "-St")), -1)
        check(idx >= 0 and (idx == len(cmd) - 1 or cmd[idx + 1].startswith("-")),
              "the switch carries no value on the command line: %s" % cmd)


async def test_advanced_values_can_be_changed_and_cleared() -> None:
    """Chad, 23 Sept: an instance name set once in the Advanced dialog could
    not be changed afterwards. The dialog reported only what was filled in and
    the screen merged it, so a cleared field or an unticked box never removed
    the old value."""
    print("\n== Advanced values can be changed and cleared")
    services, problems = sw.discover()
    app = sw.StarwrightApp(services, problems)
    target = "seren-memory" if "seren-memory" in app.svc_map else services[0].name

    async def open_modal(pilot):
        app.screen.query_one(f"#adv-{target}", Button).press()
        return await settled_modal(pilot, app)

    async with app.run_test(size=(110, 50)) as pilot:
        await pilot.click("#install")
        await pilot.pause()
        app.screen.query_one(f"#svc-{target}", Checkbox).value = True
        await pilot.pause()
        await pilot.click("#next")
        await pilot.pause()

        m = await open_modal(pilot)
        m.query_one("#adv-instance", Input).value = "wren"
        m.query_one("#adv-gen-token", Checkbox).value = True
        await pilot.pause(); await pilot.pause()          # let the widgets settle
        await pilot.click("#ok"); await pilot.pause(); await pilot.pause()
        cfg = app.per_service.get(target, {})
        check(cfg.get("instance") == "wren" and cfg.get("gen-token") is True, "set: %r" % cfg)

        m = await open_modal(pilot)
        check(m.query_one("#adv-instance", Input).value == "wren", "reopening shows the value")
        m.query_one("#adv-instance", Input).value = "rhys"
        await pilot.pause(); await pilot.pause()          # let the widgets settle
        await pilot.click("#ok"); await pilot.pause(); await pilot.pause()
        check(app.per_service[target].get("instance") == "rhys", "changed: %r" % app.per_service[target])

        m = await open_modal(pilot)
        m.query_one("#adv-instance", Input).value = ""
        m.query_one("#adv-gen-token", Checkbox).value = False
        await pilot.pause(); await pilot.pause()          # let the widgets settle
        await pilot.click("#ok"); await pilot.pause(); await pilot.pause()
        cfg = app.per_service.get(target, {})
        check("instance" not in cfg and "gen-token" not in cfg, "cleared: %r" % cfg)

        m = await open_modal(pilot)
        m.query_one("#adv-instance", Input).value = "ghost"
        await pilot.pause(); await pilot.pause()
        await pilot.click("#cancel"); await pilot.pause(); await pilot.pause()
        check("instance" not in app.per_service.get(target, {}), "cancel leaves the config untouched")


async def test_install_ledger() -> None:
    """The box knows what Starwright already put on it: ledger records, plus
    installs found by scanning the launchers older cards wrote."""
    print("\n== Install ledger")
    import tempfile
    home = Path(tempfile.mkdtemp(prefix="sw-ledger-"))
    # (1) a recorded install, with a fake dist-info so the version can be read off the venv
    (home / ".seren" / "installed").mkdir(parents=True)
    venv = home / "seren-venvs" / "memory"
    (venv / "Lib" / "site-packages" / "seren_memory-3.1.0.dist-info").mkdir(parents=True)
    (home / ".seren" / "installed" / "seren-memory.json").write_text(json.dumps({
        "schema_version": 1, "service": "seren-memory", "instance": "", "package": "seren-memory",
        "version": "", "host": "127.0.0.1", "port": 7420, "venv": str(venv),
        "config": str(home / "seren-memory" / "seren-memory.yaml"), "app_dir": str(home / "seren-memory"),
        "has_token": True, "source": "local", "installed_at": "2026-09-25T09:00:00Z", "derived": False}))
    (home / "seren-memory").mkdir()
    # (2) an older install nobody recorded: a launcher and a config, instance in the directory name
    d = home / "seren-memorywren"
    d.mkdir()
    (d / "run-seren-memory.ps1").write_text(
        f'& "{home / "seren-venvs" / "memorywren" / "Scripts" / "python.exe"}" -m seren_memory '
        f'--config "{d / "seren-memory.yaml"}"')
    (d / "seren-memory.yaml").write_text("server:\n  host: 0.0.0.0\n  port: 7267\n  bearer_token: nope\nstorage:\n  x: 1\n")
    # (3) a bash launcher for another service, and a directory that is not an install
    d2 = home / "seren-loci"
    d2.mkdir()
    (d2 / "run-seren-loci.sh").write_text(f'#!/usr/bin/env bash\nexec "{home}/seren-venvs/loci/bin/python" -m seren_loci --config "{d2}/seren-loci.yaml"\n')
    (d2 / "seren-loci.yaml").write_text("server:\n  port: 7422\n")
    (home / "seren-logs").mkdir()
    (home / "seren-notes").mkdir()

    recs = sw.installed_ledger(home)
    check([r.label for r in recs] == ["seren-loci", "seren-memory", "seren-memory@wren"], f"three installs: {[r.label for r in recs]}")
    mem = next(r for r in recs if r.label == "seren-memory")
    check(mem.version == "3.1.0" and not mem.derived and mem.port == 7420, f"recorded memory: v{mem.version} :{mem.port}")
    wren = next(r for r in recs if r.label == "seren-memory@wren")
    check(wren.derived and wren.port == 7267 and wren.host == "0.0.0.0" and wren.url == "http://127.0.0.1:7267",
          f"scanned instance: port {wren.port}, url {wren.url}")
    check(wren.venv.endswith("memorywren") and wren.config.endswith("seren-memory.yaml"), "venv and config come from the launcher")
    loci = next(r for r in recs if r.label == "seren-loci")
    check(loci.derived and loci.port == 7422 and "loci/bin/python" in loci.venv.replace("\\", "/") + "/bin/python",
          f"bash launcher parsed: {loci.venv}")

    # ports already held on the box are conflicts, unless it is the same instance re-installing
    services, problems = sw.discover()
    svcs = {x.name: x for x in services}
    if "seren-hippocampus" in svcs and "seren-memory" in svcs:
        warn = sw.port_conflicts(["seren-hippocampus"], svcs, {"seren-hippocampus": {"port": 7420}}, recs)
        check(any("installed seren-memory" in w for w in warn), f"hippocampus on 7420 collides with the installed memory: {warn}")
        warn = sw.port_conflicts(["seren-memory"], svcs, {}, recs)
        check(warn == [], f"memory re-installing on its own 7420 is not a collision: {warn}")
        warn = sw.port_conflicts(["seren-memory"], svcs, {"seren-memory": {"instance": "rhys"}}, recs)
        check(any("7420" in w for w in warn), f"a NEW memory instance on 7420 is: {warn}")
        # a dependency's address is filled in only when exactly one instance is installed
        hip = svcs["seren-hippocampus"]
        cfg = sw.prefill_from_installed(hip, {}, recs)
        check("memory-url" not in cfg, f"two memories installed: nothing guessed ({cfg})")
        cfg = sw.prefill_from_installed(hip, {}, [wren])
        check(cfg.get("memory-url") == "http://127.0.0.1:7267", f"one memory installed: memory-url prefilled ({cfg})")
        notes = sw.reinstall_notes(["seren-memory", "seren-hippocampus"], {"seren-memory": {"instance": "rhys"}}, recs)
        check(len(notes) == 1 and "beside" in notes[0], f"a new instance is 'beside': {notes}")
        notes = sw.reinstall_notes(["seren-memory"], {}, recs)
        check(len(notes) == 1 and "re-installs it in place" in notes[0], f"same instance is 'in place': {notes}")

    # the select screen shows it
    app = sw.StarwrightApp(services, problems, installed=recs)
    async with app.run_test(size=(120, 50)) as pilot:
        await pilot.click("#install")
        await pilot.pause()
        note = app.screen.query_one("#installed-note", Static).content
        check("memory@wren :7267" in str(note) and "loci :7422" in str(note), f"installed note: {note}")
        if "seren-memory" in svcs:
            card = app.screen.query_one("#inst-seren-memory", Static).content
            check("v3.1.0 :7420" in str(card) and "@wren :7267" in str(card), f"memory card lists both: {card}")
    shutil.rmtree(home, ignore_errors=True)


async def test_setups() -> None:
    """A setup is who the installs are for: name, instance, port base, wiring.
    Choosing one alters it in place; found installs can be recorded into one."""
    print("\n== Setups")
    import tempfile
    home = Path(tempfile.mkdtemp(prefix="sw-setups-"))
    os.environ["SEREN_INSTALLED_DIR"] = str(home / ".seren" / "installed")
    os.environ["SEREN_SETUPS_DIR"] = str(home / ".seren" / "setups")
    try:
        services, problems = sw.discover()
        svcs = {x.name: x for x in services}
        if not {"seren-memory", "seren-loci", "seren-corpus-callosum", "seren-hippocampus"} <= set(svcs):
            check(False, "brain cards present"); return
        # two found installs (a wren memory and loci), unrecorded
        for svc, port, inst in (("seren-memory", 7267, "wren-memory"), ("seren-loci", 7266, "wren-loci")):
            d = home / f"{svc}{inst}"; d.mkdir(parents=True)
            (d / f"run-{svc}.ps1").write_text(f'& "{home}/seren-venvs/x/Scripts/python.exe" -m {svc.replace("-", "_")} --config "{d / (svc + ".yaml")}"')
            (d / f"{svc}.yaml").write_text(f"server:\n  host: 127.0.0.1\n  port: {port}\n  bearer_token: \"tok-{svc}\"\n")
        recs = sw.installed_ledger(home)
        check([r.label for r in recs] == ["seren-loci@wren-loci", "seren-memory@wren-memory"] and all(r.derived for r in recs),
              f"two found installs: {[r.label for r in recs]}")
        check(sw.load_setups(home, recs) == [], "no setups yet")

        # record them into a setup called wren: the ledger gets two records, the setup its members
        written = sw.record_found(recs, "wren", home)
        check(len(written) == 2 and all(f.is_file() for f in written) and not any(r.derived for r in recs),
              "recorded: two ledger files, no longer 'found'")
        st = sw.Setup(name="wren", base_port=7265, members=[r.label for r in recs]); sw.save_setup(st, home)
        again = sw.installed_ledger(home)
        check([r.setup for r in again] == ["wren", "wren"] and not any(r.derived for r in again), "re-read: recorded, in setup wren")
        setups = sw.load_setups(home, again)
        check([x.name for x in setups] == ["wren"] and setups[0].members == sorted(st.members), f"setup loaded: {setups}")
        check("has loci, memory" in sw.setup_status(setups[0], svcs, again) and "missing" in sw.setup_status(setups[0], svcs, again),
              sw.setup_status(setups[0], svcs, again))

        # add the callosum and the hippocampus to wren: instance from the setup, port from the base, wiring by config path
        per = {}
        sel = ["seren-corpus-callosum", "seren-hippocampus"]
        sw.apply_setup(setups[0], sel, svcs, per, again)
        sw.wire_dependencies(sel, svcs, per, again, setups[0], home)
        cc, hip = per["seren-corpus-callosum"], per["seren-hippocampus"]
        check(cc.get("instance") == "" or "instance" not in cc, f"a grouped setup has no instance of its own: {cc}")
        check(cc.get("port") == 7265 + 3 and hip.get("port") == 7265 + 4, f"ports = base + family offset: {cc.get('port')}, {hip.get('port')}")
        check(cc.get("memory-config", "").endswith("seren-memory.yaml") and cc.get("loci-config", "").endswith("seren-loci.yaml"),
              f"callosum wired to wren's memory and loci by CONFIG PATH: {cc}")
        check(hip.get("memory-config", "").endswith("seren-memory.yaml") and "memory-url" not in hip and "memory-token" not in hip,
              f"hippocampus wired by config path, no token on argv: {hip}")

        # a fresh named setup on its own band: instance = the name, everything in this run wired to each other's planned configs
        new = sw.Setup(name="local llama", instance=sw.sanitize_instance("local llama"), base_port=7440)
        per = {}
        sel = ["seren-memory", "seren-loci", "seren-corpus-callosum"]
        sw.apply_setup(new, sel, svcs, per, again)
        sw.wire_dependencies(sel, svcs, per, again, new, home)
        check(per["seren-memory"] == {"instance": "local-llama", "port": 7440} and per["seren-loci"]["port"] == 7442,
              f"new members: instance and base+offset: {per['seren-memory']}, {per['seren-loci']}")
        check(per["seren-corpus-callosum"]["memory-config"] == str(home / "seren-memorylocal-llama" / "seren-memory.yaml"),
              f"wired to THIS run's planned memory config: {per['seren-corpus-callosum']}")
        # the default band keeps the default instance and default ports
        dflt = sw.Setup(name="2026-09-25"); per = {}
        sw.apply_setup(dflt, ["seren-memory"], svcs, per, [])
        check(per["seren-memory"] == {}, f"default setup changes nothing: {per}")
        # altering a member: its extras come back ticked
        vec = sw.InstalledRecord(service="seren-loci", instance="", port=7422, extras={"vector": True, "mcp": False},
                                 config=str(home / "seren-loci" / "seren-loci.yaml"))
        alter = sw.Setup(name="default", members=["seren-loci"]); per = {}
        sw.apply_setup(alter, ["seren-loci"], svcs, per, [vec])
        check(per["seren-loci"].get("vector") is True and per["seren-loci"].get("port") == 7422, f"alter prefills the member's flags: {per}")
        check(sw.suggest_base(again, setups) == 7440, f"next free band: {sw.suggest_base(again, setups)}")

        # the screen: tick the box, pick wren, the note says what it is missing, Next prefills the config
        app = sw.StarwrightApp(services, problems, installed=again)
        async with app.run_test(size=(120, 50)) as pilot:
            await pilot.click("#install"); await pilot.pause()
            cb = app.screen.query_one("#use-setup", Checkbox)
            check(not cb.disabled, "a setup exists: the picker is offered")
            cb.value = True; await pilot.pause()
            pick = app.screen.query_one("#setup-pick", Select)
            check(not pick.disabled, "ticking enables the drop-down")
            pick.value = "wren"; await pilot.pause(); await pilot.pause()
            check("missing" in widget_text(app.screen.query_one("#setup-note", Static)), "the note names what the setup lacks")
            check(app.screen.query_one("#setup-name", Input).value == "wren", "name follows the pick")
            app.screen.query_one("#svc-seren-hippocampus", Checkbox).value = True; await pilot.pause()
            await pilot.click("#next"); await pilot.pause(); await pilot.pause()
            hip = app.per_service.get("seren-hippocampus", {})
            check(app.setup is not None and app.setup.name == "wren" and hip.get("port") == 7269 and hip.get("memory-config", "").endswith("seren-memory.yaml"),
                  f"Next carried the setup into the config: {hip}")
            check("seren-memory" not in app.selected, "the setup's memory is USED, not pulled into the run")
            # back on the select screen: unticking the box must clear the pick without raising
            app.pop_screen(); await pilot.pause()
            cb = app.screen.query_one("#use-setup", Checkbox)
            cb.value = False; await pilot.pause(); await pilot.pause()
            check(app.screen.query_one("#setup-pick", Select).disabled and app.screen._picked_setup() is None,
                  "unticking clears the pick and disables the drop-down")
            check(not app.screen.query_one("#setup-name", Input).disabled, "name is editable again")
    finally:
        os.environ.pop("SEREN_INSTALLED_DIR", None); os.environ.pop("SEREN_SETUPS_DIR", None)
        shutil.rmtree(home, ignore_errors=True)


async def test_record_found_modal() -> None:
    """Ten found installs, an 80x24-ish box: the list scrolls, the name field
    and the Record button stay on screen, tick-all ticks all, Record writes
    the ledger and the setup, and the selection screen updates."""
    print("\n== Record found installs modal")
    import tempfile
    home = Path(tempfile.mkdtemp(prefix="sw-recmodal-"))
    os.environ["SEREN_INSTALLED_DIR"] = str(home / ".seren" / "installed")
    os.environ["SEREN_SETUPS_DIR"] = str(home / ".seren" / "setups")
    try:
        found = [sw.InstalledRecord(service=f"seren-svc{i}", instance="", port=7500 + i, derived=True,
                                    app_dir=str(home / f"seren-svc{i}"), config=str(home / f"seren-svc{i}" / "x.yaml"))
                 for i in range(10)]
        services, problems = sw.discover()
        app = sw.StarwrightApp(services, problems, installed=found)
        async with app.run_test(size=(100, 30)) as pilot:
            await pilot.click("#install"); await pilot.pause()
            btn = app.screen.query_one("#record-found", Button)
            check("record 10 found installs" in str(btn.label), f"button offered: {btn.label}")
            btn.press()
            modal = None
            for _ in range(40):
                await pilot.pause()
                for scr in reversed(app.screen_stack):
                    if isinstance(scr, sw.RecordFoundModal):
                        try:
                            if scr.query_one("#ok").region.height > 0:
                                modal = scr
                        except Exception:  # noqa: BLE001
                            pass
                if modal:
                    break
            check(modal is not None, "modal opened and laid out")
            if modal is None:
                return
            ok_btn = modal.query_one("#ok", Button)
            name_in = modal.query_one("#rec-name", Input)
            h = app.size.height
            check(0 <= ok_btn.region.y < h and ok_btn.region.y + ok_btn.region.height <= h,
                  f"Record button on screen (y={ok_btn.region.y}, screen h={h})")
            check(0 <= name_in.region.y < h, f"name field on screen (y={name_in.region.y})")
            body = modal.query_one("#modal-body")
            check(body.region.height < 10 * 3, f"the list scrolls instead of growing (body h={body.region.height})")
            modal.query_one("#rec-all", Checkbox).value = True
            await pilot.pause(); await pilot.pause()
            check(all(modal.query_one(f"#rec-{i}", Checkbox).value for i in range(10)), "tick all ticks all")
            modal.query_one("#rec-3", Checkbox).value = False
            name_in.value = "everything but three"
            await pilot.pause(); await pilot.pause()
            ok_btn.press()
            await pilot.pause(); await pilot.pause(); await pilot.pause()
            recs = sorted(p.name for p in (home / ".seren" / "installed").glob("*.json"))
            check(len(recs) == 9 and "seren-svc3.json" not in recs, f"nine recorded, the unticked one ignored: {len(recs)}")
            st = sw.load_setups(home)
            check(len(st) == 1 and st[0].name == "everything but three" and len(st[0].members) == 9,
                  f"setup saved with its members: {st}")
            note = widget_text(app.screen.query_one("#setup-note", Static))
            check("recorded 9 install(s)" in note, f"selection screen says so: {note}")
            check(not app.screen.query_one("#use-setup", Checkbox).disabled, "the picker is offered now")
            check("record 1 found install" in str(app.screen.query_one("#record-found", Button).label), "one left to record")
    finally:
        os.environ.pop("SEREN_INSTALLED_DIR", None); os.environ.pop("SEREN_SETUPS_DIR", None)
        shutil.rmtree(home, ignore_errors=True)


async def test_installed_dependency_is_used_not_reinstalled() -> None:
    """Chad, 25 Sept: ticking the hippocampus loaded a default Memory install
    rather than the one already installed. An installed dependency satisfies
    the requirement and is wired; only a missing one is pulled in."""
    print("\
== Installed dependency is used, not reinstalled")
    services, problems = sw.discover()
    svcs = {x.name: x for x in services}
    if not {"seren-memory", "seren-hippocampus"} <= set(svcs):
        check(False, "cards present")
        return
    one = [sw.InstalledRecord(service="seren-memory", instance="wren-memory", host="127.0.0.1", port=7267,
                              config="C:/u/seren-memorywren-memory/seren-memory.yaml", version="3.1.0")]
    two = one + [sw.InstalledRecord(service="seren-memory", instance="", host="127.0.0.1", port=7420,
                                    config="C:/u/seren-memory/seren-memory.yaml", version="3.0.0")]

    async def pick_hippocampus(installed):
        app = sw.StarwrightApp(services, problems, installed=installed)
        async with app.run_test(size=(120, 50)) as pilot:
            await pilot.click("#install"); await pilot.pause()
            app.screen.query_one("#svc-seren-hippocampus", Checkbox).value = True
            await pilot.pause(); await pilot.pause()
            dep = widget_text(app.screen.query_one("#dep-note", Static))
            await pilot.click("#next"); await pilot.pause(); await pilot.pause()
            note = widget_text(app.screen.query_one("#cfg-installed", Static))
            return app, dep, note

    app, dep, note = await pick_hippocampus(one)
    check("already installed, will be used: memory" in dep, f"select screen says the installed memory will be used: {dep}")
    check(app.selected == ["seren-hippocampus"], f"only the hippocampus is installed: {app.selected}")
    hip = app.per_service.get("seren-hippocampus", {})
    check(hip.get("memory-config", "").endswith("seren-memory.yaml") and "memory-url" not in hip,
          f"wired to the installed memory by config path: {hip}")
    check("instance" not in hip and "port" not in hip,
          f"no setup picked: the default instance on its default port, not a dated side-by-side: {hip}")
    check("wired to the installed memory" in note, f"config screen says so: {note}")

    app, dep, note = await pick_hippocampus(two)
    check(app.selected == ["seren-hippocampus"], f"two memories: still not reinstalled: {app.selected}")
    check("memory-config" not in app.per_service.get("seren-hippocampus", {}), "two memories: nothing guessed")
    check("2 memory instances installed" in note and "continue a setup" in note, f"config screen asks the person to choose: {note}")

    app, dep, note = await pick_hippocampus([])
    check("pulled in as dependencies: memory" in dep and "seren-memory" in app.selected,
          f"no memory on the box: pulled in as before ({app.selected})")
    hip = app.per_service.get("seren-hippocampus", {})
    check(hip.get("memory-config", "").endswith("seren-memory.yaml"), f"...and wired to the one this run will write: {hip}")



async def test_nothing_asked_that_the_box_knows() -> None:
    """Chad, 25 Sept: 'for you have memory loci and corpus installed, just
    adding the hippocampus, it shouldnt prompt or want all the values.' The
    wired memory folds to one line in Configure; the install options come
    from the installs the run builds on."""
    print("\n== Nothing asked that the box knows")
    services, problems = sw.discover()
    svcs = {x.name: x for x in services}
    if "seren-hippocampus" not in svcs:
        check(False, "hippocampus card present")
        return
    mem = sw.InstalledRecord(service="seren-memory", instance="wren-memory", host="127.0.0.1", port=7267,
                             config="C:/u/seren-memorywren-memory/seren-memory.yaml", version="3.1.0",
                             source="local", source_ref="D:/serenDaemon/SerenCore/.dev-wheelhouse",
                             autostart=True, extras={"corp": False})
    opts = sw.inherited_options([mem])
    check(opts == {"local": "D:/serenDaemon/SerenCore/.dev-wheelhouse", "service": True},
          f"options inherited from the memory: {opts}")
    scanned = sw.InstalledRecord(service="seren-memory", instance="", port=7420, derived=True, source="")
    check(sw.inherited_options([scanned]) == {}, "a scanned record says nothing about how it was installed")
    mixed = sw.InstalledRecord(service="seren-loci", port=7266, source="pypi", autostart=True)
    check("local" not in sw.inherited_options([mem, mixed]), "records that disagree on source: nothing inherited")

    app = sw.StarwrightApp(services, problems, installed=[mem])
    async with app.run_test(size=(120, 50)) as pilot:
        await pilot.click("#install"); await pilot.pause()
        app.screen.query_one("#svc-seren-hippocampus", Checkbox).value = True
        await pilot.pause()
        await pilot.click("#next"); await pilot.pause(); await pilot.pause()
        check(app.screen.query_one("#u-local", Input).value == "D:/serenDaemon/SerenCore/.dev-wheelhouse",
              "the dev wheelhouse is filled in from the memory's install")
        check(app.screen.query_one("#u-pypi", Checkbox).value is False, "PyPI unticked")
        check("dev wheelhouse" in widget_text(app.screen.query_one("#cfg-inherited", Static)),
              "the screen says where the defaults came from")
        check(app.per_service["seren-hippocampus"].get("service") is True, "autostart inherited")
        check(app.screen.query_one("#f-seren-hippocampus-service", Checkbox).value is True, "...and the box shows it ticked")
        app.screen.query_one("#adv-seren-hippocampus", Button).press()
        m = await settled_modal(pilot, app)
        check(m is not None, "Configure opened")
        if m is None:
            return
        grp = m.query_one("#adv-grp-memory")
        check(grp.display is False, "memory url / token / config are folded away")
        check(m.query_one("#adv-memory-config", Input).value.endswith("seren-memory.yaml"), "the folded config holds the wiring")
        line = " ".join(widget_text(w) for w in m.query(Static))
        check("memory: wired to the installed memory" in line, "one line says where memory points")
        m.query_one("#adv-manual-memory", Checkbox).value = True
        await pilot.pause(); await pilot.pause()
        check(m.query_one("#adv-grp-memory").display is True, "set memory by hand unfolds the boxes")
        await pilot.pause(); await pilot.pause()
        await pilot.click("#ok"); await pilot.pause(); await pilot.pause()
        check(app.per_service["seren-hippocampus"].get("memory-config", "").endswith("seren-memory.yaml"),
              "Okay keeps the wiring")


async def test_reinstall_starts_from_what_is_installed() -> None:
    """Chad, 25 Sept: continuing an install, the venv root, LocalSystem, the
    service box and the hippocampus's model url were blank, and nothing
    stopped a reinstall wiping a bearer token. A reinstall starts from the
    installed service; the card keeps the token."""
    print("\n== Reinstall starts from what is installed")
    import tempfile
    home = Path(tempfile.mkdtemp(prefix="sw-reinstall-"))
    try:
        services, problems = sw.discover()
        svcs = {x.name: x for x in services}
        if "seren-hippocampus" not in svcs:
            check(False, "hippocampus card present")
            return
        d = home / "seren-hippocampuswren-hippocampus"
        d.mkdir()
        cfgp = d / "seren-hippocampus.yaml"
        cfgp.write_text("server:\n  host: 127.0.0.1\n  port: 7269\n  bearer_token: \"keep-me\"\n"
                        "memory:\n  url: http://127.0.0.1:7267\n  bearer_token: \"memorys\"\n"
                        "model:\n  url: \"http://localhost:7200/v1\"   # llama\n\nsleep:\n  mode: thread\n")
        rec = sw.InstalledRecord(service="seren-hippocampus", instance="wren-hippocampus", host="127.0.0.1", port=7269,
                                 venv=str(home / "wren-seren-venvs-wren-hippocampus"), config=str(cfgp),
                                 app_dir=str(d), derived=True)
        # the OS says it autostarts as LocalSystem
        sw.apply_os_services([rec], {sw.os_service_name(rec): {"autostart": True, "account": "LocalSystem"}})
        check(rec.autostart and rec.local_system is True and rec.os_service, f"OS view applied: {rec.os_service}")
        check(sw.config_value(str(cfgp), "model", "url") == "http://localhost:7200/v1", "model url read, comment stripped")
        check(sw.config_value(str(cfgp), "server", "bearer_token") == "keep-me", "server block scoped")
        per = {"seren-hippocampus": {"instance": "wren-hippocampus"}}
        re_ = sw.prefill_reinstall(["seren-hippocampus"], svcs, per, [rec])
        cfg = per["seren-hippocampus"]
        check(list(re_) == ["seren-hippocampus"], "recognised as a reinstall")
        check(cfg.get("port") == 7269, f"port kept: {cfg}")
        check(cfg.get("venv") == str(home / "wren-seren-venvs-"), f"venv prefix derived: {cfg.get('venv')}")
        check(cfg.get("service") is True and cfg.get("local-system") is True, "autostart and LocalSystem from the OS")
        check(cfg.get("model-url") == "http://localhost:7200/v1", f"model url from its config: {cfg.get('model-url')}")
        check("memory-url" not in cfg, "a dependency's url is wired, not copied")
        check("token" not in cfg and "gen-token" not in cfg, "the bearer is left to the card to keep")
        cmd = sw.build_command(svcs["seren-hippocampus"], cfg, {"service-user": "caesar"})
        joined = " ".join(cmd)
        check(("LocalSystem" in joined or "--local-system" in joined) and "caesar" not in joined,
              f"LocalSystem beats the universal account: {cmd[-8:]}")
        inh = sw.inherited_options([rec])
        check(inh.get("venv") == str(home / "wren-seren-venvs-") and inh.get("local-system") is True
              and inh.get("service") is True, f"universal defaults from the record: {inh}")
        # the screens: the universal inputs and the Configure note
        app = sw.StarwrightApp(services, problems, installed=[rec])
        async with app.run_test(size=(120, 50)) as pilot:
            await pilot.click("#install"); await pilot.pause()
            app.screen.query_one("#svc-seren-hippocampus", Checkbox).value = True
            await pilot.pause()
            app.per_service["seren-hippocampus"] = {"instance": "wren-hippocampus"}
            # Next re-runs the prefill with the instance the person set
            await pilot.click("#next"); await pilot.pause(); await pilot.pause()
            if "seren-hippocampus" not in app.reinstalls:
                check(False, f"Next did not see the reinstall: {app.reinstalls}")
                return
            check(app.screen.query_one("#u-venv", Input).value == str(home / "wren-seren-venvs-"), "venv root filled")
            note = widget_text(app.screen.query_one("#cfg-inherited", Static))
            check("reinstalling in place: hippocampus" in note and "bearer tokens are kept" in note, f"screen says so: {note}")
            check(app.screen.query_one("#f-seren-hippocampus-service", Checkbox).value is True, "service box ticked")
            app.screen.query_one("#adv-seren-hippocampus", Button).press()
            m = await settled_modal(pilot, app)
            if m is not None:
                txt = " ".join(widget_text(w) for w in m.query(Static))
                check("existing bearer token is kept" in txt, "Configure says the token is kept")
                check(m.query_one("#adv-model-url", Input).value == "http://localhost:7200/v1", "model url shown in Configure")
    finally:
        shutil.rmtree(home, ignore_errors=True)


async def test_local_wheelhouse_option() -> None:
    """The universal options screen offers the dev wheelhouse once, and it
    beats both the release tag and the PyPI box when filled in."""
    print("\n== Dev wheelhouse option")
    services, problems = sw.discover()
    app = sw.StarwrightApp(services, problems)
    async with app.run_test(size=(110, 50)) as pilot:
        await pilot.click("#install")
        await pilot.pause()
        target = "seren-loci" if "seren-loci" in app.svc_map else services[0].name
        app.screen.query_one(f"#svc-{target}", Checkbox).value = True
        await pilot.pause()
        await pilot.click("#next")
        await pilot.pause()
        scr = app.screen
        check(isinstance(scr, sw.ConfigScreen), "on the config screen")
        scr.query_one("#u-ref", Input).value = "v9.9.9"
        scr.query_one("#u-local", Input).value = "http://devbox:8765"
        scr._collect()
        check(app.universal.get("local") == "http://devbox:8765", "wheelhouse collected")
        check("ref" not in app.universal and "pypi" not in app.universal,
              "a wheelhouse beats the tag and PyPI")
        scr.query_one("#u-local", Input).value = ""
        scr._collect()
        check(app.universal.get("ref") == "v9.9.9" and "local" not in app.universal,
              "clearing it hands precedence back to the tag")


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
    await test_two_doors_on_splash()
    await test_modify_cannot_prep_or_rename()
    await test_modify_refuses_unprepared_node()
    await test_install_preps_and_may_rename()
    await test_consent_flags()
    await test_version()
    await test_command_building()
    await test_local_wheelhouse_option()
    await test_install_ledger()
    await test_setups()
    await test_record_found_modal()
    await test_installed_dependency_is_used_not_reinstalled()
    await test_nothing_asked_that_the_box_knows()
    await test_reinstall_starts_from_what_is_installed()
    await test_switches_are_check_boxes()
    await test_advanced_values_can_be_changed_and_cleared()

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
