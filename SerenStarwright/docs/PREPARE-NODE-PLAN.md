# Prepare Node — plan to argue with

Written after reading `D:\serenDaemon\SetupScripts` end to end. Everything in
the "what's there" section is observed, not assumed. Every recommendation is
labelled so you can shoot it down individually.

---

## What's actually there

`SetupScripts` is a **separate repo** from `SerenSetupScripts`, and it is much
further along than "some prep scripts":

| Piece | Lines | What it does |
| --- | --- | --- |
| `common.sh` | 816 | `detect_platform`, jq-backed phase state, venv helpers, `resolve_release_tag`, `_seren_json_escape`, `write_service_manifest`, `write_node_manifest`, `install_agent_common` |
| `seren-setup.sh` | 394 | flag parsing, preflight, hostname derivation, sudoers, platform dispatch |
| `xavier/` | 8 modules | foundation, llama, kokoro, comfy, chroma, coral, build, prebuilts |
| `nano/` | 8 modules | same set |
| `spark/` | 5 modules | foundation, llama, kokoro, comfy, chroma |

Three things I expected to have to build already exist:

- **Platform detection** — `detect_platform()` reads `/etc/nv_tegra_release`
  and sets `PLATFORM`, `CUDA_ARCH`, `TORCH_ARCH_LIST`, `PYTORCH_VERSION`, …
- **Idempotency** — `phase_done` / `phase_mark` / `phase_skip_if_done` against a
  jq `$STATE_FILE`. Foundation phases skip when already done; service phases
  (`run_service`) deliberately always re-run, and the comment says why.
- **JSON machinery** — `_seren_json_escape` and `write_node_manifest` are
  already emitting structured data.

So Prepare Node is **not** a greenfield build. It's a front-end for something
that mostly works, which is the same shape as the Install Services path.

---

## Finding 1 — the Spark is unreachable dead code

`spark` appears **nowhere** in `common.sh` or `seren-setup.sh`. `detect_platform()`
handles exactly two cases:

```bash
case "$jp_release" in
    R35) PLATFORM="xavier" ;;
    R36) PLATFORM="nano"   ;;
    *)   fail "Could not detect a supported JetPack version..." ; return 1 ;;
esac
```

And `spark/foundation.sh`'s own header says:

> The Spark is NOT a Jetson — no `/etc/nv_tegra_release`, no nvpmodel, no eMMC…

So on a Spark, `jp_release` is empty, the `*)` branch fires, and the run dies
before dispatch. Five working modules with no road to them.

**This is the first thing to fix, and it's independent of any TUI.** Even
`bash seren-setup.sh -l -k` on your Spark fails today.

Detection needs a non-Tegra path — `/etc/os-release` for Ubuntu 24.04 plus a
GB10/Blackwell check via `nvidia-smi`, or a `--platform spark` override as the
escape hatch. **Recommend both**: auto-detect, with an explicit override,
because an installer that can't be told what it's running on is a bad time on
hardware that's new enough to fool detection.

> **Fight me on:** whether Spark detection should be a `--platform` flag only.
> Auto-detecting a machine you own exactly one of is arguably over-engineering.

---

## Finding 2 — the stream contract is inverted

The service installers, as of tonight:

- **stdout** = JSON Lines events
- **stderr** = human log

`SetupScripts` does the opposite, deliberately:

```bash
exec 3>&1 4>&2          # seren-setup.sh
log() { echo -e "..." >&3 2>/dev/null || true; echo -e "..."; }
```

