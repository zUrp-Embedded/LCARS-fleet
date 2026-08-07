# Glossaire structurel — LCARS actuel

**Date** : 2026-03-30
**Dernière révision** : 2026-03-30
**Statut** : référence extensive
**Référencé par** : canon/README.md
**Dérivé de** : design-history/#1_glossaire-systeme.md

> Ce glossaire ne cherche pas à tout réexpliquer. Il fixe les mots qui structurent encore LCARS aujourd'hui, avec leur sens opératoire réel.

---

## Frontier

Zone où LCARS travaille hors d'un terrain déjà balisé :
- nouveau projet
- nouveau domaine
- LCARS lui-même
- cas non couvert

La Frontier n'est pas un espace de liberté romantique.
C'est l'endroit où la dérive apparaît le plus vite.

---

## Instance

Enveloppe de travail complète d'un agent :
- identité
- home
- directives déployées
- outils
- mémoire de travail visible

LCARS contrôle d'abord des instances, pas des “agents purs”.

---

## Agent

Le moteur LLM lui-même.

Dans LCARS, l'agent seul n'est jamais la bonne unité de gouvernance.
La gouvernance utile passe par l'instance qui le porte.

---

## Worker

Rôle d'exécution spécialisé à l'intérieur de la boîte.

Un worker compte moins par son nom que par :
- sa frontière
- son périmètre
- sa place dans le cycle de travail

---

## Handoff

Artefact d'état visible d'une instance.

Il expose au minimum :
- ce qui est en cours
- ce qui a été fait
- ce qui bloque
- ce qui reste à reprendre

Le handoff sert à la reprise et à l'audit, pas au storytelling.

---

## Canal directionnel

Fichier adressé à une cible ou un rôle précis.

Il sert à :
- transmettre
- cadrer
- notifier

Il n'est pas un stockage généraliste.

---

## Queue

Artefact cumulatif de travail ou de signalement.

Une queue n'a pas la même sémantique qu'un canal directionnel :
- elle cumule
- elle se résout dans le temps
- elle ne suppose pas forcément un destinataire unique

---

## Source de vérité

Surface déclarative censée faire foi pour une classe d'information donnée.

LCARS cherche à réduire le nombre de vérités concurrentes.
Une vérité dupliquée ou contradictoire est une dette.

---

## Runtime

Instance déployée et vivante du système.

Le runtime est fait pour être utilisé, observé, détruit et reconstruit.
Il n'est pas la vérité durable.

---

## L0 à L4

Hiérarchie logique des couches de savoir.

Le détail exact évolue, mais l'idée reste :
- tout n'a pas la même portée
- tout n'a pas le même niveau de permanence
- la couche haute prime en cas de conflit

Pourquoi :
- sans hiérarchie de savoir, tout conflit redevient conversationnel

---

## Holodeck Containment

Nom de principe pour une idée simple :
- chaque instance doit opérer dans un périmètre borné et explicite

Le nom peut rester du folklore.
Le principe, lui, est structurel.

---

## Temporal Prime Directive

Nom de principe pour l'idée que le graphe d'historique publié ne se réécrit pas à la légère.

Le but n'est pas le rituel git.
Le but est d'éviter des états divergents entre humains, agents et runtime.

---

## Lire ensuite

- [README.md](README.md)
- [#1_roles-et-frontieres.md](#1_roles-et-frontieres.md)
- [#2_conventions-systeme.md](#2_conventions-systeme.md)
- [../design-history/#1_glossaire-systeme.md](../design-history/#1_glossaire-systeme.md)
