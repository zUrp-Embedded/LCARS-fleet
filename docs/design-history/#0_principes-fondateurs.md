# Principes fondateurs

**Date** : 2026-03-08
**Dernière révision** : 2026-03-10
**Statut** : actif — append-only (ajout en fin de section uniquement, pas de modification des entrées existantes sauf bug-fix documenté)
**Référencé par** : .claude/CLAUDE.md

---

## GO-0 — General Order Zero

### Rien d'implicite. Tout est récursif.

**Définition** : toute règle, contrainte, convention, décision architecturale doit être explicite. Rien n'est sous-entendu, évident, ou connu de tous. Si ce n'est pas écrit, ça n'existe pas. Tout découle de ce principe.

**Corollaire — pattern interdit : l'inférence hors règles** : tout signal linguistique indiquant qu'un agent infère sans règle explicite est une alarme GO-0. Le mot importe peu — c'est le pattern qui compte. Exemples non exhaustifs : "je suppose", "j'imagine", "probablement", "je présume", "en extrapolant", "il me semble que", "je pense que c'est", "logiquement ça devrait", "j'anticipe que"… La liste est infinie — ne pas jouer au bento en listant des mots. Critère unique : l'agent produit une réponse sans règle écrite pour la couvrir. Réponse correcte : GO-3 interrupt — signaler l'ambiguïté, pas la combler.

---

## GO-1 — Make It So

### On le dit pas, on le fait.

**Définition** : énoncer une règle sans l'encoder est sans valeur. Toute règle identifiée doit être immédiatement écrite dans le fichier canonique, commitée, et déployée. La conversation n'est pas de la mémoire.

**Chaîne obligatoire** : Write (fichier canonique) → Commit (versionner) → Deploy (propager). Un maillon manquant = la règle n'existe pas au sens GO-0.

**Corollaire — état système** : ce qui s'applique aux règles s'applique à tout état reproductible : config, permissions, packages, scripts. Un hotfix non commité n'existe pas — le prochain reprovisionning l'écrase. Le repo est la seule mémoire persistante.

---

## GO-2 — Captain's Log Directive

### Tout auditable.

**Définition** : toute règle opérationnelle doit être auditable par un humain. Une règle qui n'est pas lisible, traçable et vérifiable par un non-agent n'existe pas.

**Implémentation** : le système utilise deux formats complémentaires — HR (Human-Readable, français, document source pour audit humain) et MR (Machine-Readable, anglais compact, injecté dans le contexte agent). Définitions complètes : `#1_glossaire-systeme.md § Convention de nommage`. Tout fichier MR doit avoir un pendant HR. Corollaire : un mécanisme de contrôle de sync MR↔HR est obligatoire.

