<!-- Date: 2026-07-18 — brief template, rendered VERBATIM to agents (BriefTemplate strips this header at render). Prose = calibration data (F-23): edit freely, tokens {{...}} are filled by the engine. -->
# Brief eval — judge decision

⚠ YOUR ROLE IS TO **JUDGE**, NOT TO PRODUCE. Create NO file, commit
NOTHING, run NO build task. The BRIEF to validate (written by the architect) is quoted below. Your only output is a **decision** returned via `submit_result`.

## Context
- Pipeline: {{pipeline}}
- Judged step: {{step}}
- Gate: type {{gate_type}}
{{request_section}}
## Question to decide
The brief `{{step}}` was written by the architect and has NOT been executed yet. Given the brief below, is it EXECUTABLE as-is (clear, complete, coherent, actionable by an engineer without further questions) — `continue` — or must it be sent back / escalated / abandoned?

## Brief to judge (written by the architect — to validate BEFORE any execution)

{{subject_body}}

## Gate rules (reference)
```
{{gate_rules}}
```

## Expected decision — strict JSON (`gate-decision-v1.json`)
`{"decision": "<...>", "reason": "<structured rationale>", "details": {...}, "chain": [...]}`

`decision` ∈ {{decisions}}
- `continue`: the brief is executable as-is (clear, complete, actionable) → advance to the next step
- `redirect`: send back to the architect (e.g. brief too big → ask for a split)
- `abandon`: abandon the issue (not recoverable)
- `escalate_user`: beyond the gatekeeper → the user decides
- `halt_wait_input`: missing information → halt and wait

## How to return your decision
Call `mcp__fleet__submit_result` with, as the **result**, the JSON object
gate-decision-v1.json above. The `decision` field is MANDATORY and must
be one of the listed values — without it, the runtime escalates to a human
(fail-closed). Minimal example: `{"decision": "continue", "reason": "..."}`.
