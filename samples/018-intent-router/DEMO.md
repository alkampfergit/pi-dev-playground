# 5-minute demo — harness-level model routing

## Before the talk

1. Configure two available physical models in `intent-router.json` and verify
   their names with Pi:

   ```bash
   cd samples/018-intent-router
   source ./prepare.sh
   pi --list-models
   ```

2. Install the local GLiNER2.5 model once:

   ```bash
   ./setup-local-classifier.sh
   ```

3. Start one session and leave it open for all steps:

   ```bash
   pi --model intent/auto
   ```

## Minute 1: general question

Ask:

```text
Explain OAuth and OIDC in two short paragraphs.
```

Show the `[Intent Router]` notification. It reports GLiNER2.5's measured local
score and decision time, along with the selected configured general model.
Pi's model generates the answer.

## Minute 2: coding task

Ask:

```text
Implement a C# JWT validation helper with issuer and audience checks.
```

Show that the extension selects the configured coding model before Pi makes a
provider request. Pi then uses its normal coding tools and agent loop.

## Minute 3: sticky tool continuation

Ask:

```text
Add cancellation token support and tests for expired and invalid tokens.
```

As Pi inspects and edits files, the extension does not call the classifier again
for tool results. Continuation requests stay with the model already handling
the turn, preserving provider cache and reasoning continuity.

## Minute 4: conversation context

Ask:

```text
Explain why you used that validation order.
```

This prompt is ambiguous by itself. The router sends it with up to three prior
user turns and the previous intent, bounded to 6,000 characters. The classifier
may choose either route; show its actual result instead of promising a fixed
label.

## Minute 5: inspect and explain

Run:

```text
/router status
/router stats
/router config
```

Explain the separation:

- The extension is orchestration policy inside Pi's harness.
- GLiNER2.5 performs local classification; it does not generate the coding answer.
- The selected physical model generates the answer through Pi's normal provider
  path.
- The virtual model and `/router` commands do not change either destination
  model's prompt or weights. This is harness customization rather than ordinary
  prompt engineering.

GLiNER2.5 runs locally after the one-time download, but the destination provider
still receives the conversation needed to answer. Router unit tests prove
fallback and continuation mechanics; the opt-in integration evaluation reports
the actual model's accuracy on the included small labeled dataset.
