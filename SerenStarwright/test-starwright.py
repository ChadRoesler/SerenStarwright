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
