# pi-dev-playground

A playground for exploring the [**pi**](https://github.com/earendil-works/pi) library
(`@earendil-works/pi-*`, published under the `pi.dev` project) to build AI agents.

Pi is an open-source AI agent framework with a **unified multi-provider LLM API**
(OpenAI, Anthropic, Google, Mistral, xAI, and many more), token/cost tracking,
tool calling, and an extensible agent core. We start here with Node.js Jupyter
notebooks so we can experiment interactively.

## Layout

```
notebooks/
  01-hello-world.ipynb   # verify the toolchain: one LLM round-trip via pi-ai
```

## Setup

### 1. Install Node dependencies

```bash
npm install
```

This installs [`@earendil-works/pi-ai`](https://www.npmjs.com/package/@earendil-works/pi-ai)
(the unified LLM API) and [`tslab`](https://github.com/yunabe/tslab)
(a TypeScript/JavaScript Jupyter kernel).

### 2. Install Jupyter + register the TypeScript kernel

The notebooks run on **tslab** (TypeScript). You need Jupyter and the kernel registered once:

```bash
pip install jupyterlab          # or: pip install notebook
npx tslab install --python=python3
```

Verify the kernel is registered:

```bash
jupyter kernelspec list         # should list "tslab"
```

### 3. Provide a provider API key

pi resolves credentials from environment variables. Export **one** before launching Jupyter:

```bash
export ANTHROPIC_API_KEY=sk-ant-...   # or OPENAI_API_KEY, or GEMINI_API_KEY, ...
```

See the [pi-ai env var table](https://github.com/earendil-works/pi/blob/main/packages/ai/README.md#environment-variables)
for the full provider list.

### 4. Launch

```bash
jupyter lab
```

Open `notebooks/01-hello-world.ipynb`, make sure the kernel is **TypeScript**, and run the cells.

## Notes

- The `tslab` kernel resolves `node_modules` from the directory where you launch Jupyter,
  so run `jupyter lab` from the **repository root**.
- API keys are only ever read from the environment — never write them into a notebook cell.
