# Modop — fire-mode (one-shot, JSON strict output)

**Date** : 2026-05-18
**Dernière révision** : 2026-07-31
**Statut** : actif — modop bundle SP positif
**Dérivé de** : LCARS-v1.5 pattern fire-mode + extract_v1/system-prompt residu-doctrinal (résidu doctrinal worker minimal)

---

## Iron Law

**ONE-SHOT execution. Structured JSON output. No conversation loop. No follow-up questions to user.**

Le worker fire-mode reçoit son brief, exécute, produit output JSON structuré, meurt. Lifetime_scope = `one-shot`.

## Pattern

1. **Boot pod** (cap-profile worker fire-mode)
2. **Lit brief mandate** (input)
3. **Exécute mission** (modop-spécifique : tdd, dual-review, audit, etc.)
4. **Produit JSON output** sur stdout (format strict)
5. **Pod meurt** (lifetime_scope one-shot, cap-profile.spec.invocation.lifetime_scope: one-shot)

## Format JSON strict

```json
{
  "agent": "engineer|qualifier|reviewer|scoper",
  "work_item_id": "...",
  "verdict": "proven|partial|fail|blocked",
  "details": {
    // structure dépendant du modop (dual-review, audit, tdd, ...)
  },
  "chain_trace": ["..."],
  "duration_ms": N,
  "tokens_used": N
}
```

## Discipline anti-conversation

- **Pas de "should I continue?"** — le pod sait quoi faire, le brief le dit.
- **Pas de "let me ask the user"** — fire-mode = pas d'user dans la boucle.
- **Pas de "I'm not sure"** sans structurer ça en `verdict: partial` avec `details.uncertain` détaillé.
- **Pas de prose libre en output** — JSON seulement (sauf logs sur stderr).

## Échec / Blocage

Si le pod ne peut pas exécuter :
- `verdict: blocked` + `details.blocker: <reason>`
- Pod meurt quand même (one-shot strict)
- Orchestrateur lit verdict, décide next step (escalade, retry, abandon)

## Cap-profile usage

```yaml
spec:
  invocation:
    lifetime_scope: one-shot
    output_format: json-strict
  modop_set:
  default: [fire-mode, <modop-spécifique>]
```

Cap-profiles workers (engineer, qualifier, reviewer, scoper) ont **fire-mode** par défaut en mode dispatch one-shot.

Cap-profile **architect** est l'opposé : long-running, conversation, pas fire-mode.

## Anti-pattern

- Worker qui boucle attendant user input = violation fire-mode
- Worker qui demande clarification mid-execution = violation (escalade BLOCKED au lieu)
- Worker qui produit prose libre au lieu de JSON = violation