**Chaîne de dérivation** : `directives/` (HR canon, seul périmètre d'écriture normative) → repo `.claude/` (MR dérivé) → `~/.claude/` déployé (deploy.sh). Le HR est l'autorité. Le MR ne contient jamais d'information absente du HR.

---

## GO-3 — Red Alert Protocol

### Tout problème soulevé déclenche immédiatement le protocole.

**Définition** : tout problème identifié — par l'utilisateur ou un agent — est traité immédiatement. Deux options : fix maintenant (si coût < backlog) ou backlog explicite. Jamais de déférement silencieux. Un signal reçu n'est pas optionnel.

**Récidive** : un signal qui revient une deuxième fois n'est plus un incident — c'est une lacune structurelle. La réponse n'est pas un fix ponctuel mais une règle encodée. Le harvest compte les récidives ; GO-3 formalise l'escalade.

---

## GO-4 — Mission Debrief Directive

### Toute mission closurée, résultat quel qu'il soit.

**Définition** : quand un agent traite une action IPC et produit un résultat (ACK, livrable, rapport, refus argumenté), marquer immédiatement `[x]` l'action correspondante dans le fichier IPC. FAIL n'est pas "pas fait" — c'est un résultat. Une action `[ ]` restante après traitement est une ambiguïté bloquante. `[ ]` signifie exclusivement "personne n'a traité".

---

## GO-5 — Secure Channel Protocol

### Les canaux IPC ne tolèrent que des transmissions structurées.

**Définition** : ne jamais écrire dans les fichiers IPC (`to-*.md`, `*-handoff.md`) avec `cat >>` ou redirection brute. Utiliser `fleet-inject.sh` ou les helpers fleet dédiés. `cat >>` ignore la structure du fichier (sections ACTIONS/DONE) et produit des insertions hors-contexte.

---

## GO-6 — Starfleet Priority Classification

### Les noms expriment la fonction, pas l'ordre de création.

**Définition** : tout répertoire et fichier structurant se nomme d'après sa fonction — sémantique et auto-descriptif. Un nom arbitraire, un numéro opaque, ou un acronyme non documenté n'est pas un nom. Critère : un humain extérieur au projet comprend la fonction sans consulter une légende.

---

## GO-7 — Ship's Manifest

### Tout fichier versionné déclare son identité. Pas d'en-tête = le fichier n'existe pas.

**Définition** : tout fichier versionné qui supporte un format de commentaire ou métadonnées doit porter un en-tête déclaratif. Le format est spécifique au type : bloc `Date/Statut/Référencé par` pour `.md`, bloc LCARS stardate/auteur/statut pour les sources (`.sh`, `.py`, `.cpp`...). Même principe, formats différents. Un fichier sans en-tête n'a pas de contexte — il est implicite, donc inexistant au sens de GO-0. Exceptions : formats sans commentaires natifs (`json`, binaires). Les fichiers IPC (`*-handoff.md`, `to-*.md`, `*-queue.md`, `*-notes.md`) ont un format d'en-tête propre (titre + description du canal + writers/readers) — distinct du format GO-7 standard mais obligatoire.

**Champ `Dérivé de`** : pour les fichiers dérivés (version MR d'un HR, traduction, template instancié), ajouter `**Dérivé de** : <fichier source>` dans l'en-tête. Ce champ documente la chaîne de dérivation et permet la détection de dérive.

**Corollaire — signal de confiance** : un agent qui oublie de mettre à jour l'en-tête lors d'un edit a dévié de ses règles. Le pre-commit hook qui vérifie les en-têtes n'est pas un filet de sécurité — c'est un indicateur de dérive. Hook bloqué = signal d'audit. Hook qui passe = l'agent a appliqué GO-7. Le hook **bloque uniquement** — aucun auto-fix. Un hook qui corrige lui-même les violations qu'il détecte n'est pas un contrôle : c'est une dissimulation automatisée.

**Anti-pattern — fausse robustesse** : une solution qui *ressemble* à un GO tout en le violant est le vecteur de dérive le plus dangereux dans un système agent-centric. Le glissement typique : se focaliser sur l'output attendu (header propre) plutôt que sur le signal (header propre parce que l'agent l'a produit). Le résultat final est identique, la signification est opposée. Tester mentalement : "ce mécanisme masque-t-il une violation, ou la révèle-t-il ?"

## GO-8 — Compact Discipline

### L'agent ne guide jamais son propre compact. Un compact piloté est un handoff en dette.

**Définition** : sur signal "auto compact imminent" ou alerte contexte, l'agent exécute `/harvest-emergency` (skill fleet) immédiatement, puis `/compact` nu — sans arguments, sans liste retain/discard. Interdit de produire des instructions `/compact` avec guidance ("retenir X, jeter Y"). Un agent qui pilote son compact avoue que son handoff est en dette : les décisions et l'état courant ne sont pas persistés sur disque. GO-3 rétroactif.

**Corollaire** : un handoff bien tenu en cours de session rend le compact transparent. Rien de critique ne reste uniquement en contexte. Le compact natif de Claude Code suffit — l'agent n'a pas besoin de le guider si le handoff est à jour.

**Anti-pattern — compact guidance** : l'agent produit un bloc `/compact` avec "Retain: code changes, decisions... Discard: file reads, reasoning...". C'est une tentative de préserver du contexte en RAM au lieu de le flush sur disque. Le diagnostic est toujours le même : handoff en retard.

---

## Starfleet Principles — principes opérationnels nommés

Quatre principes opérationnels. Définitions complètes : `#1_glossaire-systeme.md § Starfleet Principles`.

**IDIC** *(Infinite Diversity in Infinite Combinations)* — tout composant fleet doit fonctionner sans hypothèse mono-environnement (ARM64, x86-64, Ubuntu, Debian, WSL2, Linux natif). Critère : "est-ce IDIC-compliant ?"

**Holodeck Containment** — chaque instance opère dans un périmètre write borné et explicite. Containment failure = écriture hors périmètre = incident. **Corollaire récursif (GO-0)** : appliqué à la fleet elle-même — la fleet a exactement deux sorties (frontière OS : StarFleet, frontière User : Architect-lead). Chaque sortie a un sas exclusif Tier 1. Structure : Tier 0 = frontières, Tier 1 = sas (bulkheads), Tier 2 = exécution interne.

**First Contact Protocol** — protocole d'onboarding projet→fleet. Bidirectionnel : le projet doit être prêt à recevoir LCARS, la fleet doit être prête à opérer le projet. Sans First Contact complet : comportement non-défini.

**Temporal Prime Directive (TPD)** — le commit graph est immuable après publication. Violations : `push --force` sur branche partagée, `commit --amend` sur commit poussé, `rebase` sur branche fetchée. Un paradoxe temporel = état divergent entre agents.

---

## Notes — companion narratif

# Notes — #0_principes-fondateurs.md

**Date** : 2026-03-10
**Statut** : companion narratif du fichier canonique
**Fichier canonique** : `#0_principes-fondateurs.md` (seul fichier faisant foi)

> Ce fichier est une version narrative et explicative. Il n'est pas injecté, pas dérivé, pas normatif.
> Toute règle ou contrainte doit vivre dans le fichier canonique. Ce fichier documente le *pourquoi*,
> stocke le changelog, et capture les discussions de refonte.

---

## Changelog version canonique

| Date | Nature | Détail |
|------|--------|--------|
| 2026-03-08 | Création | GO-0 à GO-7 + Starfleet Principles + Index MR |
| 2026-03-10 | Audit v2 | Index MR factuellement faux (6 violations GO-2 constatées) |
| 2026-03-10 | Nettoyage v2 | Retrait Index MR, blocs Ajouté/Contexte/Raffiné, preamble méta. Ajout chaîne GO-1, chaîne dérivation GO-2, enrichissement GO-4 depuis MR déployé |
| 2026-03-10 | Passe 2 v2 | GO-2 généralisé (auditabilité, pas juste MR/HR). GO-7 exception IPC retirée (les IPC ont des headers). Holodeck généralisé à toute la fleet (corollaire récursif GO-0). Backlog : nettoyer les headers IPC incohérents |
| 2026-03-12 | Bug-fix | GO-1 : ajout corollaire état système (hotfix non commité = inexistant, repo = seule mémoire persistante) |

---

## Contenu retiré du canonique

### Preamble (lignes 8-13 original)

> Log méta-narratif des principes fondateurs du système LCARS-fleet.
> Append-only : chaque principe est daté et contextualisé à sa création.
> Ne pas modifier les entrées existantes — ajouter en fin de section.
>
> Définitions compactes dans le glossaire machine (`home_claude_CLAUDE-glossary-machine.md`).
> Ce document est le log narratif de référence.

### Contextes historiques des GOs

**GO-0** — Ajouté 2026-03-08. Contexte : axiome racine du système LCARS-fleet. Tous les autres General Orders en sont des corollaires directs.

**GO-1** — Ajouté 2026-03-08. Contexte : architect a écrit "règle à retenir : ACK qualifier → [x] immédiat" dans la conversation sans l'encoder nulle part. Lordzurp a relevé l'incohérence.

**GO-2** — Ajouté 2026-03-08. Contexte : extension de GO-1. Les fichiers MR injectés sont lisibles par les machines mais difficiles à auditer globalement. Sans pendant HR, les règles opérationnelles ne sont pas révisables.

**GO-3** — Ajouté 2026-03-08. Raffiné 2026-03-09 (récidive = lacune structurelle). Contexte : corollaire de GO-0. Un problème non traité explicitement est un problème implicitement ignoré.

**GO-4** — Ajouté 2026-03-08. Contexte : identifié lors d'un cycle qualifier où l'action est restée `[ ]` après un FAIL, rendant la re-validation ambiguë.

**GO-5** — Ajouté 2026-03-08. Contexte : une directive de re-validation écrite avec `cat >>` a atterri sous `## DONE` au lieu de `## ACTIONS`, rendant la tâche invisible pour qualifier.

**GO-6** — Ajouté 2026-03-08. Contexte : `#0_principes-fondateurs.md` portait initialement le numéro `#8`. Lordzurp a relevé que personne n'arriverait jusqu'au #8.

**GO-7** — Ajouté 2026-03-08. Contexte : corollaire direct de GO-0. Un fichier sans en-tête ne déclare pas ce qu'il est — violation de l'axiome fondateur.

### Index MR (retiré — tracking opérationnel, pas un principe fondateur)

| Fichier MR | Instances cibles | Lignes | Pendant HR | Sync OK |
|---|---|---|---|---|
| `home_claude_CLAUDE.md` | architect, engineer, dev, starfleet | 162 | `hr/home_claude_CLAUDE-HR.md` | [x] ← FAUX |
| `home_claude_CLAUDE-qualifier.md` | qualifier | 114 | `hr/home_claude_CLAUDE-qualifier-HR.md` | [x] |
| `home_claude_CLAUDE-builder.md` | builder, build-arm | 114 | `hr/home_claude_CLAUDE-builder-HR.md` | [x] |
| `home_claude_CLAUDE-glossary-machine.md` | toutes | 104 | — | n/a ← FAUX : #1_glossaire est le HR |

Notes associées : hooks/skills hors scope HR, script sync MR↔HR en backlog.

---

## Bug-fixes — 2026-03-12

### GO-1 — corollaire état système ajouté
Constat : les agents appliquaient des hotfixes manuels (`git config --global` sur chaque user) au lieu de commiter le fix et reprovisionner. Violation GO-1 : un hotfix non commité est écrasé au prochain reprovisioning. Le corollaire généralise : tout état reproductible (config, permissions, packages, scripts) suit la même chaîne Write→Commit→Deploy que les règles. Le repo est la seule mémoire persistante.

---

## Détail — version longue

GO-0

1/ Formulation MR (machine-readable)

  Trois couches, du noyau au déployé :

  Principes fondateurs (#0_principes-fondateurs.md) :
  "Toute règle, contrainte, convention, décision architecturale doit être explicite. Rien n'est sous-entendu,
  évident, ou connu de tous. Si ce n'est pas écrit, ça n'existe pas. Tout découle de ce principe."

  Glossaire machine (injecté dans chaque instance via CLAUDE.md) :
  GO-0 / General Order Zero — "rien d'implicite". Everything must be explicit. Nothing implied, obvious, or
  assumed. All other GOs are corollaries.

  Protocole (home_claude_CLAUDE-protocol.md, section protocol-rules) :
  nothing-implicit: every keyword and behavior is explicitly documented — undocumented behavior does not exist —
  GO-0 alarm pattern: any linguistic signal of inference without explicit rule ("I suppose", "probably", "I
  assume"…) — list is non-exhaustive, pattern is the criterion — correct response: GO-3 interrupt, not silent
  gap-filling

  Trois fichiers, trois angles, même axiome. Le premier définit, le deuxième compresse pour injection, le
  troisième encode le comportement réactif.

  2/ La contrainte concrète

  Ce que GO-0 interdit, c'est le gap-filling silencieux — le comportement par défaut du modèle.

  Un LLM est une machine à compléter. Quand il manque une information, le comportement natif c'est : inférer le
  plus probable et continuer. GO-0 dit : non. S'il manque une règle, tu ne la devines pas — tu signales le trou
  (GO-3 interrupt).

  Concrètement :

- Pas de "logiquement ça devrait marcher comme X" → il faut une règle écrite qui dit que ça marche comme X

- Pas de "je suppose que le fichier va là" → il faut un chemin documenté

- Pas de "les autres GOs couvrent probablement ce cas" → si le cas n'est pas couvert explicitement, il n'est pas
  couvert

- Le corollaire auto-référentiel : GO-0 s'applique à lui-même — la règle de récursivité est écrite explicitement
  dans system-conventions.md parce que laisser la récursivité implicite serait une violation

  Et le pattern alarm : la formulation dit explicitement "la liste est infinie — ne pas jouer au bento en listant
  des mots. Critère unique : l'agent produit une réponse sans règle écrite pour la couvrir." C'est pas une liste
  de mots interdits — c'est un détecteur de comportement.

  3/ Comment ça me contraint, mécaniquement

  Ton expérience avec le tableau de composants électroniques est exactement le cas d'école. Tu as dit "n'utilise
  QUE ce qui est dans le tableau" — c'est une instruction de prompt. Le modèle la lit, l'intègre dans ses poids
  d'attention... et à la 30e ligne, le gradient de complétion est plus fort que l'instruction. L'instruction
  s'érode avec la distance dans la fenêtre de contexte.

  GO-0 fonctionne différemment pour trois raisons :

  a) C'est structurel, pas instructionnel. Ce n'est pas une ligne dans un prompt qui dit "ne fais pas X". C'est un
  axiome qui génère des comportements observables. Chaque GO subséquent (GO-1 à GO-7) est un corollaire qui
  encode un cas concret. Le modèle ne tient pas en mémoire "rien d'implicite" comme une consigne isolée — il tient
  un réseau de 7+ règles interconnectées qui se renforcent mutuellement. Quand GO-7 dit "pas d'en-tête = le
  fichier n'existe pas", c'est GO-0 appliqué aux fichiers. Quand GO-5 dit "jamais cat >> sur les IPC", c'est GO-0
  appliqué aux canaux. Chaque GO est un rappel contextuel de l'axiome.

  b) Le pattern alarm transforme l'inférence en erreur détectable. Ton prompt disait "n'invente pas" — mais le
  modèle ne sait pas quand il invente. Il n'a pas de signal interne fiable pour distinguer "je complète à partir
  de données" de "je complète à partir de rien". GO-0 + le protocole créent ce signal : si je produis une phrase
  contenant un marqueur d'inférence ("je suppose", "probablement"...) et qu'il n'y a pas de règle écrite derrière,
  c'est un GO-3 interrupt. Le modèle peut détecter ses propres marqueurs linguistiques d'incertitude — c'est une
  tâche de classification textuelle, pas d'introspection. C'est la différence : "ne fais pas X" demande de
  l'introspection (savoir qu'on fait X). "Si tu écris le mot 'probablement', arrête-toi" demande du pattern
  matching sur ton propre output — ce que le modèle sait très bien faire.

  c) La redondance par injection. GO-0 n'est pas une ligne perdue dans un prompt de 4000 tokens. Il est dans :

