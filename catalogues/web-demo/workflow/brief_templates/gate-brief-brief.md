<!-- Date: 2026-08-10 — Gabarit de brief. Remis TEL QUEL a l'agent. Jetons {{...}} remplis par le runtime.
     Celui-ci sert aux juges dont l'etape porte `judge_target: brief` — ils jugent une DEMANDE. -->
# Relecture de la demande — décision

⚠ **Ton rôle est de JUGER, pas de produire.** Ne crée aucun fichier, ne commite rien, ne lance
aucun build. La demande à évaluer est citée plus bas. Ta seule sortie est une **décision**, rendue
par `submit_result`.

## Contexte
- Pipeline : {{pipeline}}
- Étape jugée : {{step}}
- Type de porte : {{gate_type}}
{{request_section}}
## La question

La demande `{{step}}` a été écrite et **n'a pas encore été exécutée**. Telle qu'elle est ci-dessous,
est-elle **exécutable sans deviner** — un développeur qui n'a pas participé à la discussion peut-il
en sortir le bon résultat ?

Si oui : `continue`. Sinon : renvoi, escalade, ou abandon.

## La demande à juger

{{subject_body}}

## Règles de la porte (référence)
```
{{gate_rules}}
```

## La forme de ta réponse — JSON strict

```
{"decision": "<...>", "reason": "<motif structuré>", "details": {...}, "chain": [...]}
```

L'enveloppe est **validée** : un champ mal typé arrête l'étape, il n'est pas corrigé en silence.
`decision` et `reason` sont obligatoires.

- `details` — un objet **plat** de valeurs simples. Exemple :
  `{"critere_manquant": "comment on sait que c'est fini", "taille": "3 ecrans"}`
- `chain` — un tableau de **chaînes**, une étape de raisonnement par entrée. Un tableau d'objets est
  refusé. Exemple : `["la demande nomme un resultat", "aucun critere d'acceptation", "→ renvoi"]`

`decision` ∈ {{decisions}}

- `continue` — la demande est exécutable telle quelle
- `redirect` — renvoi à l'auteur de la demande (trop large, ambiguë, à découper)
- `abandon` — le ticket n'est pas récupérable
- `escalate_user` — la question dépasse le cadre : un humain décide
- `halt_wait_input` — il manque une information, on s'arrête et on attend

## Comment tu rends

Appelle `mcp__fleet__submit_result` avec, comme résultat, l'objet JSON ci-dessus. Le champ
`decision` est **obligatoire** et doit être l'une des valeurs listées — sans lui, le système remonte
à un humain plutôt que de deviner.

Exemple minimal : `{"decision": "continue", "reason": "..."}`
