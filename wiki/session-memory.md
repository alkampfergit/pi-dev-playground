# Session Memory

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