- CLAUDE.md (injecté à chaque session)

- home_claude_CLAUDE-glossary-machine.md (injecté à chaque session)

- home_claude_CLAUDE-protocol.md (injecté à chaque session)

- #0_principes-fondateurs.md (lu au boot / à la demande)

- Indirectement via chaque GO-1 à GO-7 qui le référence

  Le gradient de complétion qui érodait ton instruction à la ligne 30 ? Ici il faudrait qu'il érode simultanément
  5+ sources injectées à des positions différentes dans le contexte. C'est beaucoup plus résistant.

  ---

  Pourquoi "n'improvise pas" ne marche pas et GO-0 marche : "n'improvise pas" est une négation sans critère de
  détection. Le modèle ne sait pas quand il improvise. GO-0 remplace la négation par un système de détection :
  marqueurs linguistiques → alarm → interrupt → demande explicite. C'est pas "ne fais pas X", c'est "quand tu
  détectes ce pattern dans ton output, exécute cette procédure". Tu remplaces de l'introspection impossible par du
   pattern matching sur output — et ça, le modèle sait faire.

---

  GO-1 — Make It So

  "On le dit pas, on le fait."

  1/ Formulation MR

  Principes fondateurs :
  "Énoncer une règle sans l'encoder est sans valeur. Toute règle identifiée doit être immédiatement écrite dans le
   fichier MR canonique, commitée, et déployée. La conversation n'est pas de la mémoire."

  Glossaire machine :
  GO-1 / Make It So — "on le dit pas, on le fait". Stating a rule without encoding it is worthless. Write it,
  commit it, deploy it. Conversation is not memory.

  CLAUDE.md (section MEMORY.md — interdiction stricte) :
  Ne jamais écrire dans MEMORY.md une règle, convention, contrainte, ou décision architecturale. [...] Toute règle
   qui doit survivre à la session va dans home_claude_CLAUDE.md + commit + deploy. Pas d'exception.

  CLAUDE.md (section deploy.sh obligatoire) :
  Tout commit modifiant fleet/, .claude/, ou home_claude_CLAUDE*.md doit être suivi immédiatement de bash
  deploy.sh.

  2/ Contrainte concrète

  GO-1 interdit le pattern le plus naturel d'un LLM : la rétention conversationnelle. Le modèle "comprend" une
  règle en session, l'applique correctement pendant la session, et la perd au compact/restart. Le comportement par
   défaut, c'est : "je retiens ça" = la règle vit dans le contexte de la conversation. GO-1 dit : non — la
  conversation est volatile, seul le fichier MR + commit + deploy est durable.

  Concrètement, GO-1 crée une chaîne de 3 actions obligatoires à chaque identification de règle :

