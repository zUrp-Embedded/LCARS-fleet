<!-- Date: 2026-07-18 — brief template, rendered VERBATIM to agents (BriefTemplate strips this header at render). Prose = calibration data (F-23): edit freely, tokens {{...}} are filled by the engine. -->
# Deliverable eval — judge decision

⚠ YOUR ROLE IS TO **JUDGE**, NOT TO PRODUCE. Create NO file, commit
NOTHING, run NO build task. The deliverable already exists (it is quoted below). Your only output is a **decision** returned via `submit_result`.

## Context
- Pipeline: {{pipeline}}
- Judged step: {{step}}
- Gate: type {{gate_type}}
{{request_section}}
## Question to decide
The step `{{step}}` delivered its result. Given the deliverable below and the
gate rules, should the gate be crossed (`continue`) — or abandon /
send back / escalate?

## Deliverable to judge (step outputs — ALREADY produced, to evaluate)
```
{{subject_body}}
```

## Gate rules (reference)
```
{{gate_rules}}
```

## Expected decision — strict JSON (`gate-decision-v1.json`)
`{"decision": "<...>", "reason": "<structured rationale>", "details": {...}, "chain": [...]}`

The envelope is schema-VALIDATED and fail-closed: a mistyped field halts the step run, it is not
coerced. `decision` and `reason` are required; the two optional fields have an enforced shape.

- `details` — un objet de scalaires (une ligne `- **clé** : valeur` chacun), **PLUS la clé
  versionnée `findings_v1`, qui est un OBJET et la seule exception à la platitude — quel que soit
  ce que tu juges** :

  ```json
  "details": {
    "gate_rule": "R-coverage",
    "findings_v1": {
      "findings": [
        {"severity": "minor", "category": "divergent",
         "description": "nommage incohérent avec le reste du module", "refs": ["lib/x.sh:12"]}
      ],
      "severity_max": "minor"
    }
  }
  ```

  `findings` est obligatoire dans cet objet — **liste vide si tu n'as rien à signaler** : dire
  l'absence est une mesure, l'omettre n'en est pas une. `severity` ∈ `critical|important|minor` ;
  `severity_max` ∈ les trois plus `none`. Ta prose est lue par des humains, cette clé est lue par
  le RAIL : c'est elle qui permet à la carte du projet de PESER ton verdict au lieu de seulement le
  compter. Ne la sérialise pas en chaîne — c'est un objet.
  Example: `{"test_added": "none", "gate_rule": "R-coverage"}`
- `chain` — an array of PLAIN STRINGS, one reasoning step per entry, rendered as bullets under
  "Raisonnement". An array of objects is REFUSED (`#/chain/0: expected String`).
  Example: `["the diff touches the launcher", "no bats case covers it", "→ redirect"]`

`decision` ∈ {{decisions}}
- `continue`: the deliverable satisfies the gate → advance to the next step
- `redirect`: send back to the architect (e.g. brief too big → ask for a split)
- `abandon`: abandon the issue (not recoverable)
- `escalate_user`: beyond the gatekeeper → the user decides
- `halt_wait_input`: missing information → halt and wait

## How to return your decision
Call `mcp__fleet__submit_result` with, as the **result**, the JSON object
gate-decision-v1.json above. The `decision` field is MANDATORY and must
be one of the listed values — without it, the runtime escalates to a human
(fail-closed). Minimal example: `{"decision": "continue", "reason": "..."}`.
