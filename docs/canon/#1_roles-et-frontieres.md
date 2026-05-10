# Rôles et frontières — LCARS actuel

**Date** : 2026-03-30
**Dernière révision** : 2026-03-30
**Statut** : référence extensive
**Référencé par** : canon/README.md
**Dérivé de** : design-history/#1_glossaire-systeme.md, design-history/#2_roles-agents.md

> LCARS n'est pas une collection plate d'agents. C'est une topologie de rôles, de frontières et de cycles de vie. Cette structure compte plus que les noms eux-mêmes.

---

## 1. Trois couches de rôle

LCARS distingue trois niveaux :

| Niveau | Fonction |
|---|---|
| frontière | interface avec l'extérieur ou le système |
| sas | relais et filtre entre une frontière et le reste |
| worker | exécution spécialisée à l'intérieur |

Cette séparation existe pour empêcher le contact direct entre toutes les couches.

---

## 2. Tier et rôle ne sont pas synonymes

Le tier décrit surtout :
- le cycle de vie
- la permanence
- la place dans la topologie

Le rôle décrit :
- la fonction attendue
- le type de travail
- le périmètre général

Donc :
- un rôle n'est pas juste un nom d'agent
- il est une position dans une architecture de confiance

---

## 3. Les frontières comptent plus que les workers

Le cœur de LCARS n'est pas “avoir beaucoup d'agents”.

Le cœur est d'avoir des frontières nettes :
- frontière user
- frontière système
- relais internes qui évitent le contact direct avec tout

Pourquoi :
- si tout peut parler à tout, la topologie ne protège plus rien

---

## 4. Frontier

La *Frontier* désigne l'endroit où un agent travaille hors de son terrain habituel :
- nouveau projet
- nouveau domaine
- LCARS lui-même
- situation non couverte

Le danger n'est pas l'inconnu en soi.
Le danger est :
- l'adaptation silencieuse
- l'inférence non bornée
- la confusion entre règle active et improvisation locale

---

## 5. Instance et agent ne sont pas la même chose

LCARS distingue :
- l'agent comme moteur LLM
- l'instance comme enveloppe de travail

L'instance porte :
- identité
- home
- directives déployées
- mémoire de travail
- hooks
- état exposé

Donc le contrôle utile porte d'abord sur l'instance, pas sur une abstraction “agent” pure.

---

## 6. Ce que protège la topologie

La topologie doit protéger au minimum :
- les frontières de confiance
- la séparation entre usage et maintenance
- la lisibilité des chemins d'escalade
- la limitation des contacts directs inutiles

Si un rôle existe mais que sa frontière n'est pas réelle, alors ce n'est qu'un nom.

---

## 7. Pourquoi cette couche existe encore

LCARS garde cette pensée en rôles et frontières parce que :
- le moteur reste probabiliste
- le risque principal reste la dérive, pas seulement l'erreur locale
- la gouvernance passe d'abord par la structure de circulation

---

## Lire ensuite

- [#0_principes-structurants.md](#0_principes-structurants.md)
- [../#01_architecture-lcars.md](../#01_architecture-lcars.md)
- [../#16_ipc-topology.md](../#16_ipc-topology.md)
- [../design-history/#2_roles-agents.md](../design-history/#2_roles-agents.md)
