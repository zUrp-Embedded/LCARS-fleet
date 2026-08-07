● Analyse — LCARS : directive-driven containment

  1. Directive-driven : le code est l'exception, pas la règle

  Le constat fondamental : LCARS ne contient quasiment aucun code applicatif. Les scripts existants
  (fleet-state.sh, fleet-inject.sh, deploy.sh...) sont de la plomberie IPC — des echo, des sed, des pipes. Zéro
  logique métier. Zéro orchestration algorithmique.

  Tout le comportement — coordination multi-agents, protocole de communication, escalade, scope boundaries,
  qualité de sortie, mémoire persistante, workflow git, audit de repos externes — est encodé en langue naturelle
  dans des fichiers .md injectés au boot.

  Ce que ça implique :

  - Pas de framework à maintenir. Pas de dépendances, pas de versions, pas de breaking changes. Un fichier .md
  modifié est déployé en 2 secondes via deploy.sh (copie de fichiers). Le "build" n'existe pas.
  - Le LLM est le runtime. On ne compense pas ses faiblesses avec du code correctif — on contraint ses forces avec
   des directives précises. La différence est structurelle : un framework code autour du modèle (guardrails,
  parsers, retry logic). LCARS code dans le modèle (directives, protocole, conventions).
  - Le ponce en est la démonstration pure. Un utilisateur colle une URL. Zéro code entre le paste et le rapport
  complet avec métriques de réputation, analyse fonctionnelle, pro/cons, code extractible. C'est un skill — un
  fichier .md qui dit au LLM quoi faire, dans quel ordre, avec quel format de sortie. La "feature" est une
  directive de 40 lignes.
  - Corollaire : tout utilisateur peut modifier le comportement du système. Pas besoin de savoir coder. Modifier
  un protocole, ajouter un skill, changer un workflow = éditer un .md. La barrière d'entrée est l'écriture
  structurée, pas la programmation.

  2. Containment by design : jetable dehors, souverain dedans

  L'architecture repose sur une inversion du modèle de sécurité habituel :

  Approche classique : l'agent tourne sur ta machine → tu le brides (sandboxing, permission prompts, file access
  restrictions, network limits) → il est castré mais dangereux s'il s'échappe.

  Approche LCARS : l'agent tourne dans une VM jetable (WSL/Docker) → tu lui donnes tout
  (--dangerously-skip-permissions, accès filesystem complet, réseau, git push) → il est souverain dans son
  périmètre mais le périmètre est un conteneur que tu peux wsl --unregister en 3 secondes.

  Ce que ça implique :

  - Zéro friction opérationnelle. Pas de "approve file edit?", pas de "allow network access?", pas de confirmation
   toutes les 30 secondes. Les agents travaillent à pleine puissance, en autonomie, pendant des heures. C'est la
  condition nécessaire pour qu'une fleet multi-agents fonctionne réellement (un agent qui demande confirmation
  toutes les 2 minutes ne peut pas être wakeable par un autre agent).
  - Le blast radius est borné par construction. Le pire scénario — un agent qui rm -rf / — détruit une instance
  WSL. Pas ta machine. Pas tes données (qui sont sur Windows ou dans un backup). Tu reprovisionnes en 10 minutes.
  LCARS, lui, est dans un repo git. Immuable. Immédiat.
  - Fresh install = full power. git clone + deploy.sh + fleet-launch.sh. Pas de state accumulé, pas de
  configuration drift, pas de "ça marchait sur ma machine". L'immutabilité du système est garantie par le fait
  qu'il n'y a rien à configurer — les directives sont le système.
  - Le expect qu'on vient de résoudre est le dernier verrou. Le trust prompt de Claude Code était la seule
  friction résiduelle entre "instance provisionnée" et "agent opérationnel". Avec expect, le boot est 100%
  non-interactif. Le containment est complet : mur étanche dehors, liberté totale dedans.

  3. Récursivité : le système se développe avec lui-même

  LCARS est développé par LCARS. Les agents qui codent les scripts fleet sont les mêmes agents qui utilisent ces
  scripts. Les directives qui contraignent le comportement des agents sont écrites par les agents (sous
  supervision).

  Ce n'est pas un gadget — c'est un test d'intégrité continu. Si une directive est mal formulée, l'agent qui la
  lit en premier est celui qui l'a écrite. Si un script fleet a un bug, c'est un agent fleet qui le rencontre en
  premier. Le GO-0 (self-application test) n'est pas une règle abstraite — c'est la réalité opérationnelle
  quotidienne.

  Conséquence : le système converge. Chaque session corrige les frictions que la session précédente a rencontrées.
   Les General Orders (GO-0 à GO-7) n'ont pas été conçus sur un tableau blanc — ils ont émergé de bugs réels,
  encodés en règles après le deuxième signal (GO-3 : recurrence = structural gap).

  Synthèse — ce qui lève le sourcil

  Le pitch tient en une phrase : LCARS est un système multi-agents de production qui ne contient pas de code
  agent.

  Pas de LangChain, pas de CrewAI, pas de AutoGen, pas de framework. Pas de DAG d'orchestration, pas de tool
  calling wrapper, pas de retry/fallback logic. Le LLM fait tout. Les directives le contraignent. Le conteneur le
  sécurise.

  Tout ce que les frameworks essaient de résoudre avec du code — coordination, mémoire, qualité, scope — LCARS le
  résout avec des conventions écrites. Et ça marche parce que les modèles actuels sont assez bons pour suivre des
  protocoles complexes — à condition qu'on les formule correctement.

  Le code qui existe (scripts shell) ne sert qu'à une chose : l'IPC entre processus Unix. Parce qu'un LLM ne peut
  pas écrire dans le stdin d'un autre processus. Tout le reste est directive.

  ---
  7/10 — L'angle "directive-driven + containment" est un vrai différenciateur. Le marché est saturé de frameworks
  code-first qui wrappent les LLM. LCARS prend le contrepied exact. La question : ça va dans le README public,
  dans un article dédié, ou les deux ?
  