# Session Memory

## 2026-07-11 — Orchestration, RPC, and live interaction

- Reusable principles:
  - Treat subprocess agents as an explicit trust boundary: give each role a
    narrow policy, isolated state, bounded output, a timeout, and cancellation.
  - Verify session operations structurally through identifiers, ancestry, entry
    types, and counts; saved prompts and summaries remain sensitive content.
  - A persistent JSONL controller needs strict one-record framing, request
    correlation, bounded event buffers, deterministic shutdown, and an explicit
    policy for UI requests that cannot be served headlessly.
  - Interactive extensions should guard TUI-only capabilities and retain useful
    print/RPC behavior when no terminal UI exists.
  - Test live steering at event-driven checkpoints and wait for settlement.
    Installed runtime evidence takes priority over conclusions inferred from one
    surface method; abort settlement can consume queued guidance indirectly.
- User preferences:
  - Use separate design and implementation agents for independent advanced
    samples, then reconcile them with one repository-wide verification pass.
  - Keep subagents, session trees, RPC, custom UI, and live steering as focused
    lessons rather than merging their complexity into one application.
- Validation lessons:
  - Pair model-free protocol/state tests with a small live probe only where a
    model boundary matters.
  - Assert queue transitions, correlation IDs, lifecycle events, and cleanup;
    do not grade model wording or depend on timing sleeps.
  - Terminal UI automation can cover startup and degradation paths, while
    shortcut, dialog, reload, and resize behavior still needs an explicit
    human checklist when no deterministic terminal harness is available.
- Documentation map:
  - [CLI course](../docs/cli-samples.md), [sample catalog](samples.md), and the
    [design briefs](../docs/planned-samples/README.md) link to the runnable
    material and detailed acceptance criteria.

## 2026-07-11 — Operating, distributing, and integrating CLI agents

- Reusable principles:
  - Separate capability selection from per-call authorization. Headless policy
    paths should fail closed, and denials should be returned as model-visible
    tool results.
  - Model switching can preserve conversation history; verify both the next
    provider request and the session's model-change record.
  - Test automation structurally: validate process status, event shape, output
    schema, capability policy, and persistence behavior instead of judging prose.
  - Install and remove packages inside an isolated configuration, restore the
    caller's environment, and prove negative discovery after removal.
  - Treat saved conversations as sensitive data. Lifecycle helpers should expose
    only the metadata needed for the lesson.
  - When a protocol is not built in, make the adapter and process boundary
    explicit and test both healthy and degraded lifecycle paths.
- User preferences:
  - Expand sample designs before implementation and use separate workers for
    design and verified implementation when samples are independent.
  - Keep advanced topics in focused standalone samples with real runnable
    verification rather than combining them into a showcase application.
- Validation lessons:
  - Prefer model-free RPC or direct-contract checks for discovery and lifecycle
    behavior; reserve live model calls for behavior that truly crosses the model
    boundary.
  - Use bounded retries only for nondeterministic model-format failures, never
    to hide process failures or weaken acceptance checks.
  - Keep dependencies pinned where a sample owns a separate protocol process,
    and verify clean installation from the lockfile.
- Documentation map:
  - [CLI course](../docs/cli-samples.md), [sample catalog](samples.md), and the
    [design briefs](../docs/planned-samples/README.md) link to each runnable
    sample and its detailed acceptance criteria.

## 2026-07-11 — Skills, context, and extensions

- Reusable principles:
  - Put stable project-wide rules in `AGENTS.md`; keep specialized, reusable
    procedures in skills. Test each mechanism independently when teaching their
    boundary.
  - Keep a skill's instructions focused on orchestration. Put deterministic
    work in its `scripts/` directory, and test every script directly.
  - Isolate demonstrations by explicitly choosing the resources and tool set
    they need. Use the same explicit setup in interactive and non-interactive
    modes when both are supported.
  - Treat extension tools and built-ins as one active capability set. Change
    that set at the right lifecycle point; runtime actions must wait until the
    session is initialized.
  - Keep auto-discovered resources under the active configuration directory.
    Per-project configuration and machine-wide configuration are separate
    scopes; do not assume resources from one are visible in the other.
  - Centralize shared model configuration and environment preparation, then
    link each sample to those shared resources.
- User preferences:
  - Favor small, focused, runnable learning samples with PowerShell commands
    and teacher-to-student documentation.
  - Prefer a choice between clearly separate implementations over a single
    extension that hides important trade-offs.
- Validation lessons:
  - Run each completed sample. Verify behavior through a real Pi session when
    practical, and use local checks for deterministic scripts.
  - Keep generated sessions, credentials, and diagnostic output out of source
    control. Guard UI-specific extension calls when a sample also supports
    print mode.
- Documentation map:
  - [Project conventions](../AGENTS.md), [CLI course](../docs/cli-samples.md),
    and [sample catalog](samples.md) are the durable source of project and
    learning-path guidance. Each sample README remains the source of runnable
    commands and implementation detail.
