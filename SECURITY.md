# Security

## Reporting

Open a [private security advisory](../../security/advisories/new) rather than a
public issue. If that isn't available to you, a normal issue asking for a
private channel is fine - don't put the details in it.

No bounty, no SLA. This is a personal project. But a real report gets a real
answer.

## What this software does, so you can judge the risk yourself

Seren Starwright is an **installer**. It is not a sandbox, and it is not trying
to be one. Running it means:

- **Executing shell/PowerShell scripts** from this repository on your machine.
- **`sudo` / Administrator operations** during node preparation: `apt-get`,
  `nvpmodel`, hostname changes, and writing a `sudoers.d` drop-in.
- **Registering system services** - systemd units, launchd agents, or NSSM
  services - that start on boot and run as you.
- **Downloading packages** from PyPI and, optionally, release artifacts from
  GitHub.

Read the scripts before you run them. They're plain text, deliberately, and
`--describe` tells you what an installer will do without doing any of it.

## Defaults worth knowing about

**Services bind to localhost by default, except two.** `seren-lodestar` and
`seren-observatory` default to `0.0.0.0` because they're cluster-facing by
design. Everything else - memory, loci, corpus-callosum, workbench, margin,
probe - is `127.0.0.1` unless you widen it.

**Bearer tokens are optional and off by default.** The stack assumes a trusted
LAN. `--gen-token` generates one; without it, anything that can reach the port
can use the service. If a Seren service is reachable from an untrusted network,
you want a token *and* something in front of it.

**MCP endpoints ship with DNS-rebinding protection disabled.** That's a
deliberate trusted-LAN choice so a connected client can reach a service by
hostname. Re-arm it with `SEREN_<SERVICE>_MCP_ALLOWED_HOSTS`.

**Node preparation writes a `sudoers.d` drop-in** granting the target user
passwordless sudo for exactly what the Observatory does unattended: dropping
caches, `/sbin/shutdown -r` / `-c`, and **one** systemctl -
`/usr/local/sbin/seren-systemctl`, a root-owned helper that takes a verb and a
single `seren-*` unit and refuses anything else. It used to grant
`systemctl start *` and `mv /tmp/*.service /etc/systemd/system/*`, which is
root; a sudoers glob cannot be narrowed to one argument because `*` matches
spaces, so a helper does the checking. Read `nodes/lib/seren-systemctl` and
the `phase_sudoers` block of `nodes/seren-prepare-node.sh` before you accept
it.

**Two things prep does are irreversible and each needs its own flag.**
`--trim-os` removes the desktop, docker and snap; `--wipe-nvme` reformats an
NVMe that is not already ext4. Without the flag prep skips the trim and
*stops* on a non-ext4 disk, saying what it found. In the TUI the trim is a
visible pre-ticked box and the wipe is a box that asks you to type the device
name.

That write is part of **base prep**, which is opt-in: it happens on a node with
no prep record, or when you pass `--prep`, and not otherwise. This matters more
than convenience. The file is generated *for whoever is running the script*, so
when it ran on every invocation, a later run as a different user silently
re-pointed the NOPASSWD grant at them. `--no-prep` skips it outright.

**Node preparation no longer renames the machine unless asked.** `--rename NAME`
is the only thing that sets a hostname. The name used to be derived from the
service flags of the current invocation and applied as a side effect, so
installing one more component could rename a working node.

## The one-file bundle

`dist/starwright.pyz` (or `starwright.pyz`) is a zipapp containing Textual,
Rich, and a copy of every installer script. Notes:

- Release artifacts are built in CI from a tag and published with a **SHA-256
  checksum**. Verify it if you didn't build it yourself.
- The bundled scripts are a **snapshot from build time**. If a checkout is
  present on disk, that wins - the bundle is only used when there's nothing to
  prefer. The extraction path is printed at startup so you can read what you're
  actually about to run.
- It does **not** bundle a Python interpreter, so it inherits whatever `python3`
  is on the target.

## Not secrets, but worth stating

`--describe` is designed to be side-effect free and safe to run anywhere. It
reads local files (`/etc/nv_tegra_release`, module presence, `hostname`) and
reports platform facts. It makes no network calls and creates nothing. CI
asserts both of those properties on every push.