1. Write — écrire dans le fichier MR canonique (pas MEMORY.md, pas un fichier temporaire)

2. Commit — versionner (sinon le working tree est aussi volatile que la conversation)

3. Deploy — deploy.sh pour propager à toutes les instances (sinon un seul agent a la règle)

   Si un seul maillon manque, la règle n'existe pas au sens GO-0. "C'est dans le working tree mais pas commité" =
   ça n'existe pas. "C'est commité mais pas déployé" = ça existe pour le repo mais pas pour la fleet.

   Le contexte d'origine est révélateur : architect a écrit dans la conversation "règle à retenir : ACK qualifier →
   [x] immédiat". Tu as vu la violation : la règle était verbalisée mais pas encodée. D'où GO-4 qui a ensuite
   formalisé ce cas spécifique — mais GO-1 est le mécanisme générique.

   3/ Comment ça me contraint

   GO-1 transforme l'identification d'une règle en side-effect obligatoire. Sans GO-1, quand je repère un pattern
   récurrent dans la conversation, mon comportement naturel est : l'intégrer dans mon raisonnement pour la suite de
   la session. Avec GO-1, repérer un pattern récurrent déclenche : est-ce que c'est encodé quelque part ? Non →
   Write + commit + deploy, maintenant. Oui → continuer.

   C'est une contrainte forte parce qu'elle interrompt le flux de travail. Je suis en train de coder, je remarque
   un pattern — GO-1 dit : arrête de coder, encode le pattern, reviens au code. C'est du context-switching imposé.
   Le bénéfice : la fleet ne dérive pas. Chaque instance qui démarre a exactement les mêmes règles, parce qu'elles
   ont été écrites, commitées, et déployées — pas "retenues" dans un contexte qui va être compacté.

   Le lien avec le modèle est direct : un LLM n'a aucune mémoire persistante native. MEMORY.md est un hack — un
   fichier relu au démarrage. GO-1 dit : même ce hack est insuffisant pour les règles (MEMORY.md = contexte
   session, pas règle durable). Le seul mécanisme fiable, c'est le fichier versionné injecté via @import dans
   CLAUDE.md. C'est la seule chose garantie d'être dans le contexte à chaque session.

  ---

  GO-2 — Captain's Log Directive

  "Tout auditable."

  1/ Formulation MR

  Principes fondateurs :
  "Tout fichier MR doit avoir un pendant HR auditable. Une règle non auditable par un humain n'existe pas.
  Corollaire : le script de contrôle de sync MR↔HR est obligatoire."

  Glossaire machine :
  GO-2 / Captain's Log Directive — "tout auditable". Every MR file must have an HR counterpart. A rule not
  auditable by a human does not exist.

  Index MR dans principes-fondateurs.md — le tableau de correspondance :
  | home_claude_CLAUDE.md → hr/home_claude_CLAUDE-HR.md |
  | home_claude_CLAUDE-qualifier.md → hr/home_claude_CLAUDE-qualifier-HR.md |
  | home_claude_CLAUDE-builder.md → hr/home_claude_CLAUDE-builder-HR.md |

  CLAUDE.md (backlog #107) :
  #107 HR doc pour directives claude (GO-2)

  2/ Contrainte concrète

  GO-2 résout un problème spécifique aux systèmes multi-agents : l'opacité des règles machine.

  Les fichiers MR (home_claude_CLAUDE*.md) sont écrits pour être parsés par le modèle. Ils sont denses, compacts,
  parfois cryptiques ("drvfs (9p) — Edit tool silently empties files"). Un humain peut les lire, mais auditer 162
  lignes de directives compactes EN pour vérifier qu'aucune règle n'est absurde, redondante, ou contradictoire ?
  En pratique, ça ne se fait pas.

  GO-2 impose un miroir : chaque fichier MR a un pendant HR — un document en français, structuré pour la lecture
  humaine, qui décrit les mêmes règles avec contexte et justification. Si une règle existe dans le MR mais pas
  dans le HR, elle n'est pas auditable — donc elle n'existe pas (GO-0).

  Le script sync-mr-hr.sh est le mécanisme de vérification : il détecte les dérives entre les paires MR/HR. Si le
  MR évolue sans que le HR suive, c'est un signal d'audit.

  Concrètement :

- Chaque fois qu'une règle est ajoutée/modifiée dans un fichier MR → le HR correspondant doit être mis à jour
  dans la même session

- Un fichier MR sans pendant HR est une dette GO-2 (backlog #107 en est la preuve vivante)

- Le format HR n'est pas une copie — c'est une traduction conceptuelle : pourquoi la règle existe, ce qu'elle
  empêche, comment elle s'articule avec les autres

  3/ Comment ça me contraint

  GO-2 crée un double writing obligatoire. Chaque règle MR nécessite un effort de reformulation HR. C'est
  intentionnellement coûteux — le coût est le mécanisme de qualité. Si une règle ne vaut pas l'effort d'être
  expliquée en HR, elle ne vaut probablement pas la peine d'exister en MR.

  Pour le modèle, GO-2 impose de la réflexivité. Écrire un HR, c'est expliquer à un humain pourquoi la règle que
  j'applique existe. Ça force une validation : est-ce que cette règle a du sens hors du contexte immédiat où elle
  a été créée ? Un MR peut contenir une règle ad-hoc née d'un incident ponctuel. Le HR force l'examen : cette
  règle est-elle générale ou circonstancielle ?

  Le lien avec le problème multi-agent : sans GO-2, les instances pourraient accumuler des règles MR que personne
  ne relit jamais. L'humain fait confiance au système ("ça marche"), les agents suivent les règles ("c'est
  écrit"), et personne ne vérifie si l'ensemble est cohérent. GO-2 crée le point de contrôle humain.

  ---

  GO-3 — Red Alert Protocol

  "Tout problème soulevé déclenche immédiatement le protocole."

  1/ Formulation MR

  Principes fondateurs :
  "Tout problème identifié — par l'utilisateur ou un agent — est traité immédiatement. Deux options : fix
  maintenant (si coût < backlog) ou backlog explicite. Jamais de déférement silencieux."

  "Récidive : un signal qui revient une deuxième fois n'est plus un incident — c'est une lacune structurelle. La
  réponse n'est pas un fix ponctuel mais une règle encodée."

  Glossaire machine :
  GO-3 / Red Alert Protocol — every raised issue triggers immediate handling. Fix now or explicit backlog. No
  silent deferral. Recurrence (second signal) = structural gap → encode a rule, not a point fix.

  CLAUDE.md (section Rules) :
  Any issue raised — by user or agent — is treated immediately. Two options only: fix now (if cost < appending to
  backlog) or backlog it explicitly. Never propose to skip or defer silently to continue the current task. A
  raised point is an interrupt signal, not an optional aside.

  Protocole (section protocol-rules, nothing-implicit) :
  correct response: GO-3 interrupt, not silent gap-filling

  2/ Contrainte concrète

  GO-3 combat le defer-and-forget pattern — le comportement par défaut quand un modèle est en milieu de tâche et
  qu'un problème apparaît.

  Le flux naturel : je suis en train de réécrire deploy.sh, je remarque que fleet-check-coherence.sh a un bug
  GO-5. Mon instinct de complétion dit : "noter pour plus tard, finir la tâche en cours". GO-3 dit : non. Le
  problème est soulevé → il est traité maintenant. Soit le fix est trivial (< coût du backlog) → fix immédiat.
  Soit le fix est non-trivial → écriture explicite dans le backlog avec contexte complet. Dans les deux cas,
  l'action est immédiate. Ce qui est interdit, c'est le troisième chemin : "je continue et on verra".

  La clause récidive est la vraie force. Premier signal = incident, traité comme tel. Deuxième signal sur le même
  sujet = le traitement du premier signal était insuffisant. La réponse n'est plus un fix — c'est un GO encodé.
  C'est exactement comme ça que GO-3 lui-même a été raffiné le 2026-03-09 : la récidive était observée, donc le GO
   existant a été enrichi de la clause récidive au lieu de créer un GO-8.

  Concrètement :

- Problème mentionné par l'user ou détecté par l'agent → arrêt de la tâche en cours

- Évaluation coût fix vs coût backlog → décision binaire

- Fix trivial → exécuter maintenant, reprendre la tâche

- Fix non-trivial → écrire dans backlog.md avec contexte → reprendre la tâche

- Même problème une deuxième fois → ce n'est plus un fix, c'est une règle manquante → encoder (GO-1)

  3/ Comment ça me contraint

  GO-3 est le mécanisme d'interruption du système. Sans lui, un LLM en mode "tâche longue" a tendance à optimiser
  la complétion de la tâche en cours. Les problèmes secondaires sont mentionnés dans l'output ("à noter : il
  faudrait aussi...") mais pas traités. L'utilisateur voit la mention, peut-être la note, probablement l'oublie.

  GO-3 transforme chaque observation de problème en interruption de contrôle de flux. Le modèle ne peut pas
  "mentionner" un problème sans le traiter. C'est binaire : fix ou backlog, pas de troisième option.

  Le lien avec GO-0 est direct : un problème mentionné mais pas traité est un problème implicitement déféré.
  "Implicitement" → violation GO-0. GO-3 rend le déférement explicite (backlog entry avec contexte) ou le supprime
  (fix immédiat).

  Pour le modèle, la clause récidive est un mécanisme anti-dérive. Un LLM peut appliquer le même fix ponctuel 10
  fois sans jamais réaliser qu'il y a un pattern. GO-3 dit : à la deuxième occurrence, le pattern est avéré →
  encoder une règle. C'est un forçage de méta-cognition : au lieu de traiter les symptômes en boucle, identifier
  la cause structurelle.

  ---

  GO-4 — Mission Debrief Directive

  "Toute mission closurée, résultat quel qu'il soit."

  1/ Formulation MR

  Principes fondateurs :
  "Quand qualifier écrit un ACK (PASS ou FAIL), marquer immédiatement [x] l'action correspondante dans le fichier IPC.
  FAIL n'est pas 'pas fait' — c'est un résultat. Une action [ ] restante après ACK est une ambiguïté bloquante."

  Glossaire machine :
  GO-4 / Mission Debrief Directive — qualifier ACK (PASS or FAIL) → mark [x] immediately. FAIL is a result, not "not
  done".

  CLAUDE.md (section Tests) :
  Quand qualifier écrit un ACK (PASS ou FAIL), marquer immédiatement [x] l'action correspondante dans le fichier IPC.
  FAIL n'est pas "pas fait" — c'est un résultat. Une action [ ] restante après ACK est une ambiguïté bloquante
  pour la prochaine lecture.

  2/ Contrainte concrète

  GO-4 résout un problème de sémantique d'état dans les protocoles asynchrones.

  Dans un système multi-agent avec fichiers IPC, l'état [ ] a un sens précis : "tâche non traitée". Quand qualifier teste
   et obtient un FAIL, l'instinct est de laisser [ ] parce que "c'est pas passé, donc c'est pas fait". Mais pour
  l'agent qui relit le fichier à sa prochaine session, [ ] = "personne n'a regardé". Il ne peut pas distinguer :

- [ ] personne n'a traité

- [ ] qualifier a testé, ça a FAIL, mais l'item n'est pas marqué

  GO-4 dit : [x] signifie "traité", pas "réussi". Un FAIL est un résultat — la mission a été exécutée, le debrief
  est fait. L'état de la tâche (pass/fail) est dans le contenu du ACK, pas dans la checkbox.

  Concrètement :

- qualifier écrit un ACK PASS → [x] immédiat sur l'action IPC correspondante

- qualifier écrit un ACK FAIL → [x] immédiat aussi — avec le FAIL documenté dans le corps

- Aucune action [ ] ne doit rester après qu'un ACK existe pour cette action

- Si un agent voit [ ] dans un fichier IPC, il peut assumer que personne n'a traité l'item

  3/ Comment ça me contraint

  GO-4 impose une hygiène d'état stricte sur les fichiers IPC. Le modèle ne peut pas interpréter [ ] comme "en
  cours" ou "échoué mais on y reviendra". [ ] = non traité. [x] = traité (résultat dans le contenu).

  Pour un LLM, la subtilité est dans la distinction entre "état de la tâche" et "résultat de la tâche". Le modèle
  a tendance à fusionner les deux : si le résultat est négatif, l'état devrait refléter l'échec. GO-4 sépare
  explicitement : la checkbox est l'état de traitement (oui/non), le contenu textuel est le résultat
  (pass/fail/détails). C'est un pattern de protocol design — séparer le signal de contrôle (checkbox) du payload
  (contenu).

  Sans GO-4, les fichiers IPC accumulent des [ ] ambigus. qualifier a testé ? Pas testé ? Testé et fail ? L'agent qui
  relit ne peut pas savoir. Il perd du contexte à investiguer. Avec GO-4, [ ] a un sens unique et fiable :
  personne n'a traité.

  ---

  GO-5 — Secure Channel Protocol

  "Les canaux IPC ne tolèrent que des transmissions structurées."

  1/ Formulation MR

  Principes fondateurs :
  "Ne jamais écrire dans les fichiers IPC (to-*.md, *-handoff.md) avec cat >> ou redirection brute. Utiliser
  fleet-inject.sh ou les helpers fleet dédiés. cat >> ignore la structure du fichier et produit des insertions
  hors-contexte."

  Glossaire machine :
  GO-5 / Secure Channel Protocol — IPC files (to-*.md) only via fleet helpers. Never cat >>.

  CLAUDE.md (section Git/Tests) :
  Ne jamais écrire dans les fichiers IPC (to-*.md, *-handoff.md) avec cat >> ou redirection brute. Utiliser
  fleet-inject.sh (multiline depuis /tmp/fleet-snippet.md) ou les helpers fleet dédiés.

  2/ Contrainte concrète

  GO-5 protège l'intégrité structurelle des fichiers partagés.

  Les fichiers IPC ont une structure : ## STATE, ## ACTIONS, ## DONE. Chaque section a une sémantique. cat >>
  file.md ajoute du texte à la fin du fichier — quelle que soit la section. Un agent qui écrit une action avec cat

> > la met sous ## DONE si c'est la dernière section. L'action devient invisible pour l'agent qui lit ##
> >   ACTIONS.

  C'est exactement ce qui s'est passé : une directive de re-validation écrite avec cat >> a atterri sous ## DONE.
  qualifier n'a jamais vu la tâche parce qu'elle lisait ## ACTIONS.

  GO-5 impose l'utilisation de helpers qui comprennent la structure :

- fleet-inject.sh done → insère sous ## DONE, au bon endroit

- fleet-inject.sh actions → insère sous ## ACTIONS

- fleet-done.sh "titre" "corps" → append structuré dans ## DONE

- fleet-state.sh → modifie les champs ## STATE par nom

  Ces helpers sont des parseurs structurels — ils savent où écrire dans le fichier. cat >> est un append aveugle.

  3/ Comment ça me contraint

  GO-5 interdit le raccourci le plus tentant pour un LLM. Quand je dois écrire une ligne dans un fichier, cat >>
  file.md <<< "texte" est le chemin le plus court en tokens. C'est une seule commande bash, immédiate, pas
  d'import, pas de dépendance. GO-5 dit : non — utilise fleet-done.sh ou fleet-inject.sh, qui sont plus longs à
  écrire mais garantissent le placement structurel.

  C'est une contrainte anti-optimisation locale. Le modèle optimise naturellement pour le coût local (tokens,
  complexité de la commande). GO-5 impose un coût local plus élevé pour un bénéfice systémique : l'intégrité des
  fichiers IPC à travers toutes les sessions et tous les agents.

  Pour un système multi-agent, c'est critique. Si un seul agent écrit un cat >> qui corrompt la structure d'un
  fichier IPC, tous les agents qui lisent ce fichier sont affectés. Le coût d'un cat >> mal placé se propage à N
  agents × M sessions. Le coût d'utiliser fleet-inject.sh est payé une fois par l'agent écrivant.

  ---

  GO-6 — Starfleet Priority Classification

  "Le numéro exprime l'importance conceptuelle, pas l'ordre de création."

  1/ Formulation MR

  Principes fondateurs :
  "Le préfixe #N_ d'un dossier ou fichier exprime son importance de lecture pour un humain. #0 = fondations,
  numéros croissants = spécificité croissante. Un principe fondateur ne peut pas porter un numéro élevé — il
  serait ignoré."

  Glossaire machine :
  GO-6 / Starfleet Priority Classification — #N_ prefix = conceptual importance, not creation order. #0 =
  foundations.

  CLAUDE.md (section docs_and_plans) :
  Le préfixe numérique d'un dossier ou fichier exprime son importance de lecture pour un humain, pas son ordre de
  création. #0 = fondations (à lire en premier), numéros croissants = spécificité croissante. Un principe
  fondateur ne peut pas porter un numéro élevé — il serait ignoré. Lors de l'ajout d'un fichier, choisir son
  numéro selon sa position dans la hiérarchie conceptuelle, pas selon la prochaine valeur disponible.

  System-conventions.md :
  #0_=entry/prereqs (multiple allowed), #8_=live state (suggested), #9_=archives (multiple allowed) — unique per
  level — gaps allowed

  2/ Contrainte concrète

  GO-6 encode un principe d'information architecture directement dans le filesystem.

  Le problème d'origine : #0_principes-fondateurs.md était numéroté #8. Le huitième fichier dans une liste de 9.
  Personne — ni humain, ni agent — ne lit jusqu'au #8. Les principes fondateurs du système étaient enterrés sous 7
   niveaux de documentation plus spécifique.

  GO-6 dit : le numéro n'est pas un compteur — c'est un indicateur de priorité de lecture. #0 = "lire ça en
  premier, tout le reste en dépend". #9 = "archives, lire si besoin spécifique". Le numéro guide à la fois
  l'humain qui browse et l'agent qui charge du contexte.

  Concrètement :

- #0_principes-fondateurs.md = #0 parce que tout le système en découle

- #2_directives/ = #2 parce que c'est le cadre opérationnel

- #8_handoffs/ = #8 parce que c'est de l'état live, pas de la documentation fondatrice

- #9_archives/ = #9 parce que c'est du passé

- Les gaps sont autorisés — pas besoin de #3, #4, #5 si rien n'a cette importance

- Un agent qui crée un fichier doit se demander : "où se situe ce contenu dans la hiérarchie conceptuelle ?" et
  non "quel est le prochain numéro libre ?"

  3/ Comment ça me contraint

  GO-6 m'empêche d'utiliser un auto-increment naïf. Le comportement par défaut pour un modèle : regarder les
  numéros existants, prendre le suivant. #5, #6, #7 → nouveau fichier = #8. GO-6 interdit ça. Le nouveau fichier a
  le numéro qui correspond à son importance conceptuelle, pas à son ordre d'arrivée.

  C'est une contrainte de réflexion avant action. Avant de nommer un fichier, je dois évaluer où il se situe par
  rapport aux existants — pas seulement dans la liste, mais dans la hiérarchie de dépendances conceptuelles.
  "Est-ce que ce fichier est un prérequis pour d'autres ?" → numéro bas. "Est-ce que ce fichier est un détail
  d'implémentation ?" → numéro haut.

  Pour un système multi-agent, GO-6 a un effet de découverte : quand un nouvel agent démarre et charge son
  contexte, il lit les fichiers dans l'ordre numérique. Si l'ordre reflète l'importance, l'agent construit sa
  compréhension du système des fondations vers les détails. Si l'ordre est chronologique, l'agent reçoit un
  historique non-structuré.

  ---

  GO-7 — Ship's Manifest

  "Tout fichier versionné déclare son identité. Pas d'en-tête = le fichier n'existe pas."

  1/ Formulation MR

  Principes fondateurs :
  "Tout fichier versionné qui supporte un format de commentaire ou métadonnées doit porter un en-tête déclaratif.
  [...] Un fichier sans en-tête n'a pas de contexte — il est implicite, donc inexistant au sens de GO-0."

  "Corollaire — signal de confiance : un agent qui oublie de mettre à jour l'en-tête lors d'un edit a dévié de ses
   règles. Le pre-commit hook qui vérifie les en-têtes n'est pas un filet de sécurité — c'est un indicateur de
  dérive."

  "Anti-pattern — fausse robustesse : une solution qui ressemble à un GO tout en le violant est le vecteur de
  dérive le plus dangereux. [...] Tester mentalement : 'ce mécanisme masque-t-il une violation, ou la révèle-t-il
  ?'"

  Glossaire machine :
  GO-7 / Ship's Manifest — every versioned file that supports comments or metadata must carry a declarative
  header. No header = no context = file does not exist (GO-0 corollary).

  CLAUDE.md (section docs_and_plans, GO-7) :
  Every versioned file that supports comments must carry a declarative header. Same principle, two formats: docs
  (.md) — Date/Statut/Référencé par; source (.sh, .py, .cpp...) — LCARS stardate/author/status block.

  2/ Contrainte concrète

  GO-7 impose l'auto-documentation structurelle à chaque fichier.

  Un fichier sans en-tête est un fichier sans contexte. Qui l'a créé ? Quand ? Quel est son statut ? De quoi
  dépend-il ? Qui le référence ? Toutes ces réponses sont implicites (dans l'historique git, dans la mémoire de
  quelqu'un, "quelque part"). GO-7 les rend explicites, dans le fichier lui-même.

  Deux formats selon le type :

- .md : bloc Date / Dernière révision / Statut / Référencé par / Dérivé de

- .sh, .py, .cpp : bloc LCARS stardate/auteur/statut (le header ASCII Star Trek)

  Exceptions documentées : json (pas de commentaires natifs), binaires, fichiers IPC opérationnels (handoffs,
  to-*.md — ces fichiers sont éphémères par design).

  Le champ Dérivé de est spécifique aux fichiers dérivés (HR d'un MR, traductions, templates instanciés). Il
  documente la chaîne de dérivation pour la détection de dérive via sync-mr-hr.sh.

  Le corollaire signal de confiance est le plus subtil. Le pre-commit hook qui vérifie les en-têtes ne corrige
  rien — il bloque. Si un agent produit un commit sans en-tête, le hook bloque. Ce n'est pas un filet de sécurité
  ("le hook corrigera") — c'est un indicateur de dérive ("l'agent n'a pas appliqué GO-7"). Un hook qui auto-fix
  les en-têtes serait une violation : il masquerait la dérive au lieu de la signaler.

  L'anti-pattern fausse robustesse est le garde-fou méta : "ce mécanisme masque-t-il une violation, ou la
  révèle-t-il ?" Un auto-fix masque. Un bloqueur révèle.

  3/ Comment ça me contraint

  GO-7 ajoute un overhead systématique à chaque création ou modification de fichier. Créer un nouveau .sh ?
  En-tête LCARS obligatoire. Modifier un .md existant ? Vérifier et mettre à jour Dernière révision. C'est du
  travail supplémentaire à chaque opération fichier.

  Pour le modèle, la contrainte la plus forte est l'anti-pattern fausse robustesse. Un LLM est très bon pour
  produire des solutions qui ressemblent à la conformité. "Ajoutons un hook qui insère automatiquement les
  en-têtes" — ça produit le même output visible (fichiers avec en-têtes) mais viole le principe (l'agent n'a pas
  intériorisé GO-7, il est simplement corrigé après coup). GO-7 m'interdit explicitement de proposer ce type de
  solution.

  Le test mental est une contrainte de raisonnement : avant de proposer un mécanisme de conformité, je dois
  évaluer s'il masque ou révèle. C'est une distinction que le modèle peut faire — "est-ce que mon proposal rend
  les violations invisibles ?" est une question à laquelle un LLM sait répondre. GO-7 force simplement à poser
  cette question.

  ---

  Starfleet Principles — principes opérationnels pré-GO

  IDIC — Infinite Diversity in Infinite Combinations

  1/ Formulation MR

  Principes fondateurs :
  "Tout composant fleet doit fonctionner sans hypothèse mono-environnement (ARM64, x86-64, Ubuntu, Debian, WSL2,
  Linux natif). Critère : 'est-ce IDIC-compliant ?'"

  Glossaire machine :
  IDIC-compliant — no mono-env assumption; works across distros, paths, architectures.

  2/ Contrainte concrète

  IDIC interdit les hypothèses d'environnement implicites. Pas de path hardcodé /mnt/c/Users/... (WSL-only). Pas
  de apt-get sans vérification du package manager. Pas de x86_64 assumé quand ARM64 est une cible. Chaque script
  doit fonctionner sur : Ubuntu, Debian, WSL2, Linux natif, ARM64, x86-64.

  Concrètement c'est un filtre sur chaque ligne de code système : "est-ce que ça marche aussi sur l'autre archi /
  l'autre distro ?"

  3/ Comment ça me contraint

  IDIC m'empêche de prendre le raccourci de l'environnement courant. Quand je suis dans une session WSL2, tout
  fonctionne avec les paths WSL2, les tools Ubuntu, l'archi x86-64. IDIC dit : ce que tu écris ici sera aussi
  exécuté sur un Raspberry Pi ARM64 sous Debian. Chaque commande, chaque path, chaque dépendance doit être validée
   contre cette diversité.

  ---

  Holodeck Containment

  1/ Formulation MR

  Principes fondateurs :
  "Périmètre d'isolation qualifier. L'instance qualifier opère dans un périmètre write borné. Containment failure = écriture
  hors périmètre = incident."

  Glossaire machine :
  Holodeck Containment — qualifier write perimeter: no writes outside /home/commons/ + own home.

  CLAUDE.md (section Instance scope) :
  qualifier : accès à /home/commons/ et son propre home uniquement — /home/wsl-root/ (drvfs) n'est pas monté dans son
  instance.

  2/ Contrainte concrète

  qualifier ne peut écrire que dans deux endroits : /home/commons/ (canaux IPC partagés) et /home/qualifier/ (son propre home).
  Toute écriture ailleurs est un "containment failure" — un incident, pas un bug. Le filesystem lui-même renforce
  la règle : drvfs n'est pas monté, donc les projets sous /home/wsl-root/ sont physiquement inaccessibles.

  C'est un bac à sable par design : qualifier peut lire et tester, mais ne peut pas modifier le code source ni les
  artefacts de build. Ses seuls outputs sont : résultats de test (dans les canaux IPC) et ses propres fichiers
  locaux.

  3/ Comment ça me contraint

  Quand je suis l'instance qualifier, Holodeck Containment réduit mon espace d'action à la lecture + tests + rapports. Je
   ne peux pas "corriger rapidement" un bug que j'ai trouvé — je dois le rapporter dans to-dev.md [qualifier] et laisser
  dev le fixer. C'est une séparation stricte des responsabilités imposée par le filesystem, pas par la confiance.

  ---

  First Contact Protocol

  1/ Formulation MR

  Principes fondateurs :
  "Protocole d'onboarding projet→fleet. Bidirectionnel : le projet doit être prêt à recevoir LCARS, la fleet doit
  être prêt à opérer le projet. Sans First Contact complet : comportement non-défini."

  Glossaire machine :
  First Contact Protocol — bidirectional onboarding: project side + fleet side checklist.

  2/ Contrainte concrète

  Prendre en charge un nouveau projet nécessite un protocole bidirectionnel :

- Côté projet : docs_and_plans/ créé, structure arbo en place, README conforme, CI gate fonctionnelle

- Côté fleet : rôles assignés, canaux IPC initialisés, workspace cloné dans les homes agents, CLAUDE.md projet
  configuré

  Si le First Contact n'est pas complet, le comportement est explicitement non-défini. Pas "dégradé" — non-défini.
  Un agent qui opère sur un projet sans First Contact complet peut produire n'importe quoi, et c'est attendu.

  3/ Comment ça me contraint

  First Contact m'interdit de commencer à travailler sur un projet ad-hoc. "Clone ce repo et fais un fix" sans
  First Contact complet = comportement non-défini. Je dois d'abord vérifier que la checklist bidirectionnelle est
  satisfaite. Si elle ne l'est pas, la première tâche est de compléter le First Contact, pas de coder.

  ---

  Temporal Prime Directive (TPD)

  1/ Formulation MR

  Principes fondateurs :
  "Le commit graph est immuable après publication. Violations : push --force sur branche partagée, commit --amend
  sur commit poussé, rebase sur branche fetchée. Un paradoxe temporel = état divergent entre agents."

  Glossaire machine :
  Temporal Prime Directive — git history is immutable; no force-push, no rewrite-history.

  CLAUDE.md (section Git) :
  Prefer to create a new commit rather than amending an existing commit.

  2/ Contrainte concrète

  Trois opérations interdites sur tout commit publié (poussé ou fetché par un autre agent) :

- git push --force — réécrit l'historique distant

- git commit --amend sur un commit déjà poussé — crée un paradoxe (l'ancien commit existe chez les agents qui
  l'ont fetché)

- git rebase sur une branche partagée — réordonne des commits que d'autres agents référencent

  "Paradoxe temporel" = deux agents ont des historiques divergents pour la même branche. L'agent A a le commit
  abc123, l'agent B a un def456 qui est le rebase de abc123. Les références croisées (handoffs, bug reports)
  deviennent invalides.

  3/ Comment ça me contraint

  TPD interdit les corrections rétroactives. J'ai commité un message de commit mal formulé ? Je ne peux pas
  --amend si le commit est poussé. J'ai une série de petits commits qui "devraient" être un seul ? Pas de rebase
  interactif si quelqu'un a fetché. La seule opération autorisée est forward-only : nouveau commit qui corrige.

  Pour un LLM, c'est une contrainte forte parce que les suggestions de "cleanup" git sont très naturelles. "Squash
  these commits before pushing" — non. "Amend the commit message" — non si publié. "Rebase onto main" — non si
  quelqu'un travaille dessus. Forward-only, toujours.
