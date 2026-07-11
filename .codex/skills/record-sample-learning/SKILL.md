---
name: record-sample-learning
description: Capture verified learnings after completing one or more repository samples or a learning session. Use when the user asks to update AGENTS.md, document sample progress, preserve session decisions, maintain the docs course, record user preferences, or improve future sessions from what was just learned.
---

# Record Sample Learning

Use this skill after a sample or group of samples is complete, especially when
the user corrected a workflow or revealed a preference that should help future
sessions. Update documentation and memory; do not start new sample work unless
the user asks for it.

## Workflow

1. Locate the repository root and inspect only the relevant `AGENTS.md`,
   `docs/`, `wiki/`, sample `README.md` files, notebooks, changed files, and
   recent verification output. Preserve unrelated user changes.
2. Extract only durable, transferable learnings from the user's requests,
   corrections, and verified results. A learning belongs in memory only when it
   would help build, refactor, or troubleshoot a different sample or skill.
   Separate facts from assumptions. Never record API keys, tokens, private
   URLs, or other secrets.
3. Apply progressive disclosure:
   - Keep `AGENTS.md` short: stable project rules, conventions, and links.
   - Keep `docs/` as the Pi course: concepts, learning order, and links to real
     repository examples; do not duplicate complete code from samples or
     notebooks.
   - Keep `wiki/samples.md` short: one useful paragraph per sample and a link
     to its README.
   - Keep detailed history in `wiki/session-memory.md`.
   - Keep runnable commands and implementation detail in each sample README or
     notebook.
4. Update `AGENTS.md` with only rules that will remain useful across sessions.
   Add or repair links to the course, wiki memory, and sample catalog when
   needed.
5. Keep the course current. When a completed sample or notebook teaches a new
   concept, update the most relevant file under `docs/` or add a focused course
   page. Explain the idea briefly, link to the real sample/notebook with a
   repository-relative path, and mention what the learner should observe. Use
   the actual artifact as the source of truth; avoid copied code that can drift.
6. Create or update `wiki/session-memory.md` using this structure, newest entry
   first:

   ```markdown
   # Session Memory

   ## YYYY-MM-DD — Short topic

   - Reusable principles:
   - User preferences:
   - Validation lessons:
   - Documentation map:
   ```

   Keep entries concise, factual, and linked to affected files. Record the
   principle, constraint, or decision—not the story of one implementation.
   Merge duplicates instead of repeating the same learning.

   Do **not** record sample numbers, exact commands, prompt/output examples,
   session IDs, timestamps beyond the entry date, temporary alternatives,
   implementation filenames, or incidental model/version details. Keep those
   in the sample README, code comments, test output, or course page. Link to an
   artifact only in `Documentation map` when it helps a future maintainer find
   the source of truth.
7. Update `wiki/samples.md` only when the sample's purpose, usage, or lesson
   changed. Do not copy the full sample README into the catalog.
8. Validate with `git diff --check`, confirm referenced files exist, and run a
   lightweight relevant check. Re-run an external model call only when it is
   necessary and safe; use existing verified output otherwise.

## Completion

Report the files updated, the durable learning captured, the course pages
updated, and the checks run. If the session contains no durable learning, say
so and avoid adding noise to the memory.
