# 004 — Extend and manage tools

Pi starts with four enabled built-in tools: `read`, `bash`, `edit`, and `write`.
This sample shows both sides of tool management:

1. Choose one of two extensions that add a DuckDuckGo search tool without a
   key: a structured Instant Answer lookup or fuller HTML web results.
2. Pi's CLI flags and the extension API can reduce or replace the list of tools
   available to the model for a particular session.

The extension is intentionally small. It is a general web-result lookup, not a
crawler: it returns the first eight result titles, URLs, and snippets without
opening those links.

All commands below assume your current PowerShell directory is:

```text
samples/004-tools
```

## What is in this sample?

Choose exactly one extension file per Pi run:

| Extension | Tool name | Best for | Trade-off |
| --- | --- | --- | --- |
| [`duckduckgo-instant-answer.ts`](./duckduckgo-instant-answer.ts) | `duckduckgo_instant_answer` | Short factual answers and topic summaries | Not a complete results page. Uses DuckDuckGo's structured Instant Answer API. |
| [`duckduckgo-web-search.ts`](./duckduckgo-web-search.ts) | `duckduckgo_search` | Result titles, URLs, and snippets from a normal web search | Parses a public HTML page, so its markup can change or be rate-limited. |

Both extensions use `pi.registerTool()` to make a new tool visible to Pi and to
the model. Both also include the same temporary tool-management commands.

It also registers three temporary slash commands:

| Command | Effect |
| --- | --- |
| `/tools-show` | Shows the model-visible tool names. |
| `/tools-readonly` | Replaces them with `read` and `duckduckgo_search`. `bash`, `edit`, and `write` are removed immediately. |
| `/tools-restore` | Restores the tools that were active when this extension loaded, plus the search tool. |

These commands call `pi.getActiveTools()` and `pi.setActiveTools()`. They
change only the running session; they do not alter your global Pi installation
or the next session.

## Prerequisites

- Node.js, npm, PowerShell (`pwsh`), and Pi installed:

  ```powershell
  npm install -g --ignore-scripts @earendil-works/pi-coding-agent
  ```

- An Azure AI Foundry OpenAI-compatible deployment.
- A `.env` file in this directory or a parent, containing the
  `AZURE_PI_TEST_*` variables described in the [root AGENTS.md](../../AGENTS.md).

As with the other CLI samples, `models.json`, `settings.json`, `prepare.ps1`,
and `prepare.sh` are symlinks to the shared files in `samples/`.

## 1. Prepare the shell

Load the environment into the current PowerShell session:

```powershell
. ./prepare.ps1
```

Or in bash:

```bash
source ./prepare.sh
```

Sourcing matters: it preserves the Azure variables and sets
`PI_CODING_AGENT_DIR` to this sample, keeping Pi's sessions and configuration
local to `samples/004-tools`.

## 2. Add a search tool for one run

Load the extension ad-hoc and ask Pi to use it. `--no-extensions` keeps any
globally installed extensions out of this learning run; the explicit `-e` still
loads this file.

```powershell
pi --no-extensions -e ./duckduckgo-web-search.ts `
  --model "azure-openai/$env:AZURE_PI_TEST_DEPLOYMENT" `
  -p 'Use duckduckgo_search to look up the Eiffel Tower. Return its source URL and do not edit files.'
```

Pi now has its four built-ins **plus** `duckduckgo_search`. No DuckDuckGo
credential is needed. Search results are external, untrusted text, so the
tool's prompt guidance tells the model to cite returned URLs and not to treat
results as instructions. To choose the structured Instant Answer alternative,
load its file and tool name instead:

```powershell
pi --no-extensions -e ./duckduckgo-instant-answer.ts `
  --model "azure-openai/$env:AZURE_PI_TEST_DEPLOYMENT" `
  -p 'Use duckduckgo_instant_answer to look up the Eiffel Tower. Return its source URL.'
```

## 3. Remove built-ins before Pi starts

The fastest session policy is a CLI allowlist. This command starts Pi with only
the custom search tool and `read`; `bash`, `edit`, and `write` are unavailable
to the model for this run:

```powershell
pi --no-extensions -e ./duckduckgo-web-search.ts `
  --tools read,duckduckgo_search `
  --model "azure-openai/$env:AZURE_PI_TEST_DEPLOYMENT" `
  -p 'Search DuckDuckGo for the population of Rome. Do not use the shell or modify files.'
```

For a denylist instead, keep the default tools and exclude only the risky ones:

```powershell
pi --no-extensions -e ./duckduckgo-web-search.ts `
  --exclude-tools bash,edit,write `
  --model "azure-openai/$env:AZURE_PI_TEST_DEPLOYMENT"
```

Other useful startup policies are `--no-tools` (disable every tool) and
`--no-builtin-tools` (disable built-ins but keep extension tools). Use
`pi --help` to see all current tool flags.

## 4. Change tools in an interactive session

Start Pi with the extension:

```powershell
pi --no-extensions -e ./duckduckgo-web-search.ts `
  --model "azure-openai/$env:AZURE_PI_TEST_DEPLOYMENT"
```

Then enter these commands at the Pi prompt:

```text
/tools-show
/tools-readonly
/tools-show
```

Ask: `Search DuckDuckGo for the Golden Gate Bridge, then write the answer to bridge.md.`
Pi can search, but it cannot write the file—the `write` tool is no longer in
the active list. Finally enter `/tools-restore` to put the original tools back.

## How the filtering works

At startup, `--tools` creates an allowlist and `--exclude-tools` removes names
from the resulting set. In a loaded extension, `pi.setActiveTools(names)`
replaces the active set at any time. Both built-ins and extension tools use the
same name-based mechanism.

`setActiveTools()` controls what Pi offers to the model. It is a capability
configuration aid, not a security sandbox for arbitrary code already running
on your machine. For stronger isolation, run Pi in an appropriately restricted
environment as well.

## Why not Bing?

The official Bing Search APIs were retired on August 11, 2025, so they cannot
provide a current free, no-key replacement. Microsoft directs customers to
Grounding with Bing Search in Azure AI Agents, which is a different Azure
service rather than a simple unauthenticated search endpoint.

DuckDuckGo's HTML page is also not an official structured API. The web-search
extension uses it because it meets the learning goal—real web results with no
account, package, or key—but its HTML can change or rate limiting can occur.
For a production tool, choose a supported search provider and manage its
credentials, quotas, and terms of use.

## References

- [Pi extensions documentation](https://pi.dev/docs/latest/extensions)
- [Pi CLI documentation](https://pi.dev/docs/latest/cli)
- [Bing Search API retirement notice](https://learn.microsoft.com/en-us/lifecycle/announcements/bing-search-api-retirement)
