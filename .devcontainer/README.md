# Devcontainer: run the samples behind a litellm proxy

This devcontainer lets you run the `samples/` course without ever putting a
real Azure AI Foundry API key in a file — not in the repo, not in a `.env`,
not anywhere on disk in this container. The real key only ever gets typed
into the litellm admin UI and stored in litellm's own Postgres database.

## How it works

Three containers, defined in [`docker-compose.yml`](./docker-compose.yml):

- **`db`** — Postgres, used only by litellm to persist models, credentials,
  and virtual keys ([`store_model_in_db`](./litellm/config.yaml)). Data lives
  in the named volume `litellm-db-data`, so it survives container rebuilds
  until you explicitly remove the volume.
- **`litellm`** — the [litellm](https://github.com/BerriAI/litellm) proxy and
  its admin UI. [`litellm/config.yaml`](./litellm/config.yaml) deliberately
  has no models or credentials in it — you add those through the UI instead.
- **`workspace`** — the container VS Code / Claude Code attaches to. It has
  Node, Deno, PowerShell (`pwsh`), and the `pi` CLI installed
  ([`Dockerfile`](./Dockerfile)). It only ever knows the litellm proxy's URL
  (`http://litellm:4000/v1`) and a virtual key you generate and paste in
  yourself — never the real Azure credential.

`LITELLM_MASTER_KEY` and `LITELLM_SALT_KEY` on the `litellm` service, and the
Postgres password on `db`, are fixed placeholder values in
`docker-compose.yml`. They are not provider secrets — they are local-only
values that only matter within this docker network, so there is nothing
sensitive to keep out of the compose file. Change them if you like, but it's
not required for local use.

## 1. Start the devcontainer

In VS Code: **Reopen in Container**. With the Claude Code / Dev Containers CLI:

```bash
devcontainer up --workspace-folder .
```

`postCreateCommand` runs [`postCreate.sh`](./postCreate.sh), which checks
`pi` and waits for the litellm proxy's health endpoint.

## 2. Log into the litellm admin UI

Open `http://localhost:9940/ui`. The litellm proxy's port 4000 is published
to the host as `9940` (see `docker-compose.yml`) so it won't collide with
anything else already listening on 4000 on your machine.

- Username: `admin`
- Password: `sk-devcontainer-local` (the `LITELLM_MASTER_KEY` above)

## 3. Add your real Azure AI Foundry credential as a model

In the UI, go to **Models → Add Model** and create an entry for each
deployment you want to use:

- Provider: **OpenAI-Compatible Endpoints** (custom `api_base`)
- API Base: your Azure AI Foundry endpoint, e.g.
  `https://your-resource.services.ai.azure.com/openai/v1`
- API Key: your real Azure AI Foundry API key
- Model name: `cohere-command-a` (and, for the second deployment,
  `Kimi-K2.5`) — these must match the model IDs registered in the `litellm`
  provider block of [`../samples/models.json`](../samples/models.json)

This is the only place the real key is ever entered. It's stored encrypted in
the `db` Postgres container, not in any file in this repo.

## 4. Generate a virtual key

Go to **Keys → Create Key**, scope it to the model(s) you just added, and
copy the generated `sk-...` value.

## 5. Configure the virtual key in the workspace container

From a shell in the `workspace` container:

```bash
export LITELLM_MASTER_KEY=sk-...   # the virtual key from step 4
```

This only lasts for the current shell. To persist it across shells/sessions,
drop it into any `.env` file outside the repo — the samples' existing
`prepare.sh`/`prepare.ps1` scripts already walk up from the sample directory
loading every `.env` they find, closest-first, so a `.env` in your home
directory (or anywhere above the repo) works without repo changes.

## 6. Run a sample against the proxy

```bash
cd samples/001-helloworld
source ./prepare.sh
pi --model "litellm/cohere-command-a" \
  --tools write,read \
  -p 'Write a short, warm fable about a cat. Save it to fable.md.'
```

Interactively, run `pi` and pick a `litellm/...` entry from `/model`.

## Troubleshooting

- `docker compose -f .devcontainer/docker-compose.yml logs litellm` — proxy
  startup and upstream request errors.
- `docker compose -f .devcontainer/docker-compose.yml logs db` — Postgres
  issues.
- `curl http://localhost:9940/health/liveliness` from the host, or
  `wget -qO- http://litellm:4000/health/liveliness` from inside the
  workspace container.
- Getting 401s from `pi`: the model/key was probably added in the UI under a
  different model name than `cohere-command-a` / `Kimi-K2.5`, or
  `LITELLM_MASTER_KEY` in your shell isn't the virtual key from step 4.
- To start over with a clean litellm database:
  `docker compose -f .devcontainer/docker-compose.yml down -v` (this deletes
  the `litellm-db-data` volume, so the real key and any generated virtual
  keys are gone — you'll redo steps 2-4).
