Use the delegate tool with its `chain` form and exactly two steps: `scout`, then
`reviewer`. The scout must find `WAREHOUSE_REGION=eu-west` in the fixed tiny
fixture and report its exact relative path. The reviewer task must contain the
literal `{previous}` token so the scout report is handed off as evidence. Ask
the reviewer to verify the claim and return VERIFIED or NEEDS_WORK.
