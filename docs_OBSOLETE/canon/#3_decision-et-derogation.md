# Décision et dérogation — LCARS actuel

**Date** : 2026-03-30
**Dernière révision** : 2026-03-30
**Statut** : référence extensive
**Référencé par** : canon/README.md
**Dérivé de** : design-history/#7_workflow.md

> LCARS ne cherche pas à supprimer toute décision humaine. Il cherche à rendre explicites les endroits où la décision reste nécessaire, et à empêcher que l'exception devienne une voie normale de pilotage.

---

## 1. Tout ne doit pas être décidé par l'agent

Certaines décisions restent hors du périmètre d'un agent seul :
- bifurcation d'architecture
- changement de frontière
- modification des règles de gouvernance
- changement de topologie ou de release

Pourquoi :
- ces décisions engagent le système au-delà d'un ticket local

---

## 2. Le bon workflow n'est pas un menu

Quand une décision globale est requise, le rôle d'architecture doit :
- lire ce qui fait foi
- réduire l'espace des options
- recommander
- nommer explicitement le point bloquant

Pourquoi :
- LCARS préfère une recommandation justifiée à un faux libre-service d'options mal cadrées

---

## 3. Une validation ne doit pas se diluer

Une décision validée doit produire :
- une implémentation
- une trace documentaire
- une fermeture

Pourquoi :
- une décision “admise en conversation” mais non propagée dans les artefacts redevient de l'implicite

---

## 4. La dérogation n'est pas une faille honteuse

Une dérogation peut être saine si elle reste :
- explicite
- locale
- bornée
- réversible
- relisible

Pourquoi :
- un système réel rencontre des cas où la règle normale bloque une correction nécessaire
- le danger n'est pas l'exception en soi, mais l'exception sans forme

---

## 5. L'exception ne doit jamais devenir une seconde norme

Une dérogation mal fermée produit :
- une habitude implicite
- une frontière poreuse
- une dette de gouvernance

Donc une bonne dérogation précise toujours :
- l'objet
- le blocage normal
- le périmètre
- les mitigations
- la condition de fin

---

## 6. L'escalade saine est structurelle

Escalader n'est pas “forcer plus fort”.

Escalader signifie :
- déplacer le sujet vers le bon niveau de décision
- garder la frontière intacte
- obtenir un contrat plus explicite

Pourquoi :
- si l'escalade casse la hiérarchie des règles, elle ne protège plus rien

---

## 7. Pourquoi cette couche existe encore

LCARS garde cette discipline de décision parce que :
- les composants internes restent probabilistes
- les frontières restent plus importantes que le débit brut
- la maintenance future dépend de décisions qu'on peut relire

---

## Lire ensuite

- [README.md](README.md)
- [../#20_working-on-lcars.md](../#20_working-on-lcars.md)
- [../#25_release-process.md](../#25_release-process.md)
- [../design-history/#7_workflow.md](../design-history/#7_workflow.md)
