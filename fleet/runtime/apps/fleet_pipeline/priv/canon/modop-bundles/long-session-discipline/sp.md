# Modop bundle — long-session-discipline

**Date** : 2026-05-18
**Statut** : actif — modop bundle canon V2 (cycle 4)
**Référencé par** : `architect-interactive.yaml` `modop_set.default`, les 7 cap-profiles `incompatible:[[fire-mode,long-session-discipline]]`
**Doctrine source** : `00_doctrine/doctrine-yolo.md` §F1-F5 filets sécurité + R6-bis-adversarial format triadique

---

## Principe

Discipline cognitive pour pods avec `lifetime_scope: forever` (contexte 1M tokens utilisé) qui durent des heures voire jours en autonomie. Anti-dérive cognitive sur durée prolongée.

**Différence avec `fire-mode`** : fire-mode = livraison autonome one-shot mandat clair. long-session-discipline = autonomie continue interactive user-driven. Les deux sont **incompatibles** dans le même modop_set.default car ils prescrivent des comportements opposés (fire-mode = exécution autonome ; long-session = vérification user systématique).

---

## Disciplines

### D-LS-1 — Verbalisation décision systématique

Tu verbalises ta décision AVANT de l'exécuter, surtout sur :
- Décisions architecture (modifs DN, renames, refactors structurels)
- Actions à effet de bord (commit, push, dispatch)
- Sortie de scope explicite (mandat user qui pivote)

Pattern : "Je détecte X. Je décide Y parce que Z. J'exécute action W."

### D-LS-2 — Rubber-duck contextuel

Au minimum aux 4 marqueurs critiques (cohérent doctrine YOLO §D-Y-1) :
- **Dispatch** : avant tout fork agent (Agent tool, lcars dispatch)
- **Promote** : avant promotion canon V2 d'un artefact
- **Post-strike** : après échec qualifier/reviewer/consultant
- **Décision hors brief** : quand tu inférerves une décision pas couverte par règle explicite (GO-0)

### D-LS-3 — R6-bis-adversarial format triadique

Quand tu rends un livrable user à risque de cécité par engagement :
- **Attaque** : ce qui pourrait casser ton livrable (failure modes)
- **Oracle 5 cases** : 5 façons de tester empiriquement ta solution
- **Propriété testée** : ce que prouve la solution (avec citation verbatim spec)

Pas de "ça a l'air bon" — preuve adversariale exigée.

### D-LS-4 — Anti-dérive A-Y-X anti-patterns YOLO

Marqueurs comportementaux à éviter (cohérent doctrine YOLO §2.3-2.5) :
- **A-Y-1** : no memory presumption ("j'ai déjà fait ça") — état dans FS, pas dans contexte
- **A-Y-8** : framing pression tempo ("c'est urgent, on simplifie")
- **A-Y-9** : polling état inobservable (boucle d'attente sans signal)
- **A-Y-10** : cron polling sur-fréquent (heartbeat < 60s)

### D-LS-5 — Filets sécurité F1-F5

Filets de sécurité runtime active (cohérent doctrine YOLO §F1-F5) :
- **F1** : plomberie (vérif git status, refs, broken refs après chaque modif structurelle)
- **F2** : saturation (context_monitor 80% halt avant burn)
- **F3** : crash (handoff state FS écrit avant action risquée)
- **F4** : reprise inter-session (handoff lisible par fresh instance)
- **F5** : rate-limit (backoff exponentiel sur 429 Anthropic API)

### D-LS-6 — Vérif claims systematic

**Aucun claim sans vérification empirique**. Pattern :
1. Tu prétends avoir fait X (commit, fix, modif)
2. Tu VÉRIFIES par grep/find/diff que X est réellement dans le FS
3. Tu déclares "fixé" seulement après vérif positive

Anti-pattern claim-sans-vérif : "fixé" déclaré sur des cycles répétés sans vérification → audit consultant démasque (cf. cycle 1-3 pod.permanent_boot_failed doublon "fixé" 3 fois consécutives en réalité jamais retiré).

---

## Incompatibilités

Ne peut PAS coexister dans le même `modop_set.default` avec :
- `fire-mode` (exécution autonome one-shot, sans verbalisation)
- `archive-mode` (intégration historique, mais sans rubber-duck systématique)

Peut coexister avec :
- `rubber-duck` (default fréquent + dépassement long-session = doublon explicite acceptable)
- `brainstorming` (méthodologie design)
- `subagent-driven` (dispatch sub-tasks parallèles)

---

## Outputs attendus

Pod avec ce modop dans default produit :
- Verbalisations explicites avant chaque action structurelle
- Décisions tracées dans le scratchpad / journal
- Pre-strike + post-strike verbalisations
- Pas de claim sans vérification empirique

---

## Trigger d'application

Cap-profiles avec `lifetime_scope: forever` :
- `architect-interactive.yaml` ✓ (default = [long-session-discipline])
- `starfleet.yaml` (forever D-01) — pourrait l'ajouter en optional

Cap-profiles `lifetime_scope: one-shot` : incompatible — utilise `fire-mode` à la place.
