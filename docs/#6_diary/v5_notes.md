# Notes v5 — principes fondateurs, conventions opérationnelles, décisions architecturales

**Date** : 2026-03-14
**Dernière révision** : 2026-03-14
**Statut** : companion narratif des fichiers canoniques v5
**Référencé par** : —

> Ce fichier documente le *pourquoi* derrière les règles ajoutées ou formalisées en v5.
> Il n'est pas injecté. Toute règle opérationnelle vit dans les fichiers canoniques.

---

## Principes fondateurs — genèse

### Volatilité

Origine : session v5 (2026-03-13). Observation répétée : les agents appliquent des hotfixes manuels (`git config --global` sur chaque user, symlinks ad-hoc) au lieu de commiter et reprovisionner. Le prochain reprovisioning écrase tout.

Analogie OS : git = disque, runtime = RAM, redeploy = reboot. MEMORY.md = RAM déguisée en disque (fausse persistance). La conversation n'est pas de la mémoire.

Conséquence architecturale : "tout est fichier" (Unix) → "tout ce qui doit vivre est un fichier" (LCARS) → "tout ce qui n'est pas versionné n'existe pas".

Fork obligatoire : l'user qui adopte LCARS le fork — son fork est sa fleet. Un repo read-only casse le cycle fix→push→deploy. Sans modifiabilité par la fleet, la boucle d'auto-amélioration est brisée.

### Non-recouvrement (règle d'or)

Origine : session v5 (2026-03-13). Constat : le LLM est un moteur probabiliste. Deux règles similaires ne s'annulent pas — elles produisent une moyenne imprévisible des distributions. Le résultat n'est ni l'une ni l'autre.

Implication directe : chaque fait en UN seul endroit. Pas "parce que c'est propre" — parce que c'est la seule façon d'obtenir un comportement déterministe avec un moteur probabiliste.

Critère de test : si deux fichiers disent la même chose avec des mots différents, l'agent produit un comportement statistiquement différent de ce que produirait l'une ou l'autre seule. C'est mesurable, pas esthétique.

### Déterminisme

Origine : session v5 (2026-03-13). Insight fondamental : LCARS n'est pas un système qui essaie de rendre un LLM déterministe — c'est un système déterministe dont le moteur est probabiliste.

Analogie : OS kernel (déterministe) autour de processus (non prédictibles). Les directives = syscall rules. Si un agent viole son scope 1/10 c'est un bug kernel, pas un comportement probabiliste acceptable.

Le contrôle est dans l'infrastructure, pas dans le modèle. LCARS impose le déterminisme sur les ACTIONS (scope, IPC, escalade), pas sur le CONTENU (raisonnement, code).

### MR = source de vérité

Origine : session v5 (2026-03-13). Décision : MR injecté, HR en découle. Écrire en MR puis annoter en HR = exact par construction. L'inverse (narratif → compression) perd de l'info à chaque passe.

MR en français : le budget token est négligeable sur 1M de contexte. FR calibré > EN approximatif. Testé en A/B (2026-03-14) : aucune différence de performance. Le FR reste le canon.

Poids sémantiques (INTERDIT, OBLIGATOIRE, JAMAIS, TOUJOURS) : c'est de l'ingénierie de prompt, pas du style. "INTERDIT" ≠ "il est préférable de ne pas".

---

## Conventions opérationnelles — contexte

### Édition de fichiers (Write/Edit/Read)

Pourquoi Read avant Write : Claude Code ne lit pas automatiquement le contenu d'un fichier avant de le réécrire. Sans Read préalable, l'agent écrase le contenu existant avec ce qu'il imagine. Observé plusieurs fois en v3 — fichiers vidés ou réécrits avec du contenu inventé.

Pourquoi re-Read `/home/commons/` : les fichiers IPC sont multi-writer. Un autre agent peut les modifier entre deux actions dans la même session. Le contenu en contexte est potentiellement stale.

Exception `.md` réécriture complète : si l'agent réécrit 100% du fichier, le contenu existant n'a pas besoin d'être en contexte — juste la confirmation que le fichier existe (pour ne pas créer un fichier fantôme).

### drvfs (9p) — bug Edit tool

Bug observé : l'Edit tool de Claude Code vide silencieusement les fichiers sur les montages drvfs (9p) — le filesystem Windows utilisé par WSL. Le fichier apparaît vide après un Edit, sans erreur. Workaround : copier dans /tmp/, éditer, copier avec dd.

Impacte `/home/ready-room/` (drvfs mount) et tout fichier sous `/mnt/c/` ou `/home/wsl-root/`.

### Règles Markdown (pas de preview, pas de full Read)

Pourquoi pas de content preview : l'agent avait tendance à afficher le contenu complet d'un .md avant et après chaque modification — 2× le fichier en tokens pour aucune valeur. L'éditeur de l'user a l'auto-refresh.

Pourquoi pas de full Read pour analyse : sur un .md de 400+ lignes, un Read complet consomme du contexte inutilement. `grep "^## "` + `wc -l` donne la structure en 2 commandes, puis Read ciblé sur la section pertinente.

