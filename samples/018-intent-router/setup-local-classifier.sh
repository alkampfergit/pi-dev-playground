#!/usr/bin/env bash
set -euo pipefail

sample_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export UV_CACHE_DIR="$sample_dir/.uv-cache"
export HF_HOME="$sample_dir/.hf-home"
export HF_HUB_CACHE="$HF_HOME/hub"

if ! command -v uv >/dev/null 2>&1; then
  echo "Install uv first: https://docs.astral.sh/uv/getting-started/installation/" >&2
  exit 1
fi

python="$sample_dir/.venv/bin/python"
if [[ ! -x "$python" ]]; then
  uv venv --python 3.12 "$sample_dir/.venv"
fi
uv pip install --python "$python" \
  'gliner2[local]==2.2.0'
"$python" "$sample_dir/gliner/download_model.py"
echo "Ready. Local classifier Python: $python"
