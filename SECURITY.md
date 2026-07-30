# Security

## Reporting

Open a [private security advisory](../../security/advisories/new) rather than a
public issue. If that isn't available to you, a normal issue asking for a
private channel is fine — don't put the details in it.

No bounty, no SLA. This is a personal project. But a real report gets a real
answer.

## What this software does, so you can judge the risk yourself

Seren Starwright is an **installer**. It is not a sandbox, and it is not trying
to be one. Running it means:

- **Executing shell/PowerShell scripts** from this repository on your machine.
- **`sudo` / Administrator operations** during node preparation: `apt-get`,
  `nvpmodel`, hostname changes, and writing a `sudoers.d` drop-in.
- **Registering system services** — systemd units, launchd agents, or NSSM
  services — that start on boot and run as you.
- **Downloading packages** from PyPI and, optionally, release artifacts from
  GitHub.

Read the scripts before you run them. They're plain text, deliberately, and
`--describe` tells you what an installer will do without doing any of it.

## Defaults worth knowing about

**Services bind to localhost by default, except two.** `seren-lodestar` and
`seren-observatory` default to `0.0.0.0` because they're cluster-facing by
design. Everything else — memory, loci, corpus-callosum, workbench, margin,
probe — is `127.0.0.1` unless you widen it.

**Bearer tokens are optional and off by default.** The stack assumes a trusted
LAN. `--gen-token` generates one; without it, anything that can reach the port
can use the service. If a Seren service is reachable from an untrusted network,
you want a token *and* something in front of it.

**MCP endpoints ship with DNS-rebinding protection disabled.** That's a
deliberate trusted-LAN choice so a connected client can reach a service by
hostname. Re-arm it with `SEREN_<SERVICE>_MCP_ALLOWED_HOSTS`.

**Node preparation writes a `sudoers.d` drop-in** granting specific NOPASSWD
commands (power profile, cache drop) to the target user. It's narrow, but it is
a privilege grant — read `nodes/lib/seren-sudoers-update.sh` before you accept
it.

## The one-file bundle

`dist/starwright.pyz` (or `starwright.pyz`) is a zipapp containing Textual,
Rich, and a copy of every installer script. Notes:

- Release artifacts are built in CI from a tag and published with a **SHA-256
  checksum**. Verify it if you didn't build it yourself.
- The bundled scripts are a **snapshot from build time**. If a checkout is
  present on disk, that wins — the bundle is only used when there's nothing to
  prefer. The extraction path is printed at startup so you can read what you're
  actually about to run.
- It does **not** bundle a Python interpreter, so it inherits whatever `python3`
  is on the target.

## Not secrets, but worth stating

`--describe` is designed to be side-effect free and safe to run anywhere. It
reads local files (`/etc/nv_tegra_release`, module presence, `hostname`) and
reports platform facts. It makes no network calls and creates nothing. CI
asserts both of those properties on every push.
