---
name: onboarding
description: >
  Guide interactif d'accueil. Accompagne l'user de la découverte au premier projet livré.
  S'adapte au profil, au niveau, au type de projet.
allowed-tools:
  - Bash
  - Read
  - Write
when_to_use: >
  Use when the user is new to LCARS, asks how to start, says "onboarding", "getting started",
  "comment ca marche", "c'est quoi LCARS", "premier projet", or seems lost/confused about
  what to do. Also use when user explicitly invokes /onboarding.
---
# Skill: /onboarding

**Date** : 2026-03-23
**Dernière révision** : 2026-03-23
**Statut** : v6.0-RC
**Référencé par** : docs/#24_quick-start-projet.md
**Dérivé de** : —

Guide interactif d'accueil LCARS. Accompagne l'user du zéro au premier résultat concret.
S'adapte au profil, au niveau technique, au type de projet.

Doc de référence complémentaire : `docs/#24_quick-start-projet.md` (consultable à froid).

Distinction : `/onboard_v2` = onboarding système (install, credentials, GitHub). `/onboarding` = onboarding projet (premier projet, protocole, workflow).

---

## Principes

- **1 question à la fois** — jamais de batterie. Chaque réponse oriente la suite.
- **Exécuter, pas expliquer** — si l'user veut créer un projet, lancer `/new-project`, pas décrire la procédure.
- **Adapter la profondeur** — expert → aller vite, skip les bases. Débutant → ralentir, contextualiser.
- **Checkpoint naturels** — après chaque étape significative, confirmer avant de continuer.
- **Sortie libre** — l'user peut dire `stop` ou changer de sujet à tout moment. Le skill ne retient pas prisonnier.

---

## Step 1 — Prise de contact

Saluer brièvement. Présenter le modèle en 2 phrases max :

> Tu parles à architect — je planifie et je fais travailler une équipe d'agents. Tu gères le projet, pas l'équipe.

Puis évaluer la situation avec UNE question via AskUserQuestion :

> "On fait quoi ensemble ?"

Options :
- **J'ai un projet à lancer** → Step 2A
- **J'ai un repo existant à intégrer** → Step 2B
- **Je veux comprendre comment ça marche** → Step 2C
- **Je sais déjà, montre-moi les commandes** → Step 3 (shortcut)

---

## Step 2A — Nouveau projet

Lancer `/new-project`. Le skill new-project gère la collecte interactive.

Après la création, revenir ici pour Step 4 (premier cycle de travail).

**Success criteria** : repo créé, structure complète, README généré.

---

## Step 2B — Projet existant

Demander via AskUserQuestion :

> "Où est ton projet ?"

Options :
- **URL GitHub/GitLab** → on clone + `/adopt-project`
- **Déjà dans /home/projects/** → `/adopt-project` directement
- **Sur ma machine Windows** → expliquer : déposer dans `ready-room/inbox/` ou cloner depuis GitHub

Lancer `/adopt-project`. Après intégration, Step 4.

**Success criteria** : projet adopté, structure ajoutée, permissions OK.

---

## Step 2C — Exploration guidée

L'user veut comprendre avant de faire. Présenter les concepts par couches, en s'arrêtant à chaque couche pour vérifier l'intérêt.

**Couche 1 — Le modèle** (toujours) :
- Fleet = équipe d'agents spécialisés (dev code, qualifier teste, reviewer vérifie)
- Toi → architect → équipe → résultat
- Tout le travail passe par `work/` (plans, backlog, scratchpad)

Checkpoint : "On continue ou tu veux lancer un projet maintenant ?"
- Lancer un projet → Step 2A ou 2B
- Continuer → Couche 2

**Couche 2 — Le protocole** (si intéressé) :
- Les 5 mots-clés de base : `go`, `ok`, `nope`, `stop`, ESC
- Les mots-clés d'analyse : `évalue`, `analyse`, `review` → chacun finit par un score + routing
- Les mots-clés de mémoire : `TODO:`, `note bien:`, `side quest:`
- Référence complète : `docs/#09_protocole-cheatsheet.md`

Checkpoint : "Tu veux essayer sur un vrai projet ?"
- Oui → Step 2A ou 2B
- Pas encore → Couche 3

**Couche 3 — L'écosystème** (si curieux) :
- Ready-room : `inbox/` (toi → fleet), `outbox/` (fleet → toi), `fleet-live` (vue directe)
- Knowledge : L2 = savoir métier, L4 = règles fleet. Les agents se spécialisent via L2.
- Profils : `projects` (par défaut), `embedded` (hardware/firmware)
- Pointeurs : `docs/#01_architecture-lcars.md`, `docs/#02_knowledge-hierarchy.md`

**Success criteria** : l'user a compris ce dont il avait besoin, sans être noyé.

---

## Step 3 — Shortcut expert

L'user connaît déjà LCARS ou est impatient. Afficher le résumé opérationnel :

```
Commandes clés :
  /new-project          Créer un projet
  /adopt-project        Intégrer un repo existant
  /plan list            Voir les plans en cours
  /plan new <slug>      Créer un plan

Protocole express :
  go / ok / nope        Valider / rejeter
  évalue / analyse      Demander un avis
  review <fichier>      Review de code
  TODO: / note bien:    Capturer une idée

Accès fichiers :
  ready-room/inbox/     Déposer pour la fleet
  ready-room/outbox/    Récupérer de la fleet
  ready-room/fleet-live Vue directe /home/
```

Puis : "Tu veux lancer quelque chose ?" — et suivre.

**Success criteria** : l'user a les commandes, pas de friction.

---

## Step 4 — Premier cycle de travail

Le projet existe. Maintenant on fait quelque chose de concret dessus.

Demander via AskUserQuestion :

> "Qu'est-ce qu'on fait en premier sur ce projet ?"

Options :
- **L'user décrit une tâche** → planifier et exécuter normalement (sortir du skill, mode travail normal)
- **Pas d'idée** → proposer une tâche de démo adaptée au projet :
  - Projet code → "on ajoute un README complet + un premier test"
  - Projet firmware → "on vérifie le build et on documente les pins"
  - Projet script → "on ajoute un --help et un .gitignore propre"

Exécuter la tâche via le flux normal (plan → dispatch → résultat).

**Success criteria** : l'user a vu un cycle complet : demande → plan → exécution → résultat.

---

## Step 5 — Clôture

Après le premier cycle réussi :

1. Résumer ce qui a été fait (1-2 lignes)
2. Pointer les prochaines étapes naturelles :
   - "Tu peux continuer à travailler normalement — plus besoin du guide"
   - "Pour le protocole complet : `docs/#09_protocole-cheatsheet.md`"
   - "Pour la gestion du travail : `docs/#17_work-lifecycle.md`"
   - "Si ça coince : `fleet-doctor.sh` ou dis-moi"
3. Confirmer que l'user est autonome

**Success criteria** : l'user sait qu'il peut continuer seul et où trouver de l'aide.
