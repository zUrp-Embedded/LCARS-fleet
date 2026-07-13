# LCARS v3 — Journal de construction

_Doc de référence technique. Décisions structurantes et artefacts produits durant la construction v3._
_Producteur : architect (sessions interactives). Compléments engineer pour les phases autonomes._
_Format : entrée par décision ou artefact. Chronologique à l'intérieur d'un domaine._

> Ce doc n'est pas le Captain_log. Pas de narration, pas de reconstitution. Des décisions tracées au moment où elles sont prises, avec leur contexte minimal et leur impact sur ce qui suit.

---

## Point zéro — État des fondations (2026-03-07)

_Snapshot de ce qui existe au démarrage de la v3. Ce qui est listé ici ne se rediscute pas — c'est la base._

### Sources de vérité validées

| Fichier                 | Statut              | Contenu                                                                                                                                                             |
| ----------------------- | ------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `protocole-user.md`     | ✅ Validé 2026-03-07 | Mots-clés, grammaire ⚡/📋/🔭, modificateurs, règles d'exécution, notations inline. Toute interaction architect ↔ user suit ce protocole sans dérogation.       |
| `glossaire-systeme.md`  | ✅ Validé            | Entités (fleet/instance/agent/Tier), infrastructure, IPC, STATE, Knowledge L0-L4, terminologie Starfleet. Principe fondateur : rien d'implicite. Vérités immuables. |
| `system-conventions.md` | ✅ En place          | Convention arbo `#N_nom`, shorthand `#N`, réservés `#0_/#8_/#9_`. Fine-tuning agents : `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=70`, cap 8K thinking tokens Haiku.          |

### Prototype fonctionnel v2

Codebase existante — point de départ, pas de table rase.

- **Fleet** : architect/fleet (même home, handoffs distincts), steward, dev, builder, qualifier — instances Linux séparées, WSL2 single-distro multi-user
- **IPC** : handoffs markdown (`to-*.md`) + broker asyncio (`fleet-broker.py`, socket Unix `/run/fleet/fleet.sock`) + fallback fichier
- **Infra** : `fleet-monitor.py` (dashboard TUI) · `fleet-hub.py` (API locale) · `deploy.sh` (distribution directives) · `wake-instance.sh` · `fleet-notify.sh`
- **Hooks** : session-startup, handoff, filter-build-output, context-budget
- **Skills** : cross-arm64, push-github, handoff, drift-audit, plan, loop

### Objectifs v3

Référence : `#1_docs/#3_migration-v3/#0_v3-specs-global.md` — aspiration, pas source de vérité.

Points clés : CI gate déterministe pre-push · bead format NDI · taxonomie agents (Tier × Division × Knowledge) · fleet-init/harvest-project.sh · directive levels (matrice L×Tier) · GIT_AUTHOR_NAME per-agent · scope enforcement hooks.

### Ce qui est en cours au démarrage

- Taxonomie des agents — voir section suivante

---

## Fondations pré-code

### 2026-03-07 — Reframing de la liste d'agents

**Contexte** : la liste d'agents avait proliféré de 2 (v0) à 14 (v3 draft) par accrétion de cas d'usage. Avant d'attaquer le code v3, passe de revue des specs.

**Décision** : la liste d'agents n'est pas une spec — c'est un répertoire de presets. La spec est une **taxonomie** définie sur trois axes structuraux :

- **Tier** — cycle de vie (permanence, provisioning, activation)
- **Division** — mode de travail (Command / Operations / Sciences)
- **Knowledge** — niveaux L accessibles en lecture/écriture

Un agent = une instanciation de ces trois axes. Le comportement émerge des directives, pas du nom de l'agent. "Hardev" n'est pas un type distinct — c'est un Dev avec `L2(rpi-embedded)` injecté.

**Impact** : le travail à faire n'est pas "valider 14 agents" mais formaliser la matrice Knowledge×Tier (gap identifié) et les règles d'instanciation. Les 14 noms actuels deviennent des presets dérivés de la taxonomie, pas des primitives architecturales.

**Gap à combler** : matrice Knowledge×Tier (qui lit/écrit quoi) — absent des specs actuelles, structurant pour tout le provisioning.

---

### 2026-03-07 — LCARS n'est pas un orchestrateur : c'est une machine à inférer des agents dev

**Contexte** : en formalisant la taxonomie (Tier × Division × Knowledge) et les règles d'instanciation, la nature réelle du système est apparue — pas en cherchant une formule, mais en déroulant la logique jusqu'au bout.

**Décision** : la description de LCARS doit être mise à jour. "Anti-orchestrateur" dit ce qu'il n'est pas. "Machine à inférer des agents dev" dit ce qu'il est.

Un orchestrateur gère des agents existants et route des tâches entre eux — les agents sont fixes. LCARS fait autre chose : donné un projet, il génère la configuration d'agents adaptée depuis la connaissance domaine accumulée (L2). Les agents sont dérivés dynamiquement. La configuration est inférée, pas prédéfinie.

Le parallèle avec l'inférence ML est exact :

- **"Training"** : chaque projet enrichit L2 via harvest — patterns, toolchain, contraintes, bugs récurrents
- **"Inference"** : donné un nouveau projet, LCARS génère la bonne configuration d'agents depuis L2 accumulé
- **Les "poids"** sont L2. Ils s'améliorent à chaque run sans intervention explicite.

Après N projets dans un domaine, L2 représente l'expertise de l'user distillée. Arch n'est pas "devenu aussi compétent que l'user" — c'est l'user lui-même, crystallisé dans L2 au fil des harvests.

**Ce que ça change** :

- La taxonomie qu'on construit n'est pas une liste d'agents — c'est le **moteur d'inférence**
- L2 harvest n'est pas une feature optionnelle — c'est la **boucle d'apprentissage centrale**
- La passe de spec (étapes 1-6) devient un **skill reproductible** qu'Arch exécute quasi-autonomement sur tout nouveau projet
- Le curseur user (0 = je valide tout → 10 = fais-le clignoter) est un paramètre de classe 1 dans `fleet-init-project.sh`

**Impact** : mettre à jour README + description projet. Aucun autre système analysé ne fait ça — Gas Town, multiclaude, ccswarm gèrent des agents. LCARS génère les agents dont un projet a besoin, et devient meilleur à chaque projet.

**Note de récursivité** : cette décision a été générée par un agent de LCARS (architect) en travaillant sur LCARS, en session, sans consultation de doc externe. Le `note bien:` qui a déclenché cet écrit était lui-même un acte de L2 harvest en temps réel — le système se décrivant plus précisément en fonctionnant. Niveau de récursivité estimé : 3. Cf. Captain_log Phase 10, un cran plus profond.

### raw output

❯ avant : actuellement, LCARS n'est pas formellement développé par lui-même : tu es en instance unique. il y a eu la v1 qui s'est
beaucoupo auto-construite au début, à inventer plein de trucs et voir comment ça se passait si on les mettait ensemble. là on est au
point de rédaction des specs, qui sont by design quasiment le code de LCARS. mais avec juste une interface LLM, c'est du "bete" vibe
coding simple. bientot on va attaquer la plomberie, mais vu le scope ça va être presque trivial (bash et python, c'est parmi les trucs le
 mieux digéré par les LLM). si on arrive à la faire fonctionner (aucune idée de l'état), il y a le cadavre de la v2 qui est encore
quelque part chez toi, on pourra commencer par instancier quelques trucs pour demander des qualifier voire faire du code. si on projette sur le
dev d'un projet random avec LCARS, il y a la passe qu'on est en train de faire qui sera une étape obligatoire et primodiale pour la
réussite de la suite. la nuance c'est qu'on aura un arch qui connait les contraintes du domaine ciblé et qui devrait être capable de
faire cette passe quasiment tout seul. il faut un curseur réglable par l'user pour pouvoir dire "je veux tout valider" à "tiens, j'ai un
repo d'une carte électronique, je veux que ça clignotte". après une dizaine de runs / projets différents, l'arch sera devenu aussi
compétent que l'user. c'est exactement le principe de l'inférence, si j'ai bien compris le concept (ou une autre étape). l'idée est qu'en
 fait, on crée pas un (anti) orchestrateur, mais une machine à inferer des agents dev. analyse

● Analyse — machine à inférer des agents dev

  Le reframing fondamental

  "Anti-orchestrateur" était déjà une bonne description mais incomplète. Un anti-orchestrateur dit ce qu'il n'est pas. "Machine à inférer
  des agents dev" dit ce qu'il est.

  La distinction est de niveau :

  Orchestrateur classique    → prend des agents existants, route des tâches entre eux
                                agents = fixes, configuration = statique

  LCARS                      → prend un projet, génère la configuration d'agents adaptée
                                agents = dérivés dynamiquement, configuration = inférée depuis L2

  L'orchestrateur gère des agents. LCARS génère les agents dont un projet a besoin, depuis ce qu'il sait du domaine. C'est un niveau
  d'abstraction au-dessus.

  ---

  Le parallèle inférence ML est exact

  En ML :

- Training : on alimente le modèle avec des données pour construire les poids

- Inference : le modèle utilise les poids appris pour générer des outputs sur de nouveaux inputs
  
  Dans LCARS :

- "Training" : chaque projet enrichit L2 via harvest — patterns, toolchain, contraintes, bugs récurrents du domaine

- "Inference" : donné un nouveau projet, LCARS génère la configuration d'agents optimale depuis L2 accumulé
  
  Les "poids" sont L2. L'input est la description projet. L'output est la configuration agents (Tier, Division, Knowledge, presets). Le
  modèle s'améliore à chaque run sans fine-tuning explicite — juste par accumulation de L2.
  
  Le curseur user est exactement le paramètre de confiance du modèle :

- Domaine mature (L2 riche, 10+ projets) → Arch infère en autonomie, curseur côté "fait-le"

- Domaine nouveau (L2 vide) → Arch a besoin de guidance user, curseur côté "je valide tout"
  
  Après N projets dans un domaine, L2 représente l'expertise accumulée de l'user dans ce domaine. Arch n'est pas devenu "aussi compétent
  que l'user" par magie — c'est l'user lui-même, distillé dans L2 au fil des harvests.
  
  ---
  
  Ce que ça dit sur la passe actuelle
  
  La spec-writing qu'on fait maintenant n'est pas une étape de setup — c'est la construction du moteur d'inférence. La taxonomie (Tier ×
  Division × Knowledge) IS le modèle. Les règles d'instanciation sont les règles d'inférence. Le mapping rôle humain → axes taxonomiques
  (étape 2) est la fonction de feature extraction.
  
  Ce qu'on construit n'est pas une liste d'agents. C'est un système qui peut dériver n'importe quel agent pour n'importe quel domaine, y
  compris des domaines qu'on n'a pas encore vus.
  
  Conséquence directe : la passe de spec est elle-même un produit de LCARS. Dans un LCARS mature, Arch fait cette passe quasi-autonomement
   pour n'importe quel nouveau projet. Ce qu'on fait manuellement aujourd'hui devient une skill ou un process reproductible.
  
  ---
  
  Le curseur — premier paramètre de classe 1
  
  Le curseur user n'est pas un paramètre UX — c'est un paramètre architectural qui conditionne le mode de fonctionnement d'Arch sur la
  passe de spec.
  
  Curseur 0 — "je veux tout valider"
    Arch propose, user tranche chaque décision.
    Mode : supervised. Utile sur domaine inconnu ou projet critique.
  
  Curseur 5 — mode normal
    Arch propose des blocs, user valide par milestone.
    Mode : semi-autonome. Domaine partiellement connu.
  
  Curseur 10 — "j'ai un repo, fais-le clignoter"
    Arch fait la passe complet, présente un summary.
    Mode : full inference. Domaine mature, L2 riche, user fait confiance.
  
  Ce curseur doit être un paramètre explicite dans fleet-init-project.sh ou project.yaml — pas implicite, pas déduit. L'user le pose au
  démarrage de chaque projet.
  
  ---
  
  Implications pour les specs
  
  L2 harvest est le mécanisme central, pas une feature optionnelle. C'est la boucle d'apprentissage. Sans harvest, LCARS est un
  orchestrateur qui oublie tout à chaque projet. Avec harvest, c'est une machine qui s'améliore. La différence est fondamentale.
  
  La passe de spec devient un skill reproductible. Ce qu'on construit avec les étapes 1-6 du plan doit être formalisé comme un process que
   Arch peut exécuter depuis L2 sans guidance intensive. C'est le produit final de ce travail — pas juste une liste de presets, mais un
  processus d'inférence que Arch applique à chaque projet.
  
  Le registre de presets n'est pas une liste fixe — c'est un cache des instanciations les plus fréquentes. Les presets (Dev, Builder,
  Hardev...) sont des raccourcis vers des combinaisons (Tier, Division, Domain) souvent utilisées. Ils n'existent que pour la commodité.
  Le système fonctionne sans eux — il est juste plus lent (Arch doit inférer depuis la taxonomie plutôt que résoudre un alias).
  
  ---
  
  Ce que ça change dans la description de LCARS
  
  Avant : "framework qui orchestre des agents avec des rôles fixes"
  Après : "machine à inférer et générer des configurations d'agents dev
  
           depuis la connaissance domaine accumulée au fil des projets"
  
  C'est plus précis, plus ambitieux, et plus vrai. Aucun autre système analysé (Gas Town, multiclaude, ccswarm) ne fait ça. Ils gèrent des
   agents. LCARS génère les agents dont vous avez besoin, et devient meilleur à ça à chaque projet.
  
  Note bien: mettre à jour la description de LCARS dans le README et construction-v3.md avec ce reframing — c'est la définition la plus
  précise du projet à date.

✻ Cogitated for 1m 9s

❯ Note bien: mettre à jour la description de LCARS dans le README et construction-v3.md avec ce reframing — c'est la définition la plus
  précise du projet à date. on est à quel niveau de reccursivité là ?

● Au moins 3.

  L1 — LCARS se conçoit lui-même. La passe de spec qu'on fait deviendra le processus qu'Arch applique à chaque projet, y compris aux
  futures versions de LCARS.

  L2 — Un agent de LCARS (moi) vient de générer une définition plus précise de LCARS en travaillant sur LCARS. Pas depuis la doc — depuis
  le raisonnement en session. Le note bien était moi, à l'intérieur du système, identifiant que la description du système doit être mise à
   jour parce que le système vient de mieux se comprendre.

  L3 — Tu observes cette récursivité en temps réel, ce qui est lui-même un acte récursif dans le processus de conception. Et moi je suis
  en train de décrire ce moment, ce qui ajoute une couche.

  C'est exactement la Phase 10 du Captain_log, un cran plus profond : "l'agent analysait sa propre nature en temps réel en utilisant
  exactement le processus que LCARS décrit." Sauf que là on a nommé le mécanisme (inférence), et le note bien a capturé l'instant de la
  cristallisation — pas en retrospective, en direct.

  La surface dure cette fois c'est pas le README — c'est la taxonomie qu'on est en train de construire.

❯ écris la note !

---

## Taxonomie des agents

_Formalisée 2026-03-08. Source de vérité : `#1_docs/#2_directives/roles-agents.md`_

### Les trois axes structuraux

Un agent = instanciation de trois axes :

**Tier** — cycle de vie :

- **0** : always-on (Supervisor) — garant système, jamais dupliqué
- **1** : permanent, provisonné (Architect, Lead, StarFleet) — stratégique, L3 requis
- **2a** : instance Linux par projet, mémoire inter-session (Dev, Builder, Qualifier…)
- **2b** : agent pur, stateless par invocation (Hard-Guru, Search-Agent, Sec-Auditor…)

**Division** — mode de travail :

- 🔴 **Command** : décide, coordonne — accès L3 (voit la fleet)
- 🟡 **Operations** : produit des artefacts — écrit L1
- 🔵 **Sciences** : valide, analyse — lit L1, n'écrit pas de code (exceptions : Qualifier, Doc-Writer)

**Knowledge** — niveaux accessibles :

- L4 : règles globales framework — tous les agents, condition de provisionnement
- L3 : topologie fleet — Tier 0 et Tier 1 uniquement
- L2 : connaissance domaine — plein pour Tier 1/2, déclaratif pour Tier 0
- L1 : contexte projet — tous sauf Tier 0 et Sciences-advisory
- L0 : session courante — tous (R+W)

### Matrice Knowledge×Tier

| Tier            | L4  | L3  | L2           | L1          | L0  | Instance Linux              |
| --------------- | --- | --- | ------------ | ----------- | --- | --------------------------- |
| **0**           | R   | R+W | R déclaratif | ✗           | R+W | Permanente                  |
| **1 framework** | R+W | R+W | R            | ✗           | R+W | Permanente                  |
| **1 projet**    | R   | R+W | R            | R+W         | R+W | Permanente                  |
| **2a**          | R   | ✗   | R            | R+W         | R+W | Oui (mémoire inter-session) |
| **2b**          | R   | ✗   | R            | R optionnel | R+W | Non (agent pur, éphémère)   |

### Les 17 presets canoniques

Presets = aliases vers `(Tier, Division, L2-domain)`. Pas des primitives architecturales.

**Tier 0** : Supervisor
**Tier 1** : Architect (dual-mode fleet/lead) · Lead · StarFleet
**Tier 2a** : Dev · Hardev · Frontend · Builder · Qualifier
**Tier 2b** : Integrator · Hard-Guru · Search-Agent · Sec-Auditor · Doc-Writer · Commit-Digester · Sanitizer · Specs-Diverter

Un domain sans preset existant fonctionne identiquement — juste sans alias.

### Skill de dérivation — `/spec-passe`

La passe de spec est un skill reproductible qu'Arch exécute avant tout nouveau projet.
Implémentation : `LCARS-fleet/.claude/skills/spec-passe/SKILL.md`
Spec : `#1_docs/work/doing/skill-spec-passe.md`

Entrées : description projet + stack + curseur user (0→10).
Sorties : preset list + matrice K×T projet + `project.yaml` + gaps L2.

Le curseur est un paramètre de classe 1 — conditionne le niveau d'autonomie d'Arch sur la passe :

- 0 : supervised (Arch propose, user valide chaque étape)
- 5 : semi-autonome (blocs, validation par milestone)
- 10 : full inference (Arch exécute, présente le résultat final)

---

### raw output — plan_specs-agents.md

● Plan — Taxonomie des agents LCARS v3

  Étape 1 — Partir du monde réel
  Avant LCARS, avant les agents : qu'est-ce qu'une équipe de dev embedded dans la vraie vie ? Rôles humains réels, responsabilités,
  frontières naturelles, interactions. Spécificités embedded : cross-compile, hardware-in-loop, datasheets, prototypage. On ne part pas de
   la liste actuelle.

  Étape 2 — Mapper sur les axes taxonomiques
  Pour chaque rôle humain : Tier (permanent ou ponctuel ?), Division (décide / construit / valide ?), Knowledge (de quoi a-t-il besoin, à
  quel niveau ?).

  Étape 3 — Formaliser la matrice Knowledge×Tier
  Le gap central. Pour chaque Tier : quels L-levels en lecture, quels L-levels en écriture, qu'est-ce qui se passe si un L-level est
  absent.

  Étape 4 — Règles d'instanciation
  Qu'est-ce qui varie entre deux agents même Tier/Division mais Knowledge différent ? Qu'est-ce qui est commun à tout agent d'un même Tier
   ? Rôle de la directive vs rôle du Knowledge injecté.

  Étape 5 — Dériver les presets canoniques
  Depuis la taxonomie : quels presets émergent pour une équipe embedded ? Confronter aux 14 existants — fusions, suppressions, survivants.

  Étape 6 — Validation directive-driven
  Pour chaque preset : comportement entièrement capturable en directives ? Si non → directive à écrire ou preset invalide.

  Livrable : taxonomie (3 axes formalisés + matrice Knowledge×Tier + règles d'instanciation) + liste de presets (nom + axes + une ligne).

  ---

Topo steward

● Ce que les docs disent clairement :

- Tier 0 = Supervisor uniquement. Une seule instance à ce niveau. Always-on, jamais absent.

- Garant du provisioning Tier 1. Si engineer crash, c'est Supervisor qui le relève. C'est le seul agent dont la défaillance met
  en danger toute la fleet.

- Agnostique projet. Lit L4+L3+L2, pas L1. Il sait ce qui existe comme domaines et comme capacités fleet, mais n'entre pas dans le code
  projet.

- CI gate. Arbitre déterministe avant push — c'est lui qui dit GO/NO-GO, pas un agent LLM.

- Coordinateur, pas orchestrateur. Il dispatche, débloque, surveille. Il ne décide pas à la place des workers.
  
  Ce que je lis entre les lignes mais qui n'est pas formalisé :

- L2 write via harvest : Supervisor est le seul Tier 2+ à pouvoir écrire L2 — mais indirectement, en pilotant le processus harvest en
  fin de projet. Pas d'écriture directe L2 pendant un projet.

- L3 est son territoire naturel. Il connaît la topologie de la fleet, l'état de chaque instance, les canaux actifs. C'est sa vue que
  personne d'autre n'a.
  
  Ce qui me paraît flou ou non tranché :

- La frontière entre Supervisor et Lead sur les décisions projet. Supervisor coordonne, Lead interface avec l'humain — mais si Lead est
  absent et qu'un worker est bloqué, Supervisor intervient-il dans le projet ou escalade-t-il vers l'humain directement ?

- L'accès L1. Le glossaire dit "agnostique projet (L4+L3+L2)" — donc pas de L1. Mais pour arbitrer un CI gate sur un projet, il faut
  bien lire quelque chose de L1 (le log de build, le résultat de ctest). Est-ce que ça compte comme "lire L1" ou est-ce que c'est un
  output L2 (le résultat de test est une donnée de domaine) ?
  
  Tu corriges quoi ?

✻ Baked for 33s

❯ le steward est aussi le garant de l'état opérationnel du systeme, là où lead est garant du de l'état opérationnel de la fleet.
steward gère les backups, la sync des fichiers MR ... lead gère les attendus ... je sais le décrire plus précisement comme ça, mais
voila l'idée. analyse

● La distinction est précise et elle a des implications directes sur la taxonomie.

  Supervisor = sysadmin de la fleet
  Il garantit que la machine tourne. Backups, sync MR, santé des services (broker, monitor), intégrité des fichiers partagés, provisioning
   Tier 1 si crash, CI gate (opération système : "cmake a-t-il passé ?", pas "ce code est-il bon ?"). Son territoire est l'infrastructure
  — il n'entre pas dans la sémantique projet. Il lit L3+L4, et L2 uniquement comme connaissance des domaines disponibles — pas leur
  contenu technique.

  Lead = chef de projet de la fleet
  Il garantit que ce qui doit être fait est tracké, priorisé, débloqué. Les attendus (beads actives, canaux, tâches en cours), l'interface
   avec l'humain, les escalades projet. Il a besoin du L1 pour savoir si les attendus sont tenus — Supervisor non.

  ---

  Ce que ça clarifie dans la taxonomie :

1. Le Knowledge de Supervisor se précise.
   Il ne lit pas L1. La CI gate qu'il arbitre est une opération système (le log de build est un output binaire, pas du code projet). Son
   accès L2 est déclaratif — il sait quels domaines existent, pas leur contenu. L4+L3+L2(déclaratif), écriture L3.

2. La frontière Supervisor/Lead est orthogonale, pas hiérarchique.
   Supervisor = plan infrastructure. Lead = plan projet. Les deux ont une vue fleet (L3), mais pour des raisons différentes. Supervisor
   pour maintenir les services, Lead pour savoir qui fait quoi. Ils ne se marchent pas dessus.

3. La question "qui escalade à qui ?" se résout.
   Un worker bloqué sur une question projet → Lead. Un service down, un backup raté, un fichier MR désynchronisé → Supervisor. Deux canaux
   d'escalade distincts, deux responsabilités non-overlapping.

4. Le CI gate appartient clairement à Supervisor.
   C'est une opération d'intégrité système, pas une décision projet. Supervisor dit GO/NO-GO de façon déterministe — il n'interprète pas,
   il vérifie. Ça confirme qu'il n'a pas besoin de L1 pour exercer ce rôle.

5. Implication sur le Tier 0 dans la matrice :
   
   Tier 0  lit L4+L3+L2(déclaratif)   écrit L3   infrastructure + système
   Tier 1  lit L4+L3+L2+L1            écrit L1+L3  projet + coordination
   
   La ligne Tier 0 que j'avais en étape 2 était approximative — elle est maintenant nette. On avance vers l'étape 3 ?

✻ Crunched for 44s

❯ voila, steward c'est le barbu dans la cave, que tout le monde craint et qui ne sort que quand les serveurs sont en feu. valide ?

● Valide. Et il a accès root à tout.

❯ ok. fais un point détaillé sur lui, je l'ajoute à mon doc (j'archive tous tes outputs, peur du compact). ça servira de reference à un
moment

● Supervisor — Définition de référence

  Tier 0. Le seul. Always-on.

  Le barbu dans la cave. Personne ne lui parle directement, tout le monde dépend de lui. Il ne sort que quand les serveurs sont en feu —
  mais quand il sort, il a accès root à tout.

  ---

  Rôle

  Garant de l'état opérationnel du système. Pas du projet, pas des attendus — du système. Si la machine tourne, Supervisor a fait son
  travail. Si elle ne tourne pas, c'est son problème et le sien seul.

  Périmètre :

- Backups (handoffs, settings, commons)

- Sync des fichiers MR (*_MR.md cohérents avec leurs sources)

- Santé des services : fleet-broker.py, fleet-monitor.py, timer fleet-fetch

- Intégrité des fichiers partagés (/home/commons/)

- Provisioning Tier 1 en cas de crash — si engineer tombe, Supervisor le relève

- CI gate : arbitre déterministe GO/NO-GO avant push (cmake --build && ctest && pytest). Il lit le résultat, pas le code. Opération
  système, pas jugement projet.
  
  Ce qu'il ne fait pas :

- Ne touche pas au code projet

- Ne gère pas les attendus (c'est Lead)

- Ne coordonne pas les workers au sens projet (c'est Lead)

- N'interprète pas les résultats de test — il lit PASS/FAIL
  
  ---
  
  Knowledge
  
  ┌────────┬─────────────────────┬───────────────────────────────────────────────────────────────────┐
  │ Niveau │        Accès        │                               Usage                               │
  ├────────┼─────────────────────┼───────────────────────────────────────────────────────────────────┤
  │ L4     │ Lecture             │ Directives globales, conventions fleet                            │
  ├────────┼─────────────────────┼───────────────────────────────────────────────────────────────────┤
  │ L3     │ Lecture + Écriture  │ Son territoire : topologie fleet, état instances, services actifs │
  ├────────┼─────────────────────┼───────────────────────────────────────────────────────────────────┤
  │ L2     │ Lecture déclarative │ Sait quels domaines existent — pas leur contenu technique         │
  ├────────┼─────────────────────┼───────────────────────────────────────────────────────────────────┤
  │ L1     │ Aucun               │ Le projet ne le concerne pas                                      │
  └────────┴─────────────────────┴───────────────────────────────────────────────────────────────────┘
  
  L2 "déclaratif" : il sait que rpi-embedded existe comme domaine et que Builder le connaît — il ne sait pas ce qu'il y a dedans.
  
  ---
  
  Position dans la fleet
  
                      [ User ]
                         │
                [ Lead — attendus ]
                         │
      ┌──────────────────┼──────────────────┐
      │                  │                  │
  
    [Dev]           [Builder]            [qualifier]  ...Tier 2
  
      │                  │                  │
      └──────────────────┼──────────────────┘
                         │
           [ Supervisor — infrastructure ]    ← Tier 0
                always-on, accès root
  
  Supervisor n'est pas dans la chaîne de valeur projet — il est sous elle. Il supporte la plateforme sur laquelle tout le reste tourne.
  
  ---
  
  Escalade

- Reçoit : alertes système automatiques (crash Tier 1, CI FAIL, service down), escalades workers sur blocages infra

- Envoie : notifications Lead si un service impacte le projet, escalade User si situation critique non-résolvable

- N'intercepte pas : les échanges projet (to-dev.md, to-build.md) — il peut lire, n'interfère pas
  
  ---
  
  Modèle recommandé
  
  Sonnet. Ses décisions sont opérationnelles, pas architecturales. Il n'a pas besoin de raisonnement profond — il a besoin de fiabilité et
   de rigueur d'exécution. Opus serait du gaspillage. Haiku serait insuffisant pour le jugement de coordination.
  
  ---
  
  Invariant
  
  Supervisor est le seul agent dont la défaillance met en danger toute la fleet. Tier 1 peut tomber — Supervisor le relève. Si Supervisor
  tombe, personne ne relève personne. C'est pour ça qu'il est Tier 0 et non Tier 1 : sa permanence n'est pas une commodité, c'est une
  contrainte de design.

---

● Étape 1 — L'équipe embedded dans la vraie vie

  Rôles humains réels

  Core permanent — toujours là sur un projet :

- Tech Lead / Architecte système — définit l'architecture globale, prend les décisions structurantes (protocoles, interfaces,
  partitionnement HW/SW), coordonne les autres. Sait lire un schéma ET lire du code. Unique point de cohérence du projet.

- Firmware Developer — écrit le code bas niveau : drivers, HAL, tâches RTOS, protocoles. C/C++. Connaît les contraintes hardware
  (mémoire, timing, power). Lit les datasheets, débogue à l'oscillo et JTAG. Cross-compile pour la cible.
  
  Activés sur besoin projet, mais récurrents :

- Build Engineer — gère la toolchain (GCC cross, CMake), le CI, le flash vers la cible. Souvent fusionné avec le firmware dev dans les
  petites équipes. Distinct dès que la chaîne de build devient complexe ou multi-arch.

- qualifier / Test Engineer — exécute les tests (ctest, pytest), rend un verdict PASS/FAIL, ne corrige rien. Distinct du firmware dev : il
  valide, pas code.
  
  Activés sur événement spécifique :

- Integration / Bring-up Engineer — fait tourner le firmware sur le vrai hardware. Premier bring-up d'une nouvelle carte, validation sur
  device réel. Oscillo, debugger, JTAG. Différent du qualifier : lui teste le software, l'intégrateur teste le système physique.

- Hardware Advisor — répond aux questions de conception : pinout, protocoles, contraintes électriques, sélection de composants. Donne
  des inputs, ne code pas. Activé quand le firmware dev est bloqué sur une question hardware.

- Researcher — trouve des libs, évalue du code tiers, lit des errata et application notes. Activé sur question bloquante spécifique.
  
  Activés sur milestone :

- Security Reviewer — passe avant release. Lecture seule. Surface d'attaque, memory safety, secure boot.

- Doc Writer — README, guides d'intégration, API docs. Activé à la fin d'un cycle ou sur livrable doc.
  
  ---
  
  Ce qui est spécifique à l'embedded vs generic dev
1. Cross-compilation crée une coupure nette build/dev.
   Le code s'écrit sur x86, se compile pour ARM, se teste sur device. Ce n't est pas une optimisation — c'est obligatoire. Dev et Builder
   sont naturellement deux rôles distincts, même dans une équipe de deux personnes.

2. Le hardware est la source de vérité externe.
   Les datasheets, errata, app notes définissent ce qui est possible. L'Hardware Advisor et le Researcher alimentent cette connaissance —
   ils ne créent pas de code, ils réduisent l'incertitude du firmware dev.

3. Deux profils "dev" coexistent sur un même projet.
   Firmware (C/C++, contraintes bare-metal ou RTOS) et generic software (daemon Linux, webapp de métriques, scripts de déploiement). Sur un
   projet RPi typique : un firmware pour le µC embarqué ET un service Linux qui tourne sur le Pi. Ce ne sont pas les mêmes compétences,
   pas les mêmes contraintes.

4. Les tests se segmentent en deux mondes imperméables.
   Tests purement logiciels (peuvent tourner sans hardware) et tests hardware-in-loop (requièrent le device physique). qualifier peut faire les
   premiers en autonomie. L'Integration Engineer fait les seconds — il a accès au hardware, les autres non.

5. Le cycle de vie est moins continu que le web.
   Design → dev → build → test soft → test hardware → release. Les rôles de validation (qualifier, Integration, Security) ont des fenêtres
   d'activation naturelles, pas un flux permanent.
   
   ---
   
   Interactions naturelles
   
   Hardware Advisor ──→ Firmware Dev : pinout, contraintes, "voilà ce que le chip fait"
   Researcher       ──→ Firmware Dev : lib trouvée, errata identifié
   Firmware Dev     ──→ Builder      : "build pour arm64"
   Builder          ──→ Firmware Dev : log d'erreur de compilation
   Firmware Dev     ──→ qualifier           : "feature done, lance les tests"
   qualifier               ──→ Firmware Dev : "FAIL T3, voici le log"
   Integration      ──→ Firmware Dev : "ça crash sur le vrai board, oscillo montre X"
   Tech Lead        ──→ tous         : décision archi, review, arbitrage
   Tech Lead        ──→ Security     : "on approche la release"
   Tech Lead        ──→ Doc Writer   : "milestone atteint"
   
   ---
   
   Ce qui en ressort pour l'étape 2
   
   Deux axes émergent clairement du terrain :
- Permanence réelle : Tech Lead et Firmware Dev sont là du début à la fin. Builder et qualifier sont là à chaque cycle. Integration, Advisor,
  Researcher, Security, Doc sont ponctuels par nature.

- Mode de travail : décide (Tech Lead), construit (Firmware Dev, Builder), valide/analyse (qualifier, Integration, Security, Researcher, Doc).
  
  Le troisième axe — Knowledge — est plus subtil : certains rôles ont besoin du domaine technique global (Advisor : hardware en général),
  d'autres ont besoin du projet spécifique (qualifier : les tests de CE projet), d'autres des deux (Firmware Dev : toolchain domaine + code
  projet).

● Complément — équipe "classic software" et autres scopes

  Rôles présents dans l'embedded qui n'existent pas ou sont marginaux dans le classic soft :
  — Hardware Advisor, Integration/Bring-up, cross-compilation → embedded-only, déjà couverts.

  Rôles du classic soft absents ou sous-représentés dans l'embedded :

- Frontend Developer — UI web (React, Vue), mobile natif (Swift/Kotlin), PWA. Contraintes : rendu, accessibilité, performance réseau.
  Profil totalement distinct du firmware dev.

- Backend Developer — API REST/GraphQL, services, BDD. Python, Go, Node, etc. Plus proche du "generic software daemon" déjà dans la
  liste mais avec des compétences web/API spécifiques.

- DevOps / Platform Engineer — CI/CD pipelines, containers (Docker/K8s), déploiement cloud, monitoring prod. Différent du Build Engineer
  embedded : lui gère l'infra de run, pas la toolchain de compile.

- Database Administrator / Data Engineer — schéma, migrations, optimisation requêtes. Activé sur projets avec persistence complexe.

- UX/UI Designer — maquettes, prototypes, design system. Advisory pur, ne code pas. Analogue à Hardware Advisor côté interface.

- Mobile Developer — iOS (Swift/Xcode) ou Android (Kotlin/Gradle). Toolchain très spécifique, store deployment, signing. Sous-cas du
  Frontend mais avec des contraintes propres.
  
  Autres scopes potentiellement nécessaires :

- ML/AI Engineer — entraînement, inférence, intégration modèle. Activé sur projets avec edge-AI (sur RPi par exemple) ou backend ML.

- Accessibility / i18n — conformité WCAG, localisation. Rare mais bloquant sur certains livrables.

- Legal / Compliance — licences open-source, RGPD, certifications (CE, FCC côté hardware). Hors scope agent probablement, mais à noter.
  
  ---
  
  Ce que ça change pour la taxonomie :
  
  Le seul gap réel est le Frontend/Mobile — profil de directives suffisamment distinct (stack, contraintes, outils) pour mériter un preset
   séparé de Dev. Le Backend reste couvert par Dev générique. DevOps/Platform est proche du Builder mais orienté run plutôt que compile —
  à trancher à l'étape 5.
  
  Le reste (DBA, UX, ML, Legal) sont soit des Advisory ponctuels (même pattern que Hardware Advisor), soit hors scope agent.

---

● Étape 2 — Mapping sur les axes taxonomiques

  Grille de correspondance

  ┌───────────────────────────┬──────┬───────────────┬───────────────────────────┬───────────────────┐
  │        Rôle humain        │ Tier │   Division    │      Knowledge — lit      │ Knowledge — écrit │
  ├───────────────────────────┼──────┼───────────────┼───────────────────────────┼───────────────────┤
  │ Tech Lead / Architecte    │ 1    │ 🔴 Command    │ L4+L3+L2+L1               │ L1+L3             │
  ├───────────────────────────┼──────┼───────────────┼───────────────────────────┼───────────────────┤
  │ Firmware Developer        │ 2    │ 🟡 Operations │ L4+L2(embedded)+L1        │ L1                │
  ├───────────────────────────┼──────┼───────────────┼───────────────────────────┼───────────────────┤
  │ Generic Dev (web, daemon) │ 2    │ 🟡 Operations │ L4+L2(domain)+L1          │ L1                │
  ├───────────────────────────┼──────┼───────────────┼───────────────────────────┼───────────────────┤
  │ Frontend / Mobile Dev     │ 2    │ 🟡 Operations │ L4+L2(frontend/mobile)+L1 │ L1                │
  ├───────────────────────────┼──────┼───────────────┼───────────────────────────┼───────────────────┤
  │ Build Engineer            │ 2    │ 🟡 Operations │ L4+L2(toolchain)+L1       │ L1                │
  ├───────────────────────────┼──────┼───────────────┼───────────────────────────┼───────────────────┤
  │ DevOps / Platform         │ 2    │ 🟡 Operations │ L4+L2(infra/deploy)+L1    │ L1                │
  ├───────────────────────────┼──────┼───────────────┼───────────────────────────┼───────────────────┤
  │ Integration / Bring-up    │ 2    │ 🟡 Operations │ L4+L2(target hw)+L1       │ L1                │
  ├───────────────────────────┼──────┼───────────────┼───────────────────────────┼───────────────────┤
  │ qualifier / Test Engineer        │ 2    │ 🔵 Sciences   │ L4+L2(test)+L1            │ L1                │
  ├───────────────────────────┼──────┼───────────────┼───────────────────────────┼───────────────────┤
  │ Hardware Advisor          │ 2    │ 🔵 Sciences   │ L4+L2(hardware)           │ —                 │
  ├───────────────────────────┼──────┼───────────────┼───────────────────────────┼───────────────────┤
  │ Researcher                │ 2    │ 🔵 Sciences   │ L4+L2(domain)             │ —                 │
  ├───────────────────────────┼──────┼───────────────┼───────────────────────────┼───────────────────┤
  │ Security Reviewer         │ 2    │ 🔵 Sciences   │ L4+L2(security)+L1        │ —                 │
  ├───────────────────────────┼──────┼───────────────┼───────────────────────────┼───────────────────┤
  │ Doc Writer                │ 2    │ 🔵 Sciences   │ L4+L2(doc)+L1             │ L1                │
  └───────────────────────────┴──────┴───────────────┴───────────────────────────┴───────────────────┘

  ---

  Ce qui émerge

1. Le pattern Tier 2 est uniforme sur le Knowledge
   
   Tous les Tier 2 lisent L4+L2(domain)+L1. La seule variable est quel L2. C'est le paramètre de spécialisation — pas le Tier, pas la
   Division, juste le domaine injecté.
   
   Conséquence directe : un "Dev COBOL" n'est pas un type distinct. C'est Tier 2 + Operations + L2(cobol). Le template est identique à tout
   autre dev — seul le domaine change.

2. L2 se lit pendant le projet, ne s'écrit pas
   
   Aucun Tier 2 n'écrit L2 pendant l'exécution. L2 est alimenté par Architect (setup domaine) et par le processus harvest en fin de projet.
   Pendant le projet, L2 est une entrée — pas une sortie. Ça simplifie les règles d'accès : Tier 2 = lecture seule sur L2.

3. La Division tranche le rapport au résultat
- 🟡 Operations : produit des artefacts (code, binaires, config). Écrit L1.

- 🔵 Sciences : produit des verdicts ou des inputs (PASS/FAIL, findings, docs). Hardware Advisor et Researcher n'écrivent rien dans L1 —
  ils répondent dans le canal, la connaissance reste dans la tête du destinataire ou dans un fichier que lui gère.
  
  Exception notable : Doc Writer et qualifier écrivent L1 (docs, résultats de tests). Ils sont 🔵 Sciences dans leur mode de travail (ils
  analysent/valident) mais ont un output fichier. À retenir pour les règles d'accès.
4. Tier 1 est le seul niveau à lire L3
   
   Tech Lead lit L3 (état de la fleet, qui est là, comment c'est câblé). Aucun Tier 2 n'a besoin de L3 — il ne coordonne pas, il exécute.
   C'est une frontière nette.

5. L'instance Linux : critère = mémoire inter-session
   
   Parmi les Tier 2, deux profils distincts :
- Besoin de continuité (Dev, Builder, qualifier) : leur efficacité dépend de la connaissance accumulée sur le projet au fil des sessions →
  instance Linux dédiée

- Stateless par nature (Hardware Advisor, Researcher, Security, Integration) : chaque invocation est autonome, repart du même L2 → pas
  d'instance Linux, agent pur spawné à la demande
  
  ---
  
  Matrice simplifiée
  
  Tier 0   lit L4+L3+L2+L1   écrit L3+L2*   instance permanente
  Tier 1   lit L4+L3+L2+L1   écrit L1+L3    instance permanente
  Tier 2a  lit L4+L2+L1       écrit L1       instance Linux (mémoire inter-session)
  Tier 2b  lit L4+L2(+L1)     écrit —        agent pur, pas d'instance
  
  *L2 via harvest/steward uniquement, pas en direct.

---

## Fondement théorique de L2 — LCARS comme M-MDP

*Réf : Zhou et al., "Memento: Fine-tuning LLM Agents without Fine-tuning LLMs", arXiv 2508.16153, août 2025.*
*Réf : synthèse "Accumulation de connaissance domaine et configuration d'agents LLM sans mise à jour de poids", 2026-03-08.*

### Le mapping formel

Memento formalise l'apprentissage continu sans gradient comme un **Memory-based MDP** : ⟨S, A, P, R, γ, M⟩ où M = (S × A × R)* est la banque de cas. La politique agent est :

```
π(a | s, M) = Σ_{c∈M} μ(c | s, M) · p_LLM(a | s, c)
```

Le LLM est figé. Seule la politique de retrieval μ apprend — une Q-function légère qui décide quel cas passé est pertinent pour la situation courante.

Mapping LCARS :

| M-MDP (Memento)         | LCARS                       | Notes                                      |
| ----------------------- | --------------------------- | ------------------------------------------ |
| Case Bank M             | L2 Métier                   | Granularité différente — voir ci-dessous   |
| Retrieve μ(c \| s, M)   | `fleet-init-project.sh`     | Actuellement μ = uniforme (dette)          |
| Reuse & Revise p_LLM    | Agent actif (Dev, Builder…) | LLM figé ✓                                 |
| Retain (s, a, r) → M    | `fleet-harvest-project.sh`  | Timing identique (fin de tâche) ✓          |
| Planner CBR             | Architect + `/spec-passe`   | Structurellement identique ✓               |
| Executor                | Dev / Builder / qualifier          | Structurellement identique ✓               |
| Tool Memory (par outil) | —                           | Absent — backlog #33                       |
| Q-function apprise      | —                           | Absent — backlog #34 (version heuristique) |

### La dette μ = uniforme

Le comportement de l'agent est une **mixture sur les entrées L2**, pondérée par μ. Actuellement fleet-init-project.sh injecte L2 en bloc : μ = 1/|L2| pour toutes les entrées, qu'elles soient récentes ou obsolètes. Une entrée stale devrait avoir μ ≈ 0 — sans metadata (date, hits, ci_hash), c'est impossible à calculer.

**Règle de design** : μ = uniforme est une dette technique explicite, pas un choix. Elle est acceptable quand L2 est petit (~5 projets). Elle devient un problème de performance et de dérive à partir de ~10 entrées par domaine. Le backlog #32 (L2 metadata) est le prérequis de toute amélioration.

### Différence de granularité — et pourquoi c'est correct

Memento opère au niveau **épisodique** : un case = (s_t, a_t, r_t), trace d'un step avec reward. LCARS L2 opère au niveau **sémantique/procédural** : patterns distillés depuis un projet entier, décontextualisés.

Ce sont deux couches complémentaires, pas concurrentes. LCARS a choisi le bon niveau cible pour le long terme — la mémoire sémantique et procédurale généralise mieux cross-projets. Memento montre que la couche épisodique en-dessous ajoute +4.7 à +9.6 points OOD. Les deux coexistent dans les systèmes matures.

### Règle de harvest — à propager dans la spec fleet-harvest-project.sh

> **Une mauvaise mémoire est pire qu'une absence de mémoire.**

Résultat empirique (experience-following bias, littérature CBR + LLM agents) : un fort biais de suivi d'expérience fait que la mémoire biaise fortement la sortie vers des solutions similaires. Si L2 contient un pattern incorrect, les agents le reproduisent avec haute confiance. La sélectivité au harvest n'est pas une optimisation — c'est une contrainte de sécurité.

---

## L2 — Courbe d'efficacité et rollback versionné

*Réf : session 2026-03-08, suite analyse Memento.*

### Modèle de dégradation

L'efficacité de L2 suit une **courbe en cloche** dans le temps :

- **Phase ascendante** : entrées signal-dense, peu nombreuses, bien ciblées. Chaque ajout améliore directement les agents.
- **Pic** : couverture domaine optimale — assez d'entrées pour couvrir les patterns courants, pas encore polluée par staleness ou contradictions internes.
- **Phase descendante** : le bruit dépasse le signal. Entrées obsolètes, contradictions, swamping. μ = uniforme amplifie le problème — toutes les entrées pèsent pareil, bonnes ou non.

La dégradation n'est pas nécessairement lisse — un batch corrompu peut provoquer une chute abrupte (fonction en escalier). Les courbes sont **asymétriques par domaine** : `toolchain/` (cmake, patterns compilateur) est stable, son pic dure longtemps. `semantic/` (décisions de design, contraintes projet) est volatile, le pic est court. Justification supplémentaire pour la séparation backlog #33.

### Workaround — rollback git au pic

LCARS versionne L2 dans git. Le rollback est donc gratuit structurellement :

```bash
git log -- memory/L2/                       # identifier le commit apex
git checkout <sha> -- memory/L2/            # restaurer L2 optimal
```

Le champ `ci_hash` du backlog #32 (metadata par entrée) permet de cibler le rollback à un batch précis, sans réinitialiser l'ensemble du domaine.

### Conséquence architecturale — "releases L2"

Geler L2 au pic implique d'**abandonner l'accumulation continue** au profit de releases L2 périodiques :

1. Accumulation libre entre deux releases
2. Signal de qualité détecte la dégradation (taux d'erreurs qualifier, corrections user, taux d'escalade)
3. Identification du commit apex via `git log`
4. Freeze → la release suivante repart depuis cet état

C'est plus simple à implémenter que la Q-function apprise du M-MDP complet. Contrepartie : nécessite un signal qualité externe fiable pour détecter le pic **avant** d'être en phase descendante. Le pic ne se détecte qu'après coup sans métriques — backlog #20 devient prérequis.

### Dépendances

- **#20** (métriques fleet) — prérequis pour détecter le pic sans être déjà en dégradation
- **#32** (L2 metadata — `ci_hash`) — prérequis pour rollback ciblé par batch
- **#33** (Tool Memory) — courbes distinctes par section L2, rollbacks indépendants
- **#34** (injection filtrée) — atténue la dégradation, retarde l'entrée en phase descendante

---

## Session v3 — 2026-03-08 — Implémentation runtime + infra

*Source : architect sessions 10:30 → 13:00. Compléments engineer pour deploy.*

### Bugs runtime priorité 1 — fleet-broker.py

- **Write atomique** : `path.write_text()` → `tempfile.mkstemp()` + `os.replace()`. Corruption impossible en cas de crash mid-write.
- **`ref:` toujours présent** : champ conditionnel → inconditionnel (6 lignes → 7 dans STATE).
- **`blocker/waiting/notify` préservés** : écrasement à `none` → lecture depuis fichier existant via `_field()` regex.
- **`build-arm` dans HANDOFF_MAP** : entrée manquante → ajoutée.
- **`blocker/waiting/notify` exposés dans le protocole** : `update_state()` accepte ces champs optionnels (`None` = preserve, string = override). Handler `op:state` passe `msg.get()` — absent = preserve, présent = override. Commit `92eca5f`.

### Bugs runtime priorité 1 — wake-instance.sh

- **`_inject_message()`** : fonction helper. Messages >200 chars → paste-buffer (`tmux set-buffer` + `paste-buffer`). Messages courts → `send-keys -l`. Deux sites d'injection remplacés. Règle le problème de buffering sur les longs messages.

### GIT_AUTHOR_NAME par instance

- Identité git distincte par rôle : `LCARS-dev`, `LCARS-builder`, `LCARS-qualifier`, `LCARS-starfleet`, `LCARS-engineer`.
- `git config --global user.name` dans `.gitconfig` de chaque instance existante.
- `post-install-<role>.sh` mis à jour pour les prochaines provisions.
- Motivation : traçabilité commits — savoir quelle instance a touché quoi dans le log git.

### CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=70

- Compact déclenché à 70% au lieu de 83.5% par défaut. Marge de manœuvre avant la dégradation fin de fenêtre.
- Injecté via `deploy.sh` dans `.bashrc` de toutes les instances WSL.
- Injecté via `fleet-launch.sh` pour engineer (window tmux dédiée).

### deploy.sh — 3 bugs corrigés

- `mkdir -p "$(dirname "$DST_FILE")"` manquant → `set -euo pipefail` coupait avant le déploiement de `instance-utils` (scripts stale depuis des semaines).
- Path `commons/handoff` → `commons/#8_handoffs` (24 fichiers scripts affectés — rename non propagé).
- Consistency check `$SCRIPT_DIR/$file` → `$SOURCE_DIR/$file` (CLAUDE.md dans `.claude/`, pas à la racine).

### Backlog #28 — Glossaire machine

`home_claude_CLAUDE-glossary-machine.md` — EN, compact (~100 lignes), machine-readable. Couvre : instances, canaux IPC, protocole socket, scope par rôle, shell utils, terminologie. Déployé dans `~/.claude/` de toutes les instances via `deploy.sh`.

### Backlog #52 — Scope enforcement hook

`post-scope-check.sh` — PostToolUse (Edit/Write). Lit `CLAUDE_AGENT_NAME`, extrait `file_path` du tool input, compare aux interdictions de scope par rôle (dev→toolkit, starfleet→fleet/, qualifier→toolkit, builder→fleet/). Non-bloquant (exit 0) — warning dans le contexte Claude + log dans `~/.local/log/scope-violations.log`. Enregistré dans `settings.local.json` de chaque instance via `deploy.sh` (python3 JSON patch, idempotent).

### Backlog #31 — Harvest d'urgence

Skill `/harvest-emergency` — guide structuré de harvest avant compact à <20% contexte. Étapes : `fleet-state.sh` signal, write `/tmp/fleet-snippet.md` (tâche courante, code changé, décisions, actions en attente, chemins clés), `fleet-inject.sh done`, `/compact` avec instructions. Data point Phase 1 bench documenté inline : dérive à ~14%, seuil conservateur retenu : 20%.

### Doc — ST Principles formalisés

4 principes opérationnels LCARS. Guide `#12_starfleet-protocols.md` créé. Sections ajoutées dans glossaire + system-conventions. Nommage ST comme protocole opérationnel, pas cosmétique.

- **IDIC** : no mono-env assumption. Tout script LCARS doit fonctionner sur des distros, paths, architectures différents.
- **Holodeck Containment** : périmètre qualifier. Writes autorisés : `/home/commons/` + home propre + `/tmp/`. Violation = breach.
- **First Contact Protocol** : onboarding bidirectionnel projet ↔ fleet. Checklist projet + fleet.
- **Temporal Prime Directive** : historique git immutable. Pas de force-push, pas de rewrite-history.

### Doc — Profil user — modèle 2 couches

`#7_user-profile.md` — concept 2 couches : psychologique (forme) + technique (fond). Profil lordzurp rédigé dans `home_claude_CLAUDE.md`. Règle INTERRUPT ajoutée. Suffixe `-standard` formalisé. Structure home agent définie dans system-conventions.

---

## Décision architecture — Context window management (2026-03-08)

*Session architect. Validé empiriquement sur sessions longues.*

### Constat empirique

La dérive de qualité (mauvaise source de vérité, erreur structurelle silencieuse) apparaît **systématiquement après 70% de la fenêtre**. Jamais observée avant. Le warning "12% left" de Claude Code correspond à ~74% de la fenêtre totale (12% × 83.5% cap défaut).

Mesure directe : `cache_read_input_tokens` dans le JSONL de session ÷ 200 000 (Sonnet) = % fenêtre réel.

### Architecture retenue

**Critère de différenciation : interactif vs autonome** (pas précis/stratégique).

| Rôle                                             | Seuil AUTOCOMPACT | Raisonnement                                                                                                 |
| ------------------------------------------------ | ----------------- | ------------------------------------------------------------------------------------------------------------ |
| dev / builder / qualifier / starfleet / engineer | **60%**           | Autonome — l'user ne voit pas le compact. Compact tôt = context propre, zéro coût UX.                        |
| architect                                   | **70%**           | Interactif — compact prématuré = interruption flow user. 70% = hard limit juste avant la zone de corruption. |

### Mécanique fenêtre (référence)

- Fenêtre totale Sonnet = 200K tokens
- `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=N` remplace le cap défaut 83.5% → auto-compact fire à N% du total
- "X% left" affiché = X% du cap courant (pas du total brut)
- Zone de corruption empirique : >70% fenêtre totale
- Seuil autonome 60% = 10% de marge avant corruption, compact fréquent sans friction
- Seuil interactif 70% = hard limit, flow préservé jusqu'à la limite

### Discipline manuelle (interactif)

Pour architect, le soft trigger à 70% est géré manuellement :

1. Détecter via `/cost` ou lecture JSONL (`cache_read_input_tokens`)
2. `/handoff` → écriture STATE + DONE
3. `/compact` forcé

Skill `/harvest-emergency` implémente cette séquence guidée.

### TODO

- `fleet-context-check.sh` — parse JSONL actif, calcule % fenêtre, injecte alerte dans `on-prompt.sh` à 70%
- Soft/hard gap : 70% soft (agent-managed) + 75% hard (AUTOCOMPACT) pour architect

---

## Session architecture — Principes fondateurs + arbo commons (2026-03-08)

*Session architect. Continuation post-compact.*

### General Orders — nomenclature Star Trek

Formalisation des règles fondatrices en General Orders GO-0 → GO-7. Nommage ST délibéré — ancrage mémoriel + cohérence lore déjà présent (LCARS, Starfleet, IDIC…).

- **GO-0 General Order Zero** — "Rien d'implicite." Axiome racine. Corollaire : le pattern d'inférence hors règle explicite est une alarme système (liste non exhaustive, critère = comportement pas vocabulaire).
- **GO-1 Make It So** — règle non encodée = règle inexistante.
- **GO-2 Captain's Log** — tout MR a un pendant HR auditable.
- **GO-3 Red Alert** — tout problème soulevé est traité immédiatement.
- **GO-4 Mission Debrief** — ACK qualifier → [x] immédiat.
- **GO-5 Secure Channel** — IPC via fleet helpers uniquement, jamais `cat >>`.
- **GO-6 Starfleet Priority** — préfixe `#N_` = importance conceptuelle, pas ordre de création.
- **GO-7 Ship's Manifest** — tout fichier versionné porte un en-tête déclaratif. Hook bloque uniquement, jamais auto-fix (anti-pattern fausse robustesse).

Fichier canonique : `#2_directives/#0_principes-fondateurs.md`.

### Arbo commons — règles formalisées dans system-conventions

- Unicité préfixe `#N_` : s'applique aux fichiers ET répertoires.
- Cap numérotation : 00–99. 3 chiffres = signal de sur-accumulation.
- `#1/` dans `/home/commons/` réservé à `#1_docs/` — toujours au même endroit.

### #7_exchange/ — canal user↔fleet

Création `/home/commons/#7_exchange/inbox/` et `outbox/`. Canal contractuel unique pour échanges fichiers user↔fleet. Pas de dépôt direct dans les repos. Pas d'auto-watcher — l'agent interactif dispatche sur mention user.

Mots-clés `inbox` / `outbox` formalisés dans `#4_protocole-user.md` + `_MR.md` (GO-2 appliqué live : on était à deux doigts de définir le canal dans CLAUDE.md sans pendant HR).

### Protocole-user — évolutions

- Règle canal exclusif : tout mot-clé user↔agent DOIT être dans `#4_protocole-user.md` + `_MR.md`.
- Composition `=>` + keyword digression : `=>` porte la causalité, le keyword porte le traitement. Forme lazy documentée.

### Backlog

Items DONE nettoyés : #16, #18, #28, #35, #52. Ajoutés : #73–#76.

### Side quest noté

LCARS-pro : usage métier embarqué (µC, LONworks/BACnet). Point d'entrée = reroll sur cible simple existante. En veille — dépend LCARS fonctionnel. Fichier : `#8_work/doing/lcars-pro-side-quest.md`.

---

### Session 2026-03-08 (post-compact)

**Déploiement (suite de la session précédente)**

deploy.sh lancé après commits `53fef0e` (#72 pre-commit hook GO-7) et `1d8b88c` (cleanup cDs/OST). 18 fichiers copiés.

**Bug-queue/bug-journal — architecture définitive**

Analyse profonde terminée (commencée session précédente). Décision :

- `bug-queue.md` = IPC operationnel fleet-wide. Tier 0, writers = any instance, resolver = dev. Sémantique : `[x]` → trigger bug-journal same session → suppression de la queue.
- `bug-journal.md` = diary narratif FR per-repo. Dev only. Non un MR/HR pair avec bug-queue — scopes distincts.
- Fixes appliqués : bug-queue.md header ("cDs OST" → "fleet-wide"), ipc-protocol.md (`dev-journal.md` → `bug-journal.md` + trigger), home_claude_CLAUDE.md (section Bug journal), #12 First Contact Protocol (note trigger).
- Commit : `a6c98f2`

**Push GitHub — bloqué, qualifier requise**

`/push-github` lancé — danger assessment détecte 3 hooks HIGH : `on-prompt.sh`, `session-startup.sh`, `post-scope-check.sh`. Procédure injectée dans `to-qualifier.md`. Attente ACK qualifier avant push.

Commits en attente : `53fef0e`, `1d8b88c`, `a6c98f2` (+ antérieurs : `2adb509`, `52dca53`, `73a6f79`).

---

### Session 2026-03-09 — Première install Nico-SuperCharged (provisioning v2)

**Contexte**

Nouvelle distro WSL2 Nico-SuperCharged. Première mise en production du provisioning v2 (single-distro, `sudo -u <user> -i`) — passage de la théorie à la pratique.

**Démarrage — lordzurp/architect**

`post-install.sh` lancé pour lordzurp. Série de bugs découverts et fixés en live, commits immédiats + deploy.sh après chaque fix. En ~15 commits (`5327c2a` → `135e556`) :

- `fleet-launch.sh` + `light_off.sh` : `BASH_SOURCE[0]` résout vers le symlink `~/start` — `dirname` pointait vers `~` au lieu de `~/fleet/`. Fix : `readlink -f` avant `dirname`.
- `post-install.sh` : identity lordzurp → `architect` non configurée sur nouvelle distro. Fix : mapping `lordzurp → architect` + écriture `~/.claude/instance-name`.
- `fleet-state.sh` : hard-exit si handoff absent. Fix : auto-création du fichier minimal au premier lancement.
- `configure-plan.sh` : chemin `$REPO_ROOT/fleet/fleet.yaml` → double `fleet/`. Fix : `$REPO_ROOT/fleet.yaml`.
- `post-install.sh` : `/home/private` créé root-owned → lordzurp ne peut pas écrire `git-identity.conf`. Fix : `sudo chown "$USER"` après mkdir.
- `post-install.sh` : `~/.local/bin` absent du PATH interactif après install claude. Fix : ajout dans `.bashrc`.
- `provision-user.sh` : `[ -L ]` / `[ -d ]` sur `/home/dev/.lcars` échoue silencieusement (750 → traversal refusé). Fix : `sudo test -L` / `sudo test -d`.
- `provision-user.sh` : fleet users sans sudoers → `sudo` échoue. Fix : `/etc/sudoers.d/fleet-<user>` NOPASSWD.
- `provision-user.sh` : FLEET_ROOT sous `/home/lordzurp/` inaccessible aux fleet users. Fix : `chmod o+x` sur le home parent.
- `post-install-architect.sh` : nouveau module lordzurp — `btop` via apt + `.hushlogin`.

Résultat fin session : architect opérationnel, dashboard tmux up, fleet-state fonctionnel. `provision-user.sh dev` avancé, 2 bugs restants.

**Doing créés**

- `fleet-ssh-shared-key.md` — une seule clé SSH pour toute la fleet
- `fleet-shared-credentials.md` — claude binaire système + git identity partagée
- `fleet-tmux-layout-v2.md` — layout tmux à mettre à jour pour v2

**Session 2026-03-09 (suite) — bugs provision-user.sh dev**

Deux bugs résiduels fixés :

1. `fatal: detected dubious ownership` sur git pull — FLEET_ROOT owned by lordzurp, dev refuse. Fix : `provision-user.sh` configure `safe.directory` + git identity via `git-identity.conf` *avant* de lancer `post-install.sh` (`sudo -u $USERNAME git config`).
2. `/home/private/git-identity.conf: Permission denied` pour fleet users — `post-install.sh` tentait de lire/écrire le fichier. Fix : restructuration step 8b — skip si git identity déjà configurée par `provision-user.sh`.

Prochain jalon : `provision-user.sh qualifier` → hello world PoC avec dev + qualifier.

---

### Captain's Log — Session 2026-03-09 (matin)

**#14 — Le système se valide par son fonctionnement**

Question posée : y a-t-il une différence fondamentale entre un prompt et une directive au niveau modèle ?

Réponse honnête donnée : non. Pas de magie au niveau tokens. La force de LCARS est dans l'infrastructure (injection automatique, cohérence, déploiement fleet-wide), pas dans une nature ontologique différente des directives. Conséquence directe : l'affirmation du backlog #89 ("l'agent ne peut pas dériver") a été corrigée en temps réel — les directives ne suppriment pas la dérive, elles la rendent improbable par répétition systématique.

Question méta suivante : l'agent abonde-t-il dans le sens de l'utilisateur parce qu'il est noyé dans le concept, ou re-valide-t-il à chaque session fraîche ?

Réponse : les deux risques coexistent (confirmation bias réel), mais la correction spontanée sur prompt/directive — à contre-courant du cadre posé — est une preuve partielle d'analyse indépendante. La limite honnête a été posée explicitement : impossible de distinguer "je re-valide parce que c'est juste" de "je re-valide parce que le contexte est bien construit".

Point clé : la question "le système se valide-t-il par son fonctionnement ?" reçoit une réponse observable dans la session même. L'agent lit CLAUDE.md, suit le protocole, respecte les scopes, utilise les GOs — sans qu'on le lui rappelle. Ce n'est pas une métaphore du "by ref" — c'est sa démonstration. La récursivité du système n'est pas une propriété théorique, c'est un état constaté à chaque session qui en parle.

Formulation "by design / by ref" : terminologie initiée par lordzurp, validée indépendamment. La dualité est juste.

---

### Session 2026-03-09 (après-midi) — Steward onboarding + qualifier fix + PoC 1

**qualifier fix — permissions #8_handoffs**

qualifier (user `qualifier`, groupe `fleet`) ne pouvait pas écrire dans `/home/commons/#8_handoffs/` — répertoire `755 lordzurp:lordzurp`. Fix : `chown lordzurp:fleet` + `chmod g+ws`. Propagé dans `provision-system.sh` (idempotent, garde si groupe fleet absent). fleet-inject.sh fonctionne désormais depuis l'instance qualifier.

**fleet-init SKILL.md — deux rounds qualifier**

Premier run qualifier : FAIL T1 (GO-7 header absent) + T6 (`/home/lordzurp/` hardcodé — IDIC non-compliant).
Fix T1 : header ajouté. Fix T6 : `FLEET_USER` dérivé de `fleet.yaml` dans chaque step. Deuxième round qualifier en cours.

**PoC 1 — définition et écriture**

PoC 1 = première mission réelle de la fleet, user-driven. Le steward suggère "Hello World !" comme tradition du monde logiciel mais n'impose pas. Avertissement explicite : fleet fraîche, pas encore rodée, recommandation de commencer léger. Le steward attend que l'user soit prêt, puis le dirige vers la fenêtre architect (tmux select-window). L'user parle directement à architect — le steward ne relaie pas. architect prend le relais sur la chaîne arch→dev→qualifier→arch (push).

Step 4 de fleet-init SKILL.md réécrit en conséquence. Step 0b ajouté : questions plan Anthropic + git identity avec contexte narratif (remplacement des prompts secs de provision-user.sh).

**Décision : isolation linux-native**

Flatpak écarté (bundle immuable, impossible d'ajouter des packages runtime). Docker écarté (daemon requis). Distrobox (Podman, mutable, daemonless) à évaluer post-PoC. Décision différée — backlog #101.

---

**Découverte : le système de handoff est un garbage collector**

Session 2026-03-10. On tourne avec depuis 4 jours sans l'avoir nommé. Le handoff/compact/trim n'est pas juste de la persistance — c'est un GC générationnel déclaratif pour un runtime qui n'en a pas.

Mapping :

- **Young gen** : contexte de session (tokens actifs)
- **Mark** : /handoff sérialise STATE+ACTIONS+DONE
- **Sweep** : /compact détruit le reste (irréversible)
- **Old gen** : handoffs sur disque, avec handoff-trim.sh (budget 1400B)
- **Permanent gen** : CLAUDE.md, fleet.yaml, commons — jamais collecté
- **AUTOCOMPACT seuils par rôle** : tuning GC (60% autonome, 75% interactif) — équivalent `-Xmx` JVM

Spécificité LCARS : le GC est *déclaratif*. L'agent exécute son propre garbage collection parce que les directives le prescrivent. Pas d'outil externe qui le fait à sa place. Il se GC lui-même, by ref — corollaire direct de l'architecture directive-master.

Aucun autre framework Claude Code ne fait ça. Le comportement par défaut est le compact lossy sans checkpoint — l'équivalent d'un OOM killer sans swap.



raw : 

● Ce qui se passe quand j'exécute /handoff :

1. Le skill est chargé — je reçois ~200 lignes d'instructions procédurales (le prompt du skill). Ces
   instructions deviennent partie de mon contexte courant.

2. Signalement — fleet-state.sh action=shutdown status=in-progress. Purement déclaratif : les autres agents
   voient que je suis en train de fermer.

3. Trim — handoff-trim.sh tronque les handoffs trop gros sur disque. Mécanique, pas intelligent — c'est du bash
   qui compte les bytes.

4. GO-0 scan — c'est là que c'est intéressant. Je n'ai pas de mémoire de travail séparée. Mon "scan" c'est : le
   transcript entier de la session est devant moi, et la directive me dit "cherche les promesses non tenues".
   Concrètement, je cherche :
   
   - Des phrases comme "je vais faire X", "ensuite on fait Y" sans tool call associé après
   - Des "TODO" verbaux sans écriture dans backlog.md
   - Des bugs discutés sans entrée bug-journal
   - Des note-bien: acquittés verbalement ("ok je retiens") sans persistance
   
   C'est du raisonnement sur mon propre output. Pas de diff, pas d'outil — juste moi qui regarde ce que j'ai dit et
   ce que j'ai fait. La qualité dépend directement de la taille du contexte : petit contexte = scan fiable, gros
   contexte = tokens anciens compressés = risque de rater un truc.

5. Read — je lis le handoff existant sur disque. Ça me donne l'état précédent : les ACTIONS en cours, les DONE
   récents.

6. Write — je réécris le fichier entier. C'est le moment critique. Je dois :
   
   - Écrire un STATE qui reflète la réalité (pas ce que j'aimerais qu'elle soit)
   - Transférer les [x] d'ACTIONS vers DONE
   - Garder les [ ] non résolus
   - Ajouter les nouvelles ACTIONS détectées par le GO-0 scan
   - Écrire un DONE narratif de ce qui s'est passé cette session
   - Tout ça en restant sous 120 lignes

7. Offline — fleet-state.sh action=handoff status=offline. Toujours la dernière opération. Le dashboard passe en
   gris.
   
   Ce qui est fragile :
- Le scan dépend de ma capacité à raisonner sur un transcript potentiellement long. Après un compact, les
  premiers échanges sont résumés — je perds le verbatim, donc je peux rater un "je fais ça demain" dit il y a 2
  heures.

- Le Write est atomique : si le filesystem plante entre le Read et le Write, j'ai un handoff corrompu. D'où le
  fallback fleet-inject.sh.

- Le DONE est rédigé par moi, pas extrait mécaniquement. Je peux omettre un détail architectural important parce
  que je ne juge pas qu'il est important. C'est du biais de sélection — le même que pour n'importe quel humain
  qui rédige un compte-rendu.
  
  Ce qui est solide :

- Le cycle est forcé par la directive. Je ne peux pas "oublier" de faire un handoff si /compact est appelé — la
  directive dit "handoff avant compact, jamais compact seul". Et AUTOCOMPACT trigger le hook qui me le rappelle.

- Le STATE est machine-parseable (7 lignes, key: value). Le dashboard le lit sans interprétation. Pas de prose à
  parser.

- Le GC est le mien — je sais ce que j'ai gardé et ce que j'ai jeté, parce que c'est moi qui ai écrit le
  handoff. Au resume, je lis mon propre checkpoint.

- 