- **fd 3** = console (what a human watches)
- **stdout** = the log file (tee'd detail)

Both are reasonable; they're just opposite. And **fd 3 is taken**, so the exact
trick used on the service side would collide head-on.

Three ways out:

1. **Events on fd 5.** Smallest change to `SetupScripts`. But now Starwright
   speaks two dialects, and "which fd is the machine one" becomes a thing to
   remember. *(Not recommended.)*
2. **Events to a file**, path passed in as `--events /tmp/x.jsonl`, Starwright
   tails it. Zero interference with existing redirection, works even when a
   phase spawns something that scribbles on every stream. Slightly more moving
   parts.
3. **Reshape node logging to match the service convention** — human to stderr,
   machine to stdout, logfile via `tee` at the call site. Cleanest end state,
   most invasive, and it touches a working 816-line file.

**Recommend 2.** It's the only one that doesn't require trusting that no phase
in 3,500 lines of prep ever writes to the wrong stream — and prep runs
`apt-get`, `cmake`, `pip`, and `nvpmodel`, which are not famous for stream
hygiene.

> **Fight me on:** 3 is genuinely nicer if you're willing to touch `common.sh`.
> If you want one contract across the whole stack, say so and I'll do it.

---

## Finding 3 — the grid means something different here

Install Services: one card = one installable package, each independent.

Prepare Node: the cards are **components of one machine's setup**, and they
aren't peers:

- `foundation` is not optional. It's the prerequisite for everything, always
  runs, and is the thing phase-state exists for.
- `llama` / `kokoro` / `comfy` / `chroma` are the real choices.
- `coral` is hardware-gated (needs the M.2 TPU physically present) and is
  excluded from `--all` on purpose.
- `build` / `prebuilts` are **not components** — they're the `--build` flag,
  a mode that changes how the others install.

So the Prepare Node screen is not "the same grid with different cards." It's:

```
  Platform: Orin Nano (jp6, CUDA arch 87)          [detected]

  [x] llama.cpp      inference server
  [x] kokoro         TTS
  [ ] comfyui        image generation
  [x] chromadb       vector store
  [ ] coral          M.2 TPU        (hardware not detected)

  Install source:  (o) prebuilts   ( ) build from source
  Hostname:        [ nano-llama-kokoro-chroma        ]  (auto-derived)
```

Foundation isn't a card — it's a line of status text saying what will run.

> **Fight me on:** whether `coral` should be hidden or shown-greyed when the
> TPU isn't detected. I say greyed with a reason; hiding it makes people think
> the installer forgot about it.

---

## Finding 4 — sudo, and the honesty problem

Node prep is `apt-get`, `nvpmodel`, hostname changes, and sudoers edits. A TUI
that hits a sudo prompt in the middle of a run is a hang with no explanation —
the prompt goes to a terminal the TUI has taken over.

**Recommend:** validate up front (`sudo -v`) on the Prepare Node screen, before
any work, and refuse to start if it fails. Never prompt mid-run.

The second honesty problem: `run_service` **always reinstalls** — that's
deliberate and documented in `common.sh`. But a checkbox that says `[x] llama`
looks like "ensure llama", not "reinstall llama from scratch, possibly a
40-minute source build." The UI must say which it is. Foundation phases say
"already complete — skipping"; service phases don't.

---

## Finding 5 — two repos, one installer

Starwright lives in `SerenSetupScripts`. The prep scripts live in `SetupScripts`.
A single binary that does both has to find both.

Options:

1. **`$SEREN_NODE_SCRIPTS` + upward search**, same pattern Starwright already
   uses for its own root. Cheap, no repo surgery.
2. **Bundle both** into the `.pyz`. Already bundling one; adding the other is
   mechanical, and gives you the true one-file story on a virgin Jetson.
3. **Merge the repos.** Cleanest conceptually — one installer repo — but it's a
   history-rewriting move on two public repos for a naming tidiness win.

**Recommend 1 + 2**: find it if it's there, carry a copy if it isn't. Explicitly
**not** 3 tonight.

---

## Proposed order of work

1. **Fix Spark detection** — standalone value, unblocks your actual hardware,
   no TUI involved. Do this even if the rest gets deferred.
2. **`--describe` for prep modules** — each platform module reports name,
   description, which platforms it applies to, hardware gates, est. duration.
3. **`--events FILE`** on `seren-setup.sh`, reusing `_seren_json_escape`.
4. **`PrepareNodeScreen`** — detected platform, component checkboxes,
   source mode, hostname, sudo preflight.
5. **Reuse `InstallScreen` verbatim** — it already consumes the event stream
   and does sequential-with-stop-on-failure. Should need no changes.

Steps 1–3 are useful without any TUI. Step 1 is useful tonight.

---

## Open questions I can't answer for you

- **Does Prepare Node need to run remotely?** Everything above assumes you're
  SSH'd into the node. Driving four boxes from the NUC is a different program
  (and Lodestar arguably already owns that).
- **What does `--tag` mean in the UI?** `resolve_release_tag` exists and
  `--tag 2026.04.29-xavier` pins a prebuilt set. Dropdown of available tags
  (needs network) or free-text field?
- **Is `seren-wipe.sh` in scope?** There's a wipe script in that repo. A
  "start over" button is either very useful or very dangerous.
