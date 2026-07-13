# Workflow : Arch propose → User valide

**Date** : 2026-03-05
**Dernière révision** : 2026-03-12
**Statut** : référence active
**Référencé par** : —

---

## Contexte

Workflow naturellement émergent lors des phases de début de projet ou d'évolution architecturale.
Applicable quand la décision nécessite un contexte global que l'agent ne peut pas trancher seul.

---

## Séquence

```
1. TRIGGER
   Nouvelle fonctionnalité, décision d'archi, refactor significatif,
   ou question ouverte identifiée dans les handoffs / docs.

2. ARCH PARSE
   - Lire les docs existants (docs/, handoffs, notes)
   - Recherche externe si nécessaire (WebSearch / WebFetch sur sources primaires)
   - Identifier les options réalistes (2-3 max)
   - Évaluer trade-offs : complexité, réversibilité, dépendances

3. ARCH PROPOSE
   - Présenter les options sans menu à choix
   - Donner une recommandation claire avec justification
   - Identifier explicitement ce qui bloque sans décision user
   - Format : "Je recommande X parce que Y. Alternative Z si contrainte W."

4. USER VALIDE / BLOQUE / PRÉCISE
   - Valide : arch implémente directement
   - Bloque : arch documente le veto dans les handoffs et cherche alternative
   - Précise : arch intègre et re-propose si nécessaire (1 seul aller-retour max)

5. IMPLÉMENTATION
   - Arch commence immédiatement après validation
   - Documente la décision dans docs/ (raison du choix, alternatives rejetées)
   - Les décisions architecturales ne se re-ouvrent pas sans nouvelle information

6. DONE
   - Résultat dans les canaux normaux (handoffs, to-engineer.md DONE)
   - Pas de rapport de session sauf demande explicite
```

---

## Règles d'application

- **Pas de menu à choix** : arch présente une recommandation, pas une liste de cases à cocher. Si plusieurs options, la recommandation est explicite avec les alternatives en secondaire.
- **Un seul aller-retour** : si user précise, arch re-propose une fois. Pas de ping-pong.
- **Décision documentée** : toute décision validée atterrit dans `docs/` (pas juste dans la conversation).
- **Bloqueur explicite** : si rien ne peut avancer sans user, le dire clairement et s'arrêter — pas de contournement silencieux.

---

## Quand NE PAS utiliser ce workflow

- Tâches purement techniques sans ambiguïté architecturale : arch implémente directement.
- Bugs : diagnostic + fix direct, pas de proposition préalable sauf si la cause est ambiguë.
- Urgences CI (build cassé, deploy bloqué) : action immédiate, rapport après.

---

## Portée

Ce workflow est applicable par :
- **architect** en sessions interactives
- **engineer** en sessions autonomes
- **starfleet** quand il remonte une décision fleet-level à user via to-engineer.md

Skill associé : `/plan` — déclenche ce workflow formellement avec un plan structuré
dans `work/doing/<topic>.md` avant toute implémentation multi-fichiers.

---

## Notes — companion narratif

# Notes — #7_workflow-arch-propose-user-valide.md

**Date** : 2026-03-10
**Statut** : companion narratif du fichier canonique
**Fichier canonique** : `#7_workflow-arch-propose-user-valide.md` (seul fichier faisant foi)

> Ce fichier est une version narrative et explicative. Il n'est pas injecté, pas dérivé, pas normatif.
> Toute règle ou contrainte doit vivre dans le fichier canonique. Ce fichier documente le *pourquoi*,
> stocke le changelog, et capture les discussions de refonte.

---

## Changelog version canonique

| Date | Nature | Détail |
|------|--------|--------|
| 2026-03-05 | Création | Workflow TRIGGER→PARSE→PROPOSE→VALIDE→IMPLEMENT→DONE |
| 2026-03-08 | Révision | Header ajouté |
| 2026-03-10 | Audit v2 | Non propagé dans aucun MR, skill `/plan` existe mais pas référencé dans les directives |

---

## Notes d'analyse (session v2)

### Question ouverte : canonique ou obsolete ?

Ce workflow est un bon pattern mais il n'est encodé nulle part dans les directives injectées. Soit on le propage dans le MR (CLAUDE.md section Rules ou un fichier dédié), soit on le déclasse en annexe.

*(à compléter lors de la revue fichier par fichier)*

---

## Bug-fixes — 2026-03-12

### Path `docs/work/doing/` → `work/doing/`
Le skill `/plan` référençait `docs/work/doing/<topic>.md`. `work/` est peer de `docs/` (racine projet), pas enfant. Corrigé.
