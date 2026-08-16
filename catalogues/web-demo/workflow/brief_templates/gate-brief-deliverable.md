<!-- Date: 2026-08-10 — Gabarit de brief. Remis TEL QUEL a l'agent. Jetons {{...}} remplis par le runtime.
     Celui-ci sert aux juges dont l'etape porte `judge_target: deliverable` — ils jugent ce qui a
     ete PRODUIT. Comparez-le avec gate-brief-brief.md : meme structure, autre objet. -->
# Relecture du livrable — décision

⚠ **Ton rôle est de JUGER, pas de produire.** Ne crée aucun fichier, ne commite rien. Le livrable
existe déjà, il est cité plus bas. Ta seule sortie est une **décision**, rendue par `submit_result`.

## Contexte
- Pipeline : {{pipeline}}
- Étape jugée : {{step}}
- Type de porte : {{gate_type}}
{{request_section}}
## La question

L'étape `{{step}}` a rendu son résultat. Au vu du livrable ci-dessous et des règles de la porte :
est-ce que ça passe (`continue`) — ou faut-il renvoyer, escalader, abandonner ?

Deux questions distinctes, dans cet ordre : **est-ce que ça fait ce qui était demandé**, puis
**est-ce que c'est tenable**. La première décide ; la seconde nuance.

## Le livrable à juger
```
{{subject_body}}
```

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
  `{"test_ajoute": "aucun", "regle": "couverture"}`
- `chain` — un tableau de **chaînes**, une étape de raisonnement par entrée. Un tableau d'objets est
  refusé. Exemple : `["le diff touche le formulaire", "aucun test sur le champ vide", "→ renvoi"]`

`decision` ∈ {{decisions}}

- `continue` — le livrable satisfait la porte
- `redirect` — renvoi au producteur, avec ce qu'il faut corriger
- `abandon` — le ticket n'est pas récupérable
- `escalate_user` — la question dépasse le cadre : un humain décide
- `halt_wait_input` — il manque une information, on s'arrête et on attend

## Comment tu rends

Appelle `mcp__fleet__submit_result` avec, comme résultat, l'objet JSON ci-dessus. Le champ
`decision` est **obligatoire** — sans lui, le système remonte à un humain plutôt que de deviner.

Exemple minimal : `{"decision": "continue", "reason": "..."}`