### Shell — contraintes

Pas de masquage d'erreurs (`2>/dev/null`) : observé en v3 — les agents masquent les erreurs diagnostiques pour "nettoyer l'output". Les erreurs sont de l'information. Un agent qui masque une erreur masque un signal.

Pas de trial-and-error : observé en v3 — les agents retentent des commandes avec des flags différents sans lire l'erreur. Le pattern `command || command --flag || command --other-flag` est un anti-pattern.

Fix root cause : corollaire direct. Quand une commande échoue, lire l'erreur et fixer le problème sous-jacent. Pas contourner.

### Install / deploy — cycle de vie

Session v5 (2026-03-13) : refactor complet du provisioning. 5800 → 860 lignes. 7 scripts per-role × 2 plateformes → 1 script blueprint-driven.

Cycle idempotent : install = update = même opération. Inspiré de l'approche "cattle not pets" — le runtime est jetable, le repo est la vérité.

Séparation install/deploy : install prépare le système (une fois), deploy distribue le contenu (à chaque update). Deux responsabilités, deux moments, un seul pipeline.

Doctor = install --check : pas de script doctor séparé qui diverge de l'install. Même code, même inventaire de vérifications. `install.sh --check` = dry-run read-only.

Isolation YOLO : zero friction interne (agents root, pas de permissions entre eux), isolation absolue vs machine user. WSL = sandbox naturelle. Un agent compromis ne sort pas de la WSL.

### IPC spool-based

Remplacement des canaux v3 (to-*.md, fleet-inject.sh, fleet-notify.sh) par un spool filesystem classique. Un script unique `fleet-send.sh` remplace 8 scripts.

Réception : `/var/spool/fleet/inbox/<role>/`. Chaque rôle a son inbox. L'agent lit son inbox au démarrage et en continu.

### Output agent — format

Pourquoi lettres/chiffres : les items numérotés sont des adresses. L'user répond par référence ("ok pour 2/", "nope B/", "fais 1/ et 3/"). Un output non-numéroté force l'user à reformuler ou citer — friction pure.

Pourquoi lettres pour l'analyse, chiffres pour les actions : discrimination visuelle immédiate. "A/ Analyse" vs "1/ Faire" — l'user sait d'un coup d'œil s'il lit un constat ou une instruction.

### Bug journal

Convention : chaque repo avec `docs/` maintient `docs/#11_bug-journal.md`. Entrée obligatoire quand un bug est fixé, avant fin de session. Le numéro #11 suit GO-6 (position dans la hiérarchie conceptuelle du dossier docs/).

---

## Décisions architecturales v5

### Steward supprimé

Contexte : en v3, Steward était le sas de StarFleet (Tier 1 sas-os). Tout ce qui allait à StarFleet passait par Steward — filtre d'intégrité, validation avant exécution sudo.

Décision v5 : Steward était une couche en trop. Friction, token-cost, latence IPC. Si le système est solide (directives + redeploy instant), pas besoin de filtrer sudo. Le coût maximal d'une erreur = perte du travail non commité, au grand max une demi-journée.

Conséquence : StarFleet a le sudo direct. La séparation décision/exécution est perdue en tant que pattern structurel, mais le coût de la perte est acceptable vs le gain en simplicité.

Topologie résultante : Tier 0 = StarFleet + Architect. Tier 1 = Engineer (seul sas restant, côté user). Tier 2 = workers.

### Divisions (Command/Operations/Sciences) supprimées

Contexte : en v3, chaque agent avait un triplet (Tier, Division, Scope). Les divisions mappaient vers des accès L différents (Command→L3, Operations→L1 W, Sciences→L1 R).

Décision v5 : les divisions n'ajoutaient pas de discrimination utile. Le Tier détermine la persistance, le Scope détermine les autorisations — la Division était un axe redondant. Simplifié en Tier/Scope/Knowledge.

### First Contact Protocol décomposé

Contexte : en v3, "First Contact" mélangeait deux choses distinctes.

1/ **Onboarding** : script déroulé au premier lancement de StarFleet. Configuration post-install, vérifications, bienvenue. C'est de la plomberie, pas un protocole.

2/ **Project setup** : mise au carré d'un projet existant pour compatibilité fleet (conventions d'arbo, nommage, structure docs/work). Réduit l'aléatoire quand on injecte un projet. C'est une checklist, pas un "protocole".

Décision v5 : ne pas retenir "First Contact" comme Starfleet Principle. Encoder chaque aspect dans son lieu naturel — onboarding dans les scripts, project setup dans les conventions.

### Suffixe `-standard`

Convention : tout fichier suffixé `-standard` est un template non-personnalisé. Usage principal : protocole EN (`protocole-standard.md`) = version anglaise par défaut pour les forks non-francophones.

Le protocole est nécessairement dans la langue de l'user (c'est de l'opcode d'interaction). LCARS est packé avec un protocole EN-standard, mais le FR est câblé par défaut.
