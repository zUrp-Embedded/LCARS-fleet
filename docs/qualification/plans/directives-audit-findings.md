# Audit directives LCARS — findings

**Date** : 2026-03-25
**Derniere revision** : 2026-03-25
**Statut** : audit complet — v6.0-RC
**Reference par** : demande user

## Statistiques
- Fichiers audites : 27 (8 core + 3 organisation + 2 protocole + 11 roles + 3 profiles)
- References verifiees : ~85
- Findings : 21 (0 CRITICAL / 5 HIGH / 11 MEDIUM / 5 LOW)

---

## Findings

### REF-01 (HIGH) : GO-4 et GO-7 definis hors de #1_general-orders.md — non-recouvrement structurel

**Fichier** : fleet/system-prompt/sources/organisation/topologie.md (l.160), fleet/system-prompt/sources/organisation/workflow.md (l.22)
**Detail** : GO-4 (Mission Debrief) est defini dans topologie.md. GO-7 (En-tete declaratif) est defini dans workflow.md. Les autres GO (0, 1, 3, 5, 8) sont dans core/#1_general-orders.md. Le commentaire dans #1 mentionne GO-2 et GO-6 comme retires, mais ne mentionne pas GO-4 et GO-7 comme delocalises. Un agent qui lit #1_general-orders.md pour comprendre les General Orders ne trouvera ni GO-4 ni GO-7.
**Fix propose** : Ajouter dans le commentaire HTML de #1_general-orders.md une note : "GO-4 defini dans topologie.md, GO-7 defini dans workflow.md" pour la tracabilite. Ou consolider tous les GO dans un seul fichier.

---

### REF-02 (HIGH) : GO-5 defini dans infrastructure.md, pas dans general-orders.md

**Fichier** : fleet/system-prompt/sources/organisation/infrastructure.md (l.33)
**Detail** : GO-5 (Secure Channel) est defini dans infrastructure.md. L'exemple dans #1_general-orders.md (l.50) mentionne "un bug GO-5 dans fleet-check-coherence.sh" — reference a GO-5 sans le definir. Meme probleme que REF-01 : les GO sont disperses entre 3 fichiers differents.
**Fix propose** : Meme que REF-01 — soit consolider, soit documenter la dispersion dans le commentaire HTML.

---

### REF-03 (HIGH) : builder et deployer n'ont pas de fichier role

**Fichier** : fleet/profiles/embedded.yaml (l.9, l.22)
**Detail** : embedded.yaml declare les roles `builder` et `deployer`, mais aucun fichier n'existe dans fleet/system-prompt/sources/roles/ pour ces deux roles. Le build-sp.sh tente de lire `sources/roles/builder.md` et `sources/roles/deployer.md` — fichiers absents. Ces agents seront deployes sans section role dans leur system-prompt. De plus, ces deux roles n'ont pas de bloc `system_prompt:` dans embedded.yaml, donc build-sp.sh ne sait pas quel contenu injecter au-dela du role.
**Fix propose** : Creer `roles/builder.md` et `roles/deployer.md` avec scope, interdictions, et perimetre. Ajouter les blocs `system_prompt:` dans embedded.yaml.

---

### REF-04 (HIGH) : Contradiction scope Engineer — "maintenance LCARS" interdit dans topologie vs implicitement autorise dans son role

**Fichier** : fleet/system-prompt/sources/organisation/topologie.md (l.55), fleet/system-prompt/sources/roles/engineer.md (l.12, l.18)
**Detail** : topologie.md dit explicitement "INTERDIT : code projet, push projet, maintenance LCARS". Mais engineer.md dit "Maintient LCARS-fleet (L4 R)" et son scope autorise inclut "deploy, drift audit". La matrice des scopes (topologie.md l.85) donne a Engineer "L4 R, deploy, drift audit" mais interdit "push LCARS". L'ambiguite est sur "maintenance LCARS" — topologie dit INTERDIT, le role dit "Maintient LCARS-fleet".
**Fix propose** : Clarifier dans topologie.md : "INTERDIT : maintenance LCARS (modifications/push)" au lieu de juste "maintenance LCARS". Engineer maintient l'etat operationnel (deploy, drift audit) sans modifier le code.

---

### REF-05 (HIGH) : StarFleet scope "interaction user directe" interdit — contredit par la realite operationnelle

**Fichier** : fleet/system-prompt/sources/organisation/topologie.md (l.30), fleet/system-prompt/sources/roles/starfleet.md (l.16, l.20)
**Detail** : topologie.md et starfleet.md disent "INTERDIT : input user direct sur L1". Mais starfleet.md l.16 precise "l'interlocuteur user est architect" et le role a le protocole complet injecte (fleet.yaml l.23 inclut `protocole`). Le mot-cle `yop` de reprise de session, les commandes slash, etc. sont des interactions user directes. L'interdiction porte sur "input user direct sur L1" (code projet), pas sur "interaction user" tout court — mais la formulation "Scope interdit : interaction user directe" (starfleet.md l.20) est trop large.
**Fix propose** : Reformuler dans starfleet.md : "Scope interdit : code applicatif, instructions user sur code projet (L1)" pour distinguer clairement l'interaction de supervision (autorisee) de l'interaction sur le code projet (interdite).

---

### REF-06 (MEDIUM) : Non-recouvrement — "Read avant Write" dit dans 2 fichiers avec des mots differents

**Fichier** : fleet/system-prompt/sources/core/#5_edition.md (l.15-16), fleet/system-prompt/sources/organisation/workflow.md (l.12-16)
**Detail** : #5_edition.md pose la regle "Read avant Write" (CRITICAL). workflow.md ajoute des exceptions a cette regle (l.12-16). C'est un cas bordure : workflow.md ne repete pas la regle mais la modifie avec des exceptions. L'axiome de non-recouvrement est respecte en intention, mais un agent voit la regle dans deux fichiers avec des nuances differentes.
**Fix propose** : Acceptable en l'etat — workflow.md reference explicitement "core/#5_edition" et ne formule que les exceptions. Pas de violation stricte, mais noter que la regle vit en 2 endroits.

---

### REF-07 (MEDIUM) : Non-recouvrement — "Architect INTERDIT implementer" repete dans 3 fichiers

**Fichier** : core/#3_perimetre.md (l.15), organisation/topologie.md (l.32), roles/architect.md (l.12-14)
**Detail** : La regle "Architect ne code pas" est formulee dans perimetre.md ("Architect INTERDIT implementer"), dans topologie.md ("INTERDIT : implementer. Le travail d'architect s'arrete au plan"), et dans architect.md ("JAMAIS ecrire de code. JAMAIS creer de fichier source. JAMAIS implementer."). Trois formulations differentes de la meme regle = violation de l'axiome de non-recouvrement.
**Fix propose** : Garder la regle detaillee dans le fichier role (architect.md) comme seul endroit. Dans perimetre.md et topologie.md, ne mentionner que la reference au scope sans reformuler l'interdiction.

---

### REF-08 (MEDIUM) : Non-recouvrement — "JAMAIS push direct" / "push LCARS interdit" en 3+ endroits

**Fichier** : organisation/topologie.md (l.85, l.155-157), organisation/infrastructure.md (l.150, l.154-158), roles/dev.md (l.20), roles/engineer.md (l.16)
**Detail** : La regle de qui peut pusher ou est formulee dans la matrice des scopes (topologie.md), dans "Push par role" (infrastructure.md), et dans chaque fichier role concerne. L'information est coherente mais repetee avec des mots differents dans au moins 4 fichiers.
**Fix propose** : Definir "Push par role" une seule fois dans infrastructure.md (ou topologie.md). Les roles ne doivent declarer que "Scope interdit : push" sans re-enumerer les cas.

---

### REF-09 (MEDIUM) : "Non-wakeable" dans topologie mais architect.yaml dit wakeable: false — terminologie mixte

**Fichier** : fleet/system-prompt/sources/organisation/topologie.md (l.32), fleet/profiles/projects.yaml (l.17)
**Detail** : topologie.md utilise "Non-wakeable" pour architect. Le profile projects.yaml utilise `wakeable: false`. Ce sont deux manieres de dire la meme chose, mais le terme "Non-wakeable" n'est pas defini dans les directives. Il faut lire le profile YAML pour comprendre que ca signifie "pas de wake IPC possible".
**Fix propose** : Ajouter une definition explicite de "wakeable" dans topologie.md (section agents interactifs).

---

### REF-10 (MEDIUM) : Consultant dans la matrice fleet-plan (workflow.md) mais pas dans les profiles fleet ou projects

**Fichier** : fleet/system-prompt/sources/organisation/workflow.md (l.91), fleet/profiles/fleet.yaml, fleet/profiles/projects.yaml
**Detail** : La matrice agent x commande dans workflow.md inclut "Consultant" avec acces a `check` et `list`. Le consultant est declare dans fleet.yaml (profile fleet). Pas de contradiction a proprement parler, mais la matrice melange des agents de profiles differents sans le signaler.
**Fix propose** : Ajouter une note dans la matrice indiquant le profile d'appartenance de chaque agent, ou documenter que la matrice couvre tous les profiles.

---

### REF-11 (MEDIUM) : Dev role.md — "INTERDIT : compiler" vs scope "build" dans topologie

