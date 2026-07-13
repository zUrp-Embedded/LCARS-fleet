# Design History — genèse et distillation

**Date** : 2026-03-30
**Dernière révision** : 2026-03-30
**Statut** : index gelé — preuve et genèse
**Référencé par** : #00_index.md

> `design-history/` n'est pas de la doc opératoire. C'est une couche de preuve, de genèse et de distillation. Le but n'est pas de tout garder au même niveau, mais de séparer ce qui nourrit le diary, ce qui nourrit la base canonique extensive, et ce qui reste simple archive brute.

---

## Deux sorties cibles

### 1. Diary

Le `diary` garde :
- le récit chronologique
- les bifurcations
- les patch notes
- les choix structurants racontés comme événements

Pièce maîtresse :
- `docs/#6_diary/Captain_log.md`

### 2. Base canonique extensive

La base canonique extensive garde :
- les concepts encore vrais aujourd'hui
- les principes, rôles, conventions et workflows réécrits à l'état actuel
- le pourquoi du système actuel, pas l'historique détaillé de ses mutations

---

## Statut du dossier

Pour cette phase `v6-rc`, `design-history/` est considéré comme gelé :
- on ne s'en sert plus comme doc vivante
- on le conserve comme preuve, archive et matière de distillation
- les évolutions courantes partent désormais vers `docs/canon/` ou `docs/#6_diary/`

---

## Classification actuelle

### A. Noyau conceptuel à distiller

Ces fichiers contiennent du canon historique encore utile, mais ne doivent pas être repris tels quels comme vérité actuelle :

- `#0_principes-fondateurs.md`
- `#1_glossaire-systeme.md`
- `#2_roles-agents.md`
- `#3_system-conventions.md`
- `#6_claude-md-architecture.md`
- `#7_workflow.md`
- `#8_user-profile.md`

Traitement attendu :
- extraction du noyau encore valide
- réécriture en base canonique extensive
- conservation du matériau ancien comme preuve

Déjà largement distillés :
- `#0_principes-fondateurs.md`
- `#1_glossaire-systeme.md`
- `#2_roles-agents.md`
- `#3_system-conventions.md`
- `#6_claude-md-architecture.md`
- `#7_workflow.md`
- `#8_user-profile.md`

### A'. Pièce active recoupée par le runtime

- `#4_protocole.md`

Traitement attendu :
- conservation comme témoin historique majeur
- pas de promotion directe en canon `docs/canon/` tant que le chantier runtime/protocole v7 n'est pas ouvert
- usage principal : preuve de genèse, comparaison et archéologie

### B. Snapshot / transition

Ces fichiers décrivent un état intermédiaire ou une coupe versionnée :

- `snapshots/#5_protocole-EN.md`
- `snapshots/v3_claude-md-variants.md`

Traitement attendu :
- conservation comme snapshot
- pas de promotion directe en canon actuel

### C. Dépôt brut de consolidation

- `raw/v5_audit-trail.md`

Traitement attendu :
- archive de travail précieuse
- source de fouille
- pas un document à lire comme vérité synthétique

---

## Ce qui a déjà quitté ce dossier

Déplacé vers le `diary` :
- `docs/#6_diary/v5_notes.md`
- `docs/#6_diary/v5.2_changelog.md`

Raison :
- ces fichiers racontent des choix, transitions et décisions en séquence
- leur place naturelle est la couche narrative, pas la couche de canon ancien

Déjà distillé vers la base canonique extensive :
- `docs/canon/#0_principes-structurants.md`
- `docs/canon/#1_roles-et-frontieres.md`
- `docs/canon/#2_conventions-systeme.md`
- `docs/canon/#3_decision-et-derogation.md`
- `docs/canon/#4_architecture-des-directives.md`
- `docs/canon/#5_modele-utilisateur.md`
- `docs/canon/#6_glossaire-structurel.md`

---

## Règle de lecture

Quand un fichier mélange :
- vérité conceptuelle encore valide
- notes de contexte
- changelog
- exemples de transition

il doit être scindé mentalement avant toute réutilisation.

Le danger principal de `design-history/` est de confondre :
- un bon texte historique
- avec une bonne source de vérité actuelle

---

## Suite du chantier

1. inventorier le noyau encore valide de chaque pièce A
2. décider ce qui mérite une réécriture en base canonique extensive
3. laisser les snapshots et le brut comme couche de preuve
