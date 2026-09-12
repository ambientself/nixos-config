# nixos-config

NixOS configuration for my machines, pulled by each machine rather than pushed
from a workstation.

The reasoning behind the design, and the measurements it rests on, live in
`docs/nix-pi-plan.md` in the repository this was split out of.

## Layout

| | |
|---|---|
| `.sops.yaml` | who can decrypt what |
| `secrets/` | encrypted, one file per host |
| `scripts/` | checks that run in the hook and in CI |
| `.githooks/` | enable with `git config core.hooksPath .githooks` |

## This repository is public, on purpose

The machines clone it anonymously, so nothing secret has to be placed on a card
before a machine can start configuring itself. Secrets live here as sops
ciphertext, encrypted to my own key and to each host's own key.

That choice has consequences, and they are the reason for the rules below.

**Published ciphertext is permanent.** Public repositories are cloned, mirrored
and archived within minutes, and git history cannot be recalled.

1. **Rotating a credential means revoking it at the provider.** Re-encrypting is
   not rotation. A credential whose ciphertext is public forever is safe only
   because it no longer works.
2. **Never commit a secret in plaintext, even for one commit.** This is enforced
   rather than remembered — see below — because it cannot be undone.
3. **Do not annotate.** Configuration describes what a machine runs. It does not
   need to explain which parts are worth attacking.

## The guard

`scripts/check-secrets-encrypted.sh` refuses any file on a secret path that is
not sops-encrypted. It is default-deny: everything under `secrets/`, and anything
named `*.enc`, must carry sops' encryption marker, with a two-entry allowlist for
`.gitkeep` and `README.md`.

It runs in two places on purpose. The pre-commit hook catches a mistake before it
exists; CI catches it when the hook was skipped with `--no-verify` or never
enabled on a fresh clone.

CI also runs a **positive control** — it writes a plaintext file and fails the
build if the check *passes* it. A guard that has never refused anything has not
been tested, and a check that silently stops working looks exactly like a check
that never has anything to complain about.

Enable the hook once per clone:

```bash
git config core.hooksPath .githooks
```

## Adding a host

A machine's own key is only available once the machine exists, so this happens
after its first boot, not before:

```bash
ssh-keyscan <host> | nix run nixpkgs#ssh-to-age
```

Add it to `.sops.yaml`, then re-encrypt **every** affected file — `sops
updatekeys` works one file at a time, and a file that is missed becomes a boot
failure on the machine that cannot read its own secret.