**Fichier** : fleet/system-prompt/sources/roles/dev.md (l.14), fleet/system-prompt/sources/organisation/topologie.md (l.94)
**Detail** : dev.md dit "INTERDIT : modifier LCARS, compiler, gerer le toolkit." Mais le scope `code` dans la matrice des scopes (topologie.md l.93) n'inclut pas et n'exclut pas explicitement la compilation. Le scope `build` (l.94) est un scope distinct. La coherence est presente (dev n'a pas scope build), mais l'interdiction "compiler" dans le role ne mappe pas explicitement a un scope.
**Fix propose** : Acceptable — le role est plus precis que le scope. Pas de conflit reel.

---

### REF-12 (MEDIUM) : Reviewer role header non conforme — manque `derived_from` et utilise un format different

**Fichier** : fleet/system-prompt/sources/roles/reviewer.md (l.1-7)
**Detail** : Le header HTML du reviewer utilise `title: reviewer role` (minuscule, pas "Role — reviewer" comme les autres). Le champ `derived_from` est absent (present dans tous les autres roles). Le champ `date` est 2026-03-17 alors que tous les autres sont 2026-03-22.
**Fix propose** : Uniformiser le header avec le format des autres roles : `title: Role — reviewer`, ajouter `derived_from: —`.

---

### REF-13 (MEDIUM) : Quality agent — scope `test` dans le profile mais description mentionne "GO-7 compliance"

**Fichier** : fleet/profiles/fleet.yaml (l.43), fleet/system-prompt/sources/roles/quality.md (l.12)
**Detail** : Le profile declare quality avec scope `test`. Le role dit "Verification GO-7 compliance, validation hooks, skills, coherence directives". La verification de coherence de directives ressemble plus au scope `analysis` qu'a `test`. Le scope `test` dans la matrice (topologie.md l.95) autorise "execution tests, rapports PASS/FAIL" et "L1 R + W rapports". Quality opere sur L4, pas L1 — le scope `test` est defini avec "L1 R + W rapports" mais quality travaille sur L4.
**Fix propose** : Considerer un scope dedie `test-L4` ou clarifier dans la matrice que le scope `test` s'applique aussi a L4 quand l'agent est de type LCARS.

---

### REF-14 (MEDIUM) : Engineer profile — pas de `organisation/infrastructure` dans system_prompt

**Fichier** : fleet/profiles/projects.yaml (l.46-49)
**Detail** : Engineer recoit `core`, `topologie`, et `workflow` mais PAS `infrastructure`. L'engineer est cense deployer (`deploy` dans son scope) et utiliser les scripts fleet (fleet-send, fleet-plan, fleet-dispatch). Toutes les refs a ces scripts, les chemins systeme, la structure IPC, les permissions, le triangle git — tout est dans infrastructure.md. Sans ce fichier, engineer manque le contexte operationnel de ses propres outils.
**Fix propose** : Ajouter `organisation/infrastructure` dans le system_prompt de engineer dans projects.yaml.

---

### REF-15 (MEDIUM) : Dev profile — pas de `organisation/topologie` ni `organisation/infrastructure` dans system_prompt

**Fichier** : fleet/profiles/projects.yaml (l.64-67)
**Detail** : Dev recoit `core` et `workflow` seulement. Il n'a pas topologie (normal — Tier 2 projet ne voit pas L3 selon la matrice Knowledge x Tier). Mais dev n'a pas non plus infrastructure — ce qui signifie qu'il ne connait pas les chemins systeme, la structure du repo LCARS, les regles IPC (GO-5), le triangle git strict. La regle est coherente avec la matrice (Tier 2 = pas de L3), mais dev utilise `fleet-send.sh` (role l.16) sans avoir le contexte IPC.
**Fix propose** : Verifier si l'injection minimale de la section IPC est necessaire pour dev, ou si le SP anthropic-lcars couvre les bases. Sinon, considerer un extrait infrastructure minimal.

---

### REF-16 (MEDIUM) : Protocole utilise des emojis pour les niveaux (niv.) — MEMORY.md dit "User hates emojis"

**Fichier** : directives/protocole.md (l.51 et tout le fichier)
**Detail** : La colonne `niv.` utilise des emojis pour coder les niveaux. MEMORY.md note que l'user n'aime pas les emojis. Ceci dit, ces emojis sont des marqueurs techniques dans un fichier de reference, pas de la conversation — c'est un choix de design du protocole, pas un probleme de conformite.
**Fix propose** : LOW priority — remplacer les emojis par des marqueurs texte (S/M/L ou 1/2/3) si l'user le souhaite, mais fonctionnellement neutre.

---

### REF-17 (LOW) : fleet-system.yaml reference `fleet.yaml` comme "artefact genere" mais fleet.yaml n'est pas genere dans le profile fleet

**Fichier** : fleet/system-prompt/sources/organisation/infrastructure.md (l.23-24)
**Detail** : Infrastructure.md declare `/home/projects/LCARS/fleet/fleet-system.yaml` comme "Source de verite topologique. Editee a la main" et `/home/projects/LCARS/fleet/fleet.yaml` comme "Artefact genere par fleet-build-yaml.sh". Mais dans le repo, fleet.yaml n'existe pas en tant qu'artefact genere au chemin `/home/projects/LCARS/fleet/fleet.yaml` — les fichiers YAML de profiles sont dans `fleet/profiles/`. Le `fleet.yaml` mentionne dans le code est le resultat de `fleet-build-yaml.sh` a `/local/LCARS/fleet/fleet.yaml` (runtime), pas dans le working copy.
**Fix propose** : Clarifier dans infrastructure.md que fleet.yaml est genere dans le runtime `/local/LCARS/`, pas dans le working copy.

---

### REF-18 (LOW) : `side quest:` cree dans `work/doing/` (protocole) mais workflow definit `TODO/` -> `doing/` -> `done/`

**Fichier** : directives/protocole.md (l.330), fleet/system-prompt/sources/organisation/workflow.md (l.53-55, l.60)
**Detail** : Le protocole dit que `side quest:` cree directement dans `work/doing/<slug>.md`. Mais le workflow definit un cycle `TODO -> doing -> done` avec transitions via `fleet-plan.sh` uniquement. Un side quest qui atterrit directement dans `doing/` bypasse le cycle de vie normal des plans. Ce n'est pas une contradiction stricte (le side quest est un raccourci delibere), mais c'est une exception non documentee au cycle `fleet-plan.sh`.
**Fix propose** : Documenter dans workflow.md que `side quest:` est une exception autorisee qui cree directement dans `doing/` sans passer par `TODO/`.

---

### REF-19 (LOW) : StarFleet profile `stateless: true` — surprenant pour un Tier 0 permanent

**Fichier** : fleet/profiles/fleet.yaml (l.14)
**Detail** : Le profile fleet.yaml declare starfleet avec `stateless: true`. Topologie.md (l.28) dit "Provisonnes au setup, JAMAIS instancies dynamiquement. TOUJOURS presents." pour Tier 0. `stateless: true` signifie pas de memory sync ni handoff persistant automatique — mais starfleet a les skills `handoff` et `harvest-emergency`. Le champ `stateless` dans le blueprint controle la persistance inter-session (topologie.md l.61). StarFleet avec stateless=true implique qu'il depend du handoff manuel uniquement. Pas une contradiction, mais un choix architectural a verifier.
**Fix propose** : Verifier si c'est intentionnel. Si oui, documenter pourquoi Tier 0 est stateless (le handoff skill suffit).

---

### REF-20 (LOW) : Matrice agent x commande (workflow.md) ne couvre pas quality, compliance, reviewer, researcher, documenter

**Fichier** : fleet/system-prompt/sources/organisation/workflow.md (l.85-91)
**Detail** : La matrice fleet-plan liste Architect, Engineer, Dev, StarFleet, Consultant. Les agents quality, compliance, reviewer, researcher, documenter ne sont pas dans la matrice. Quality et compliance sont invoques par fleet-plan.sh (compliance.md l.16), mais leur acces aux commandes n'est pas dans la matrice.
**Fix propose** : Completer la matrice avec tous les agents, ou documenter que seuls les agents listees interagissent avec fleet-plan.sh (les autres sont dispatches).

---

### REF-21 (LOW) : Drift source <-> deploye = aucun, mais direction de maintenance ambigue

**Fichier** : directives/protocole.md, fleet/system-prompt/sources/protocole.md
**Detail** : Les deux fichiers sont identiques (diff = 0). La direction de maintenance (axiomes.md l.19) dit "directives/ (source user) -> sources/ (assemblage fleet) -> SP deploye (runtime)". Le fichier sources/protocole.md n'a aucun header `derived_from: directives/protocole.md` — il est declare comme "source de verite primaire" dans son propre contenu. Question : lequel est la copie de l'autre ? Si directives/ est la source et sources/ l'assemblage, alors sources/protocole.md devrait avoir un `derived_from`.
**Fix propose** : Ajouter `derived_from: directives/protocole.md` dans le header HTML de sources/protocole.md, ou documenter explicitement que les deux sont maintenus en sync par copie.

---

## Resume

Les findings les plus impactants :

1/ **REF-01/02/03** — Dispersion des GO et roles manquants : les General Orders sont repartis sur 4 fichiers sans index central. builder/deployer n'ont pas de fichier role.

2/ **REF-04/05** — Contradictions de formulation sur les scopes Engineer et StarFleet : coherents en intention mais ambigus pour un LLM.

3/ **REF-07/08** — Non-recouvrement : "Architect ne code pas" et "push par role" repetes en 3+ endroits avec des mots differents. Violation directe de l'axiome fondamental.

4/ **REF-14** — Engineer manque `infrastructure.md` dans son system_prompt alors qu'il utilise quotidiennement les outils decrits dedans.

5/ **REF-13** — Quality avec scope `test` alors qu'il fait de l'analyse de conformite sur L4 — mapping scope imprecis.
