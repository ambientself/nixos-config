#!/usr/bin/env bash
# Refuse any file under a secret path that is not actually sops-encrypted.
#
# This repository is PUBLIC. A secret committed in plaintext for a single commit
# is public permanently: public repos are cloned, mirrored and archived within
# minutes, and git history cannot be recalled. So this check is mechanical and
# runs in two places -- a pre-commit hook, and CI, because a hook can be skipped
# with --no-verify and a public mistake cannot be unmade.
#
# Usage:
#   check-secrets-encrypted.sh <file>...   check the named files
#   check-secrets-encrypted.sh            check every tracked file
set -uo pipefail

# Default deny. Everything under these paths must be encrypted unless it is
# explicitly allowed below -- the allowlist is deliberately tiny, because the
# safe direction for this check is to complain about a harmless file rather
# than to stay quiet about a real one.
is_secret_path() {
    case "$1" in
        secrets/*|*/secrets/*|*.enc) return 0 ;;
        *) return 1 ;;
    esac
}

is_allowed_plaintext() {
    case "${1##*/}" in
        .gitkeep|README.md) return 0 ;;
        *) return 1 ;;
    esac
}

# Every sops-encrypted value carries this marker, in every output format --
# yaml, json, env, and the single `data` blob of binary format.
SOPS_MARKER='ENC\[AES256_GCM'

# Deliberately avoids `mapfile`: macOS still ships bash 3.2, and a guard that
# crashes on a fresh clone is a guard that is not running.
files=()
if [ "$#" -gt 0 ]; then
    files=("$@")
else
    while IFS= read -r line; do files+=("$line"); done < <(git ls-files)
fi
[ "${#files[@]}" -eq 0 ] && { echo "secrets check: nothing to check"; exit 0; }

bad=()
for f in "${files[@]}"; do
    [ -f "$f" ] || continue
    is_secret_path "$f" || continue
    is_allowed_plaintext "$f" && continue
    if ! grep -qE "$SOPS_MARKER" "$f" 2>/dev/null; then
        bad+=("$f")
    fi
done

if [ "${#bad[@]}" -eq 0 ]; then
    echo "secrets check: ok"
    exit 0
fi

cat >&2 <<EOF

  REFUSED: these files sit on a secret path but are not sops-encrypted.

EOF
for f in "${bad[@]}"; do printf '    %s\n' "$f" >&2; done
cat >&2 <<EOF

  This repository is public. Committing one of these in plaintext publishes it
  permanently -- rotating the credential afterwards means REVOKING it at the
  provider, not re-encrypting the file.

  Encrypt it first:
      sops --encrypt --in-place <file>                 # yaml / json / env
      sops --encrypt --input-type binary --output-type binary \\
           <file> > <file>.enc && rm <file>            # keys, certs, blobs

EOF
exit 1
