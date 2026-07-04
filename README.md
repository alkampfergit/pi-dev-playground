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

```
notebooks/
  00-hello-typescript.ipynb   # simplest check: TypeScript runs in a notebook
  01-hello-world.ipynb        # one LLM round-trip via pi-ai (Anthropic → Haiku)
env.ts                        # walk-up .env loader (see below)
deno.json                     # import map + npm deps for Deno
```

## Setup

### 1. Install Deno + register its Jupyter kernel

```bash
brew install deno            # or: curl -fsSL https://deno.land/install.sh | sh
deno jupyter --install
```

### 2. Install Jupyter

```bash
pip3 install jupyterlab      # any Jupyter front-end works
jupyter kernelspec list      # should list "deno"
```

### 3. Cache the npm dependencies

```bash
deno install                 # reads deno.json, populates node_modules/
```

### 4. Provide a provider API key — outside the repo

pi resolves credentials from environment variables. Keep your key **on disk but outside
the git repo** so it can never be committed. Create a `.env` in a parent directory:

```bash
# e.g. one level above this repo:  ../.env
ANTHROPIC_API_KEY=sk-ant-...
```

The notebooks call `loadEnvUp()` (from `env.ts`), which **walks up the directory tree**
from the current folder, finds the first `.env`, and imports its variables into the
session. See `.env.example` for the supported keys. Anthropic uses **Haiku**
(`claude-haiku-4-5`) in `01-hello-world.ipynb`; swap in OpenAI/Google by adding a key.

### 5. Launch (from the repo root)

```bash
jupyter lab
```

Open a notebook, ensure the kernel is **Deno**, and run the cells. Launch from the repo
root so the `playground/env` import alias (defined in `deno.json`) resolves.

## Notes

- `env.ts` never overwrites variables already exported in your shell (pass
  `{ override: true }` to `loadEnvUp` if you want it to).
- Keys are only ever read from a `.env` / the environment — never write them into a cell.
- `.env` is git-ignored; only `.env.example` is committed.
