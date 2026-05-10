# Surfaces de vérité — LCARS actuel

**Date** : 2026-03-30
**Dernière révision** : 2026-03-30
**Statut** : référence extensive
**Référencé par** : canon/README.md
**Dérivé de** : design-history/#0_principes-fondateurs.md, design-history/#1_glossaire-systeme.md, design-history/raw/v5_audit-trail.md

> LCARS fonctionne seulement si chaque classe d'information a une surface de vérité identifiable. Dès qu'une même chose devient vraie à plusieurs endroits sans hiérarchie claire, le système redevient conversationnel.

---

## 1. Une vérité par classe d'information

La bonne question n'est pas seulement “où est l'info ?”.
La bonne question est :
- quel endroit fait foi
- pour quel type d'information
- à quelle durée

Pourquoi :
- plusieurs copies sans hiérarchie créent du non-déterminisme documentaire

---

## 2. Le repo distant reste la vérité durable principale

Pour tout ce qui doit survivre proprement :
- code
- doc canonique
- scripts
- configuration source
- règles

la vérité durable doit vivre dans le repo versionné.

Pourquoi :
- le runtime vivant peut être patché, observé, endommagé, puis détruit
- ce qui n'est pas revenu au repo reste une dette

---

## 3. Le runtime peut être vrai localement sans être vérité canonique

Un runtime expose des vérités locales utiles :
- état courant
- déploiement effectif
- handoffs
- hooks présents
- workers actifs

Mais ces vérités sont :
- locales
- opérationnelles
- potentiellement jetables

Pourquoi :
- LCARS doit savoir distinguer vérité de fonctionnement et vérité de référence

Important :
- la classe d'une surface peut changer
- un handoff hors repo reste une vérité locale
- un handoff migré dans un worktree versionné change de statut

Dans ce cas, la hiérarchie doit être redéclarée explicitement. Ce n'est pas la nature du fichier qui compte, c'est son régime de vérité réel.

---

## 4. La doc explicative n'est pas automatiquement vérité active

Une doc peut expliquer correctement un système sans être la couche qui le gouverne.

Donc il faut distinguer :
- directive active
- mécanisme runtime
- doc de cadrage
- archive historique

Pourquoi :
- une doc consultative qui commence à gouverner en silence devient une directive masquée

---

## 5. Une dérivation saine doit rester lisible

Quand une couche dérive d'une autre, la chaîne doit rester claire :
- source
- artefact dérivé
- runtime déployé
- état observé

Pourquoi :
- sans chaîne de dérivation lisible, on ne sait plus où corriger quand les couches divergent

---

## 6. Les conflits doivent être résolus par hiérarchie, pas par rhétorique

Quand deux surfaces se contredisent, la question n'est pas :
- laquelle paraît la plus plausible

La question est :
- laquelle est censée faire foi pour ce sujet précis

Pourquoi :
- sinon l'arbitrage dépend du contexte humain du moment

---

## 7. Les artefacts visibles comptent plus qu'une belle théorie

Dans LCARS, des fichiers modestes mais relisibles valent souvent mieux que :
- un récit élégant
- une mémoire de session flatteuse
- un état “évident” dans la tête d'un agent

Pourquoi :
- une vérité qu'on ne peut ni relire ni requalifier finit par dépendre d'une personne

---

## 8. Pourquoi cette couche existe encore

LCARS garde cette pensée parce que :
- le projet est récursif
- les couches dérivées existent vraiment
- les agents peuvent produire un discours plus cohérent que l'état réel

Donc la question “où est la vérité ici ?” reste une question de survie, pas de style.

---

## Lire ensuite

- [README.md](README.md)
- [#0_principes-structurants.md](#0_principes-structurants.md)
- [#2_conventions-systeme.md](#2_conventions-systeme.md)
- [../#01_architecture-lcars.md](../#01_architecture-lcars.md)
- [../design-history/raw/v5_audit-trail.md](../design-history/raw/v5_audit-trail.md)
