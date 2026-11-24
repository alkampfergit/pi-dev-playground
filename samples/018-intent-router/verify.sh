#!/usr/bin/env bash
set -euo pipefail

sample_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$sample_dir/../.." && pwd)"

for link in models.json settings.json prepare.ps1 prepare.sh; do
  target="$(readlink "$sample_dir/$link")"
  [[ "$target" == "../$link" ]] || { echo "$link must point to ../$link" >&2; exit 1; }
done

node --experimental-strip-types "$sample_dir/tests/router.test.ts"
old_agent_dir="${PI_CODING_AGENT_DIR-}"
old_offline="${PI_OFFLINE-}"
export PI_CODING_AGENT_DIR="$sample_dir"
export PI_OFFLINE=1
trap 'export PI_CODING_AGENT_DIR="$old_agent_dir" PI_OFFLINE="$old_offline"' EXIT
models="$(cd "$repo_root" && pi --offline --list-models intent/auto 2>&1)"
if ! grep -Eq '^intent[[:space:]]+auto([[:space:]]|$)' <<<"$models"; then
  printf 'Pi did not register intent/auto. Output:\n%s\n' "$models" >&2
  exit 1
fi
echo 'PASS: router policy tests and Pi virtual-model discovery.'
