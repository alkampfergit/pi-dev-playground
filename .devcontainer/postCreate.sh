#!/usr/bin/env bash
set -euo pipefail

echo "pi --version:"
pi --version || true

echo
echo "Checking the litellm proxy (service: litellm, port 4000)..."
if wget -qO- "http://litellm:4000/health/liveliness" >/dev/null 2>&1; then
    echo "litellm proxy is reachable at http://litellm:4000"
else
    echo "litellm proxy is not reachable yet. It may still be starting;" >&2
    echo "check with: docker compose -f .devcontainer/docker-compose.yml logs litellm" >&2
fi

echo
echo "Devcontainer ready. Next steps (see .devcontainer/README.md for details):"
echo "  1. Open http://localhost:4000/ui and log in as admin / sk-devcontainer-local"
echo "  2. Add your real Azure AI Foundry endpoint + key as a model in the UI"
echo "  3. Generate a virtual key scoped to that model"
echo "  4. export LITELLM_MASTER_KEY=<virtual key> in this shell, then use"
echo "     provider 'litellm' instead of 'azure-openai' in the samples"
