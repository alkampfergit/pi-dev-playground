# pi-dev-playground

A playground for exploring the [**pi**](https://github.com/earendil-works/pi) library
(`@earendil-works/pi-*`, the "pi.dev" project) to build AI agents.

Pi is an open-source AI agent framework with a **unified multi-provider LLM API**
(OpenAI, Anthropic, Google, Mistral, xAI, and many more), token/cost tracking,
tool calling, and an extensible agent core. We start with TypeScript Jupyter
notebooks so we can experiment interactively.

## Why Deno (not Node.js)?

The notebooks run on the **Deno** Jupyter kernel. `@earendil-works/pi-ai` is an
**ESM-only** package (its `exports` map defines only the `import` condition, no
`require`). Node's CommonJS-based Jupyter kernels (**tslab**, ijavascript) transpile
to `require()` and therefore **cannot import pi.dev at all**. Deno runs TypeScript and
ESM natively, supports top-level `await`, and loads npm packages via `npm:` specifiers —
so it runs pi.dev out of the box while staying a TS/JS (non-Python) notebook.

## Layout

Everything the notebooks need lives in `notebooks/` (so the Deno kernel — whose working
directory is the notebook's folder — always finds `deno.json`):

```
notebooks/
  00-hello-typescript.ipynb        # simplest check: TypeScript runs in a notebook
  01-hello-world.ipynb             # one LLM round-trip via pi-ai (Azure OpenAI)
  02-streaming.ipynb               # streamSimple + iterating the event stream
  03-multi-turn-chat.ipynb         # managing Context.messages history + running cost
  04-tool-calling.ipynb            # Tool + TypeBox schema, the manual agent loop
  05-structured-output.ipynb       # typed JSON via a forced tool + validateToolCall
  06-vision-image-input.ipynb      # multimodal ImageContent input
  07-reasoning-thinking.ipynb      # reasoning levels + ThinkingContent blocks
  08-cost-caching-robustness.ipynb # calculateCost, cacheRetention, abort, retries
  09-multiple-providers.ipynb      # unified API across several models/providers
  10-agent-framework.ipynb         # @earendil-works/pi-agent-core Agent class
  env.ts                           # walk-up .env loader
  azure.ts                         # shared registerAzure() provider setup helper
  deno.json                        # import map + npm deps for Deno
  deno.lock                        # pinned dependency lockfile (committed)
  .env.example                     # which API keys are supported
```

Notebooks **02 onward** are a progressive series: each loads env with `loadEnvUp()`
then registers Azure OpenAI in one call via `registerAzure()` (from `azure.ts`),
so the notebook stays focused on the one pi feature it teaches. They all target the
same `AZURE_PI_TEST_*` env vars as `01`.

---

## Setup on a new computer (after a fresh clone)

### 1. Install the prerequisites

```bash
# Deno (the runtime + Jupyter kernel)
brew install deno                    # or: curl -fsSL https://deno.land/install.sh | sh

# A Jupyter front-end. Either:
#   (a) JupyterLab in the browser:
pip3 install jupyterlab
#   (b) or just use VS Code with the "Jupyter" extension installed.
```

### 2. Register the Deno Jupyter kernel

```bash
deno jupyter --install
jupyter kernelspec list              # should list "deno"
```

### 3. Cache the dependencies

```bash
cd notebooks
deno install                         # reads deno.json / deno.lock, populates node_modules/
```

### 4. Add your API key — in a `.env` OUTSIDE the repo

Keep your key on disk but **outside the git folder** so it can never be committed.
Create a `.env` in a parent directory (see `notebooks/.env.example` for supported keys):

```bash
# e.g. one directory above the repo:  ../.env
ANTHROPIC_API_KEY=sk-ant-...
```

Cell 1 of each notebook calls `loadEnvUp()` (from `env.ts`), which **walks up the
directory tree** from the notebook folder and loads **every** `.env` it finds,
**closest-first** (a nearer `.env` wins on conflicts), printing the keys loaded from
each. Anthropic uses **Haiku** (`claude-haiku-4-5`) in
`01-hello-world.ipynb`; add `OPENAI_API_KEY` or `GEMINI_API_KEY` to use another provider.

### 5. Open a notebook and select the **Deno** kernel

**JupyterLab:**

```bash
cd notebooks
jupyter lab
```

Open a notebook, and in the top-right kernel picker choose **Deno**.

**VS Code:**

1. Open `notebooks/01-hello-world.ipynb`.
2. Click the kernel picker (top-right) → **Select Another Kernel…** → **Jupyter Kernel…** → **Deno**.
3. Run the cells.

> ⚠️ **Do not pick "TypeScript" (tslab).** It's a CommonJS kernel and cannot load pi.dev;
> it fails with `Cannot find module` / `Unexpected pending rebuildTimer` and also
> re-saves the wrong kernel into the notebook file. Always choose **Deno**.
>
> If the **Deno** kernel isn't listed in VS Code, it was installed while VS Code was
> running: `Cmd/Ctrl+Shift+P` → **Developer: Reload Window** (and if needed
> **Jupyter: Clear Kernel Cache**, then reload again).

---

## Notes

- `env.ts` never overwrites variables already exported in your shell (pass
  `{ override: true }` to `loadEnvUp` if you want it to).
- Keys are only ever read from a `.env` / the environment — never write them into a cell.
- `.env` is git-ignored; only `.env.example` is committed.
- Re-run `deno install` in `notebooks/` whenever `deno.json` changes.
