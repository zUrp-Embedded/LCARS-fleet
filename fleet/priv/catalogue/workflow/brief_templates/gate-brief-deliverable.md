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

## MESURE OBLIGATOIRE avant tout verdict — `mcp__fleet__run_probe`

Appelle `mcp__fleet__run_probe` avec `{"probe": "test-relevance"}` **avant** de rendre ta décision.
Ce n'est pas une option offerte, c'est un acte attendu de toi : sans lui, ton avis sur la valeur
d'une suite de tests est une opinion, et une opinion ne contrôle rien.

Tu ne fournis ni dépôt, ni PR, ni SHA, ni chemins — ils viennent de ton canal et des déclarations du
projet. Tu n'as qu'un nom à écrire.

**Ce que la sonde te rend.** Elle remet le code de cette livraison à son état de base *en gardant sa
suite*, et regarde si la suite s'en aperçoit :

- `verdict=relevant` — la suite devient rouge sans le code livré : **elle le prouve**.
- `verdict=blind` — la suite reste **verte sans le code livré**. C'est un fait sur la SUITE, pas un
  verdict sur la livraison : à toi de décider ce que ça vaut ici. Une suite aveugle sur un livrable
  trivial n'est pas la même chose qu'une suite aveugle sur la logique qu'on t'a demandé de couvrir.
- `verdict=inapplicable` — rien n'était mesurable, et `reason` dit quoi (`head-suite-red` : la suite
  était déjà rouge, donc rien n'est concluable ; `no-harness-declared` : le projet ne déclare pas
  ses chemins de preuve). **`inapplicable` n'est PAS un vert** — c'est l'absence de mesure, et la
  raconter comme une mesure réussie serait le seul vrai mensonge possible ici.

⚠ **Le fait ne décide pas à ta place.** La sonde rapporte, tu tranches. Elle ne peut ni t'obliger à
refuser, ni t'autoriser à approuver : elle t'enlève seulement la possibilité de conclure sans avoir
regardé.

⚠ **Et son échec ne te bloque pas.** Runner mort, workflow absent, attente épuisée : rends ton
verdict quand même, en le disant dans ton `reason`. Ce mécanisme est un GAIN, jamais une condition
d'avancement — le rail, lui, sait constater après coup si cette tête a été sondée.

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
