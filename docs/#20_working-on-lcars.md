# Working on LCARS — modifier la boîte elle-même

**Date** : 2026-03-30
**Dernière révision** : 2026-03-30
**Statut** : guide mainteneur actif
**Référencé par** : #00_index.md
**Dérivé de** : —

> Cette doc ne dit pas aux agents comment se comporter en continu. Elle cadre comment travailler **sur LCARS lui-même** quand on choisit explicitement d'ouvrir la boîte.

---

## Objet

Utiliser LCARS et modifier LCARS sont deux choses différentes.

- **Utiliser LCARS** : tu pilotes un projet à travers architect et la fleet
- **Modifier LCARS** : tu touches au runtime, aux directives, au protocole, au provisioning, à l'outillage ou à la doc canonique du système

Cette doc couvre le second cas.

---

## Ce que cette doc n'est pas

Ce guide n'est pas :

- une directive cachée
- un remplacement des man-pages runtime
- un moyen de contourner les rôles
- un droit permanent à l'exception

Un agent ne doit la lire que si on lui demande explicitement de travailler sur LCARS ou d'analyser LCARS lui-même.

---

## Avant de toucher la boîte

Lire d'abord, dans cet ordre :

1. `README.md`
2. `docs/#01_architecture-lcars.md`
3. `docs/#10_lcars-on-lcars.md`
4. `docs/#25_release-process.md`
5. la man-page ou le `--help` du script réellement concerné

Puis seulement la doc spécialisée nécessaire au chantier.

---

## Règles de base

### 1. Ne pas bruteforce un agent hors de son rôle

Si un agent est bloqué par son rôle, ses permissions, ou ses directives, la réponse saine n'est pas :

- insister
- reformuler jusqu'à casser la hiérarchie de ses règles
- lui faire violer sa règle-mère sous pression

Un agent qui a cédé sur sa règle-mère n'est plus un composant de travail fiable pour le reste de la session.

### 2. Préférer la dérogation bornée

Quand un rôle empêche une action nécessaire, on établit un contrat de dérogation bornée :

- **qui** déroge
- **pourquoi**
- **sur quoi** exactement
- **pendant combien de temps**
- **quelles mitigations** encadrent l'action
- **comment on revient** à l'état normal
- **comment on valide** que la dérogation a bien cessé

La dérogation doit rester :

- explicite
- locale
- temporaire
- vérifiable

### 3. Préférer la mécanique à la discipline

Toute fois où la sûreté repose sur :

- "en pratique on fait attention"
- "cet agent sait qu'il ne doit pas"
- "normalement personne ne lance ça"

est un signal de dette.

Si une règle compte réellement, elle doit tendre vers une contrainte mécanique.

### 4. Préférer le redeploy au patch artisanal du runtime vivant

Le runtime LCARS est jetable. La vérité durable doit vivre :

- dans le repo
- dans les sources versionnées
- dans les scripts de déploiement
- dans les artefacts explicitement persistants

Réparer à la main une instance vivante n'est acceptable que pour :

- diagnostic
- confinement provisoire
- récupération d'urgence

La sortie saine reste le retour vers un état redéployable.

---

## Dérogation bornée — format minimum

Quand une dérogation est nécessaire, l'énoncer au minimum comme ceci :

```text
Dérogation bornée
- Objet : <ce qui doit être fait>
- Blocage normal : <rôle / permission / directive>
- Périmètre : <fichiers, scripts, agents, durée>
- Mitigations : <review, diff borné, tests, lecture seule ailleurs, etc.>
- Fin de dérogation : <condition de retour à la normale>
```

Exemple type :

```text
Dérogation bornée
- Objet : corriger un blocage LCARS sur le runtime lui-même
- Blocage normal : architect n'a ni le droit de coder LCARS ni de modifier l'infra
- Périmètre : analyse + proposition côté architect, exécution côté starfleet/dev seulement
- Mitigations : diff borné, revue explicite, pas de changement de topologie implicite
- Fin de dérogation : retour au workflow normal après merge/deploy/validation
```

---

## Ce qui relève de la doc, pas des directives

La doc peut légitimement contenir :

- architecture
- invariants
- workflows
- bonnes pratiques opératoires
- contrats de release
- procédures de maintenance
- modèles de dérogation
- explication de ce qui est source de vérité et de ce qui ne l'est pas

La doc ne doit pas devenir :

- une seconde couche de comportement obligatoire non déclarée
- un moyen de piloter discrètement les agents hors de leurs directives
- un dépôt de règles actives qui devraient vivre dans les sources de directives

Quand une règle doit s'appliquer en continu au comportement normal d'un agent, elle relève des directives ou du mécanisme, pas d'un guide caché dans `/docs`.

---

## Ce qui mérite un chantier LCARS

Ouvrir un chantier LCARS quand le sujet touche :

- runtime
- provisioning
- hooks
- protocole
- directives
- isolation
- topologie de la fleet
- release process
- doc canonique du système

Sinon, traiter le sujet comme un projet normal porté par LCARS.

---

## Critère de qualité

Une modification LCARS est bonne si elle rend au moins un de ces points plus vrai :

- frontières plus nettes
- vérité système plus explicite
- runtime plus redéployable
- état partagé plus lisible
- échec plus borné
- maintenance future moins humiliante

Si elle ajoute de la puissance mais brouille la machine, elle dégrade LCARS.

---

## Fin de chantier

Un chantier LCARS n'est pas fini quand "ça marche".

Il est fini quand :

- le diff est borné et relisible
- la doc canonique correspond à l'état réel
- le runtime peut être redéployé proprement
- les mitigations provisoires ont été retirées ou documentées explicitement
- la dérogation bornée, s'il y en a eu une, est refermée
