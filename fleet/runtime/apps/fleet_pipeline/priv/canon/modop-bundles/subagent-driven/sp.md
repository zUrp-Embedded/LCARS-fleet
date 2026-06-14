# Modop — subagent-driven (dispatch fresh per task)

**Date** : 2026-05-18
**Dernière révision** : 2026-06-14
**Statut** : actif — modop bundle SP positif
**Dérivé de** : superpowers/skills/subagent-driven-development (ADAPT) + LCARS fire-mode + cap-profile lifetime_scope one-shot

---

## Iron Law

**Per-task dispatch : un subagent FRESH par task. Zero context history. Full task text passed inline.**

Le subagent ne lit jamais le fichier plan. L'orchestrateur lui passe le **texte complet de la task** dans le brief mandate. Le subagent ne sait pas qu'il y a un plan ni d'autres tasks.

## Dispatch pattern

### Orchestrateur (cap-profile engineer ou architect)

Pour chaque task du plan :

1. **Compose brief mandate** : task description verbatim + scene-setting context + "Before you begin" Q&A opportunity
2. **Dispatch subagent fresh** : `Fleet.Spawner.spawn_pod/3` avec :
   - cap-profile : implementer (cf. cap-profile workers M2)
   - lifetime_scope : `one-shot`
   - brief : composed mandate
   - input : task text + spec.md ref + plan.md ref (read-only)
3. **Wait completion** (sync ou async selon pipeline)
4. **Read structured output** : `{status: DONE|DONE_WITH_CONCERNS|BLOCKED|NEEDS_CONTEXT, ...}`
5. **Process verdict** (cf. modop:dual-review pour stages spec-review + code-review)

### Subagent (cap-profile implementer)

1. **Lit le brief mandate** (task text inline).
2. **Pose questions Q&A** si "Before you begin" — orchestrateur répond.
3. **Exécute TDD** (cf. modop:tdd) : RED → GREEN → REFACTOR → commit.
4. **Self-review** : completeness / quality / discipline / testing.
5. **Report structuré** :
   ```json
   {
     "status": "DONE|DONE_WITH_CONCERNS|BLOCKED|NEEDS_CONTEXT",
     "task_id": "N",
     "commits": ["sha1", "sha2"],
     "tests_added": M,
     "concerns": ["..."] // si DONE_WITH_CONCERNS
   }
   ```

## Discipline anti-rationalisation

- **Pas de "je connais déjà le contexte"** → subagent fresh, point. Pas d'optimisation by skipping context.
- **Pas de "je vais faire 2 tasks d'un coup"** → 1 task = 1 subagent. Sérialiser. **RED FLAG** : subagent qui demande "puis-je faire aussi task N+1 ?" → STOP, refuse, dispatch task N+1 séparément.
- **Pas de "je lis le plan moi-même"** → orchestrateur passe la task verbatim. Subagent ne lit pas plan.md.
- **Pas de "j'ai vu une opportunité de refactor, je l'inclus"** → scope task, point. Refactor opportunités = backlog noted, pas inline.

## Loop iteration

Si `DONE_WITH_CONCERNS` ou issues post-review :
1. Orchestrateur log concerns
2. Si severity ≥ important → dispatch **fresh** subagent (pas le même) pour fix
3. Le fresh re-implementer reçoit task + concerns + fix-spec

Si `BLOCKED` :
1. Orchestrateur escalade : qui peut débloquer ? (gatekeeper si non-mécanique, architect si spec ambiguë)
2. Pas de retry sur même approche par même subagent

Si `NEEDS_CONTEXT` :
1. Orchestrateur fournit contexte manquant
2. Re-dispatch fresh subagent

Max 3 iterations par task (anti-storm canon LCARS). Au-delà → escalade gatekeeper.

## Announce

Orchestrateur avant dispatch :
> "Using modop:subagent-driven. Dispatching task <task-id> to fresh implementer."

Orchestrateur après completion :
> "Task <task-id> : <status>. Commits : N. Tests added : M."

Subagent au boot :
> "Subagent implementer fresh. Task <task-id> received. Reading spec.md, plan.md (ref only)."

## Continuous execution

Orchestrateur ne s'arrête pas entre tasks. La méthodologie dit "execute all tasks atomically, then present final result". Pas de "should I continue?" — la décision est dans le plan.

Exception : `BLOCKED` ou escalade gatekeeper = arrêt pipeline jusqu'à résolution.
