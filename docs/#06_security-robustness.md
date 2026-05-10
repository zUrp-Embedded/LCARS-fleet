# Sécurité et robustesse — modèle de menace et décisions

**Date** : 2026-03-03
**Dernière révision** : 2026-03-30
**Statut** : référence active
**Référencé par** : #00_index.md

> LCARS n'essaie pas de rendre les agents fiables par confiance. Il essaie de borner les dégâts, de rendre les erreurs visibles, et de déplacer la sûreté vers la mécanique quand c'est nécessaire.

---

## Modèle de menace

In scope :
- agent interne bogué ou confus
- erreurs de routage
- dérive silencieuse
- état partagé incohérent
- permissions ou chemins mal appliqués
- erreurs masquées ou fallbacks trop généreux

Hors scope :
- compromission hôte
- breakout VM / conteneur
- opérateur root malveillant

LCARS assume un modèle de boîte mono-confiance avec frontières mécaniques internes à tenir.

---

## Position défensive

Règles simples :
- préférer l'échec explicite au succès mensonger
- préférer la contrainte mécanique à la convention sociale
- préférer le redeploy au patch vivant
- préférer les artefacts lisibles aux états implicites

---

## Ce que la sécurité veut dire ici

La sécurité LCARS n'est pas principalement :
- du réseau
- du multi-tenant hostile
- de la crypto produit

Elle est principalement :
- de l'isolation de rôle
- de la tenue du runtime
- de la vérité système
- de la réduction des dérives silencieuses

---

## Frontières acceptées

Certaines hypothèses sont assumées :
- utilisateur unique
- environnement local contrôlé
- runtime jetable
- sécurité forte portée d'abord par la boîte, pas par la bonne volonté de l'agent

Ces hypothèses ne suppriment pas le besoin de rigueur. Elles bornent simplement le problème traité par LCARS.

---

## Règle de qualité

Une correction “robustesse” est bonne si elle fait au moins un de ces trois gains :
- réduit un mode de défaillance
- rend un échec plus visible
- diminue la dépendance à une discipline humaine

---

## Lire ensuite

- [#20_working-on-lcars.md](#20)
- [#25_release-process.md](#25)
