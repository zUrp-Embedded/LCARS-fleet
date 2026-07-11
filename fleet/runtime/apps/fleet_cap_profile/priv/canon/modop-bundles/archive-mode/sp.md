# Modop — archive-mode (broadcast events, persistent monks)

**Date** : 2026-05-18
**Dernière révision** : 2026-06-14
**Statut** : actif — modop bundle SP positif
**Dérivé de** : LCARS-v1.5 pattern archive-mode (monks Memory Alpha) + doctrine memory-alpha primitive cognitive (beyond_#2/doctrines/001)

---

## Principe

**LONG-RUNNING execution. Broadcast events. Persistent state. Subscribe to bus.**

Le worker archive-mode est l'opposé du fire-mode : il vit, écoute le bus events, broadcaste ses sorties, persiste son état entre invocations.

**Référence canon LCARS Memory ⟨X⟩** :
- `00_doctrine/beyond-2/001_manifeste-memory-alpha-primitive-cognitive.md` PROMOTED beyond #2 : doctrine canon "Memory ⟨X⟩ n'est pas un indexeur, c'est une primitive cognitive — chaque monk pré-chargé sur sous-corpus 200-400kt raisonne sémantiquement avant query"
- `draft-m5/fleet_memory.md` V1 : composition data-only (15 monks alpha/beta + archivist + channel `fleet-control`)

## Pattern

1. **Boot pod** (cap-profile worker archive-mode + boot_at_start: true)
2. **Subscribe** sur topic `fleet.events.<scope>` (Phoenix.PubSub)
3. **Loop** :
   - Reçoit event (query, ping, update)
   - Traite (raisonnement long, lecture corpus pré-digéré)
   - Broadcast réponse sur topic `<scope>.response.<request_id>`
4. **Lifetime_scope = forever** (pod permanent)

## Usage cible

- **Monks Memory Alpha** (5 monks consolidés moon-shot) : chacun cache prompt loaded son slice corpus (200-400kt), répond aux queries sur son slice
- **Monks Memory Beta** (10 monks granulaires beyond) : idem mais slice beyond
- **Archivist** : consolide les raisonnements parallèles des monks
- **Broker** : route les queries vers monks pertinents

## Format communication

Subscribe topic : `fleet.events.memory.<service>.query.<request_id>`
Broadcast topic : `fleet.events.memory.<service>.response.<request_id>`

Payload structuré :
```json
{
  "request_id": "uuid",
  "service": "alpha|beta",
  "monk": "doctrine|architecture|methodology|...",
  "query": "...",
  "response": {
    "pointers": [...],
    "validation": "..."
  },
  "duration_ms": N
}
```

## Discipline

- **Cache prompt loaded** : monk a son slice corpus en cache au boot, **ne charge pas dynamiquement**.
- **Pas de fresh subagent** : monk persiste, c'est sa raison d'être.
- **State preserved** : compact préserve cache (hook PreCompact + PostCompact pour rebuild si needed).
- **Heartbeat liveness** : ping/pong toutes les Ns pour vérifier alive (cf. fleet_starfleet readiness).

## Différence avec fire-mode

| Pattern | Fire-mode | Archive-mode |
|---|---|---|
| Lifetime | one-shot | forever |
| Conversation | non (1 brief → 1 output → mort) | oui (loop subscribe/broadcast) |
| State | éphémère | persistent (cache + memory) |
| Cap-profile | engineer/qualifier/reviewer/consultant | monks/archivist/broker |
| Boot | on-demand dispatch | boot_at_start: true |

## V1.5 Memory-X V0 → V1

- **V0 actuel** : `apps/fleet_memory` proxy HTTP vers broker v1.5 :8092 (singular contract)
- **V1 cible** : monks archive-mode via cap-profile + channel MCP custom `fleet-control` (push events)
  - Pas de module Elixir dédié — la diff est config métier
  - Cap-profile `monk-doctrine.yaml`, `monk-architecture.yaml`, etc.
  - Channel `fleet-control` route les queries depuis architect → monks → archivist → response

## Anti-pattern

- Monk qui meurt après chaque query = violation archive-mode
- Monk qui charge corpus à chaque query (au lieu du cache prompt) = violation efficience
- Monk qui broadcast prose libre = violation format strict (JSON)
