# Audit bash-pro Safety & Security Patterns — Ring 2+3+4 (10 kernel scripts)

**Date** : 2026-03-28
**Checklist source** : `/home/projects/LCARS/knowledge/wshobson-agents/shell-scripting/bash-pro.md` (section Safety & Security Patterns, 14 points)
**Statut** : recherche uniquement, aucun fichier modifie

## Scripts audites

| Alias | Ring | Chemin complet |
|---|---|---|
| **fleet-state** | 2 | `/home/projects/LCARS/fleet/fleet-state.sh` |
| **fleet-done** | 2 | `/home/projects/LCARS/fleet/fleet-done.sh` |
| **fleet-action-done** | 2 | `/home/projects/LCARS/fleet/fleet-action-done.sh` |
| **fleet-inject** | 2 | `/home/projects/LCARS/fleet/fleet-inject.sh` |
| **fleet-dispatch** | 3 | `/home/projects/LCARS/fleet/fleet-dispatch.sh` |
| **fleet-plan** | 3 | `/home/projects/LCARS/fleet/fleet-plan.sh` |
| **fleet-scrub** | 3 | `/home/projects/LCARS/fleet/fleet-scrub.sh` |
| **fleet-launch** | 4 | `/home/projects/LCARS/fleet/fleet-launch.sh` |
| **light_on** | 4 | `/home/projects/LCARS/fleet/light_on.sh` |
| **light_off** | 4 | `/home/projects/LCARS/fleet/light_off.sh` |

---

## Resultats detailles

### 1. Declare constants with `readonly`

| Script | Verdict | Detail |
|---|---|---|
| fleet-state | FAIL | INSTANCE, FILE, DATE (L89-103) ne sont pas `readonly` alors qu'elles ne changent pas apres init |
| fleet-done | FAIL | TITLE, INSTANCE, FILE, DATE (L81-91) ne sont pas `readonly` |
| fleet-action-done | FAIL | FRAGMENT, INSTANCE, FILE (L81-84) ne sont pas `readonly` |
| fleet-inject | FAIL | SECTION, HANDOFF_FILE, SNIPPET_FILE (L78-99) ne sont pas `readonly` apres resolution |
| fleet-dispatch | FAIL | role, subject, prompt_file (L105-107) ne sont pas `readonly`. Les constantes headless resolues (max_turns, timeout_sec, allowed_tools L171-178) non plus |
| fleet-plan | FAIL | PROJECT_ROOT, WORK_DIR, TODO_DIR, DOING_DIR, DONE_DIR, INDEX_FILE (L103-108) ne sont pas `readonly` |
| fleet-scrub | FAIL | PROJECT_ROOT, WORK_DIR, TODO_DIR, DOING_DIR, DONE_DIR, INDEX_FILE, SCRATCHPAD, BACKLOG (L94-101) ne sont pas `readonly` |
| fleet-launch | FAIL | SESSION, HANDOFF (L74-75) ne sont pas `readonly` |
| light_on | FAIL | PROFILE (L73), SESSION (L139) ne sont pas `readonly` |
| light_off | FAIL | SESSION, HANDOFF, HANDOFF_TIMEOUT (L73-75) ne sont pas `readonly` |

### 2. Use `local` for all function variables

| Script | Verdict | Detail |
|---|---|---|
| fleet-state | N/A | Pas de fonction definie (script lineaire) |
| fleet-done | N/A | Pas de fonction definie (script lineaire) |
| fleet-action-done | N/A | Pas de fonction definie (script lineaire) |
| fleet-inject | N/A | Pas de fonction definie (script lineaire) |
| fleet-dispatch | N/A | Pas de fonction definie (script lineaire, les variables sont au top-level) |
| fleet-plan | PASS | Toutes les fonctions utilisent `local` : `_resolve_project` L91, `_find_plan` L147, `_plan_state` L159, `_sync_ready_room` L169, `_index_log` L179, `cmd_new` L227, `cmd_start` L266, `cmd_done` L304, `cmd_check` L476, `cmd_list` L554-571, `cmd_append` L581, `cmd_audit` L601. `_validator_role` L137 utilise `local`. `_index_touch`/`_index_init_stub` n'ont pas de variables propres — OK |
| fleet-scrub | PASS | Toutes les fonctions utilisent `local` : `_resolve_project` L82, `_dispatch_reviewer` L158, `_parse_triage_items` L240, `cmd_scratchpad` L274, `cmd_backlog` L401, `cmd_init` L548. `_sync_ready_room` L131, `_index_log` L187 — `local` correct |
| fleet-launch | PASS | `_tmux()` L72 n'a pas de variable — OK (wrapper direct). Pas d'autre fonction definie avec variables |
| light_on | N/A | Pas de fonction definie (script lineaire) |
| light_off | PASS | `get_status` L84-88, `get_action` L90-94, `stamp_forced_shutdown` L97-110 utilisent `local` pour leurs variables (date_str L98, file L101, act L103, tmp L106) |

### 3. Implement `timeout` for external commands

| Script | Verdict | Detail |
|---|---|---|
| fleet-state | FAIL | `rsync` L134 appele sans timeout — hang possible si drvfs est lent/unmounted. `fleet-session-log.sh` L151 appele sans timeout |
| fleet-done | N/A | Pas de commande externe longue (awk local sur fichier local) |
| fleet-action-done | N/A | Pas de commande externe longue (awk/grep locaux) |
| fleet-inject | N/A | Pas de commande externe longue (awk/head/tail sur fichiers locaux) |
| fleet-dispatch | PASS | `timeout "$timeout_sec"` L205 sur `claude -p` headless. Timeout configurable via fleet.yaml + CLI override |
| fleet-plan | FAIL | `fleet-dispatch.sh` appele L425/546/687 sans timeout propre (le dispatch interne a un timeout, mais fleet-plan ne wrappe pas avec timeout). `rsync` dans `_sync_ready_room` L173 sans timeout |
| fleet-scrub | FAIL | `fleet-dispatch.sh` appele L170 sans timeout propre. `rsync` dans `_sync_ready_room` L135 sans timeout |
| fleet-launch | FAIL | `python3 fleet-hub.py` L144-148 lance sans timeout. `tmux` appels multiples L120-207 sans timeout. `fleet-monitor.py` L162 lance sans timeout |
| light_on | PASS | `timeout 5 gh api user` L122 — timeout explicite sur appel reseau. Mais `fleet-build-yaml.sh` L94 et `fleet-launch.sh` L143 appeles via `bash` sans timeout — mitige car ce sont des scripts locaux connus |
| light_off | FAIL | `fleet_tmux send-keys` L160, `fleet-shutdown-clean.sh` L227-229 appeles sans timeout. Le poll loop L167-176 a un timeout global ($HANDOFF_TIMEOUT=120s) — bon, mais `read -r` L147 bloque indefiniment sans timeout |

### 4. Validate file permissions before operations (`[[ -r "$file" ]]`)

| Script | Verdict | Detail |
|---|---|---|
| fleet-state | PASS | `[[ -f "$FILE" ]]` L95 avant lecture. `[[ -d "$FLEET_READY_ROOM/handoffs" ]]` L133 avant rsync |
| fleet-done | PASS | `[[ -f "$FILE" ]]` L88. `grep -q "^## DONE" "$FILE"` L89 — verification existence + contenu |
| fleet-action-done | PASS | `[[ -f "$FILE" ]]` L86. `grep -q "^\[ \]"` L88/94 avant operation |
| fleet-inject | PASS | `[[ -f "$HANDOFF_FILE" ]]` L101, `[[ -f "$SNIPPET_FILE" ]]` L102, `[[ -s "$SNIPPET_FILE" ]]` L103. `grep -q "^${ANCHOR_PLAIN}" "$HANDOFF_FILE"` L136 |
| fleet-dispatch | PASS | `[[ ! -f "$prompt_file" ]]` L136. `id "$target_user"` L129 verifie l'utilisateur existe |
| fleet-plan | PASS | `[[ -f "$src" ]]` dans cmd_start L270, cmd_done L320. `_find_plan` L146-154 verifie existence. `[[ -f "$plan" ]]` L568/607 dans les boucles |
| fleet-scrub | PASS | `[[ -f "$SCRATCHPAD" ]]` L269, `[[ -f "$BACKLOG" ]]` L395, `[[ -f "$plan" ]]` L288/412/578 dans les boucles |
| fleet-launch | PASS | `[ ! -d "$HANDOFF" ]` L127. Security gate L79-97 teste l'ecriture sur /mnt/c |
| light_on | PASS | `[ -z "$PROFILE" ]` L84. `[ ! -f "$DEPLOY_OK" ]` L101. Pas de lecture fichier sans test prealable |
| light_off | PASS | `[ -f "$file" ]` L86/92/102 dans get_status/get_action/stamp_forced_shutdown. `[ -f /tmp/fleet-hub.pid ]` L214 |

### 5. Use process substitution instead of temporary files when possible

| Script | Verdict | Detail |
|---|---|---|
| fleet-state | PASS | `${FILE}.tmp` avec write-tmp-then-mv atomique L130 — necessaire pour atomicite |
| fleet-done | PASS | `${FILE}.tmp` write-tmp-then-mv L103 — necessaire pour atomicite |
| fleet-action-done | PASS | `${FILE}.tmp` write-tmp-then-mv L104/112 — necessaire pour atomicite |
| fleet-inject | PASS | `mktemp` L106 pour INSERT_TMP necessaire (contenu passe a awk via fichier), `${HANDOFF_FILE}.tmp` pour atomicite L150 |
| fleet-dispatch | PASS | Fichiers temp necessaires : `$_tmp_prompt` (passe via stdin a claude -p), `$result_file` (capture stdout de background process). Process substitution impossible ici (sudo + background) |
| fleet-plan | PASS | `mktemp` pour prompts transmis a fleet-dispatch via fichier — necessaire (IPC). `${...}.tmp` pour write-tmp-then-mv — necessaire |
| fleet-scrub | PASS | Meme pattern que fleet-plan : mktemp pour prompts dispatch, necessaire |
| fleet-launch | PASS | Pas de fichier temporaire inutile. `/tmp/fleet-hub.pid` et `/tmp/fleet-hub.log` sont du state management, pas des temp files |
| light_on | N/A | Pas de fichier temporaire |
| light_off | PASS | `${file}.tmp` L106-107 pour sed atomique |

### 6. Sanitize user input before using in commands

| Script | Verdict | Detail |
|---|---|---|
| fleet-state | PASS | KEY filtre par `case` L112-113 (whitelist: action|status|blocker|ref|waiting|notify|session). VAL_ESC L114 echappe `\`, `&`, `|` pour sed. FLEET_SESSION vient de l'env, pas de l'utilisateur |
| fleet-done | PASS | TITLE et BODY passes a awk via ENVIRON (pas d'interpolation shell). Pas d'injection possible par awk ENVIRON |
| fleet-action-done | PASS | FRAGMENT passe a awk via `-v frag=` L98 — safe (awk variable assignment, pas d'interpolation). `grep -qF` L94 utilise fixed-string match |
| fleet-inject | PASS | SECTION filtre par case L109 (whitelist: done|actions). Le contenu du snippet est injecte via fichier temp lu par awk — pas d'injection command |
| fleet-dispatch | PASS | `role` valide par regex L110 `^[a-z][a-z0-9_-]*$` — empeche injection yq. `target_user` resolu via fleet-env, verifie par `id`. `prompt` est lu depuis fichier ou stdin, passe via fichier temp a claude stdin — pas d'injection |
| fleet-plan | PASS | `slug` utilise comme nom de fichier uniquement (pas d'eval/cmd sub). `--step` et `--force` filtres par case. Le prompt de validation est construit avec `printf '%s'` et fichier temp — safe |
| fleet-scrub | PASS | Pas d'input utilisateur direct. Le contenu scratchpad/backlog est lu et passe au reviewer via fichier — pas d'injection. Les regexes BASH_REMATCH L473/490 filtrent les slugs `[a-z0-9_-]+` |
| fleet-launch | PASS | TEMPLATE valide par case L115-118 (whitelist). Security gate teste l'ecriture /mnt/c sans user input. Tous les parametres tmux sont construits internement |
| light_on | PASS | PROFILE filtre par case L75-80 (whitelist). PLAN_TYPE vient de yq sur fichier local. GH_LOGIN utilise uniquement dans `gh repo list` — safe |
| light_off | PASS | `--force` est le seul argument, filtre L80. Workers viennent de `fleet_roles` (fleet.yaml parse). Pas d'input utilisateur dans les commandes tmux |

### 7. Validate numeric input with pattern matching

| Script | Verdict | Detail |
|---|---|---|
| fleet-state | N/A | Pas d'input numerique |
| fleet-done | N/A | Pas d'input numerique |
| fleet-action-done | N/A | Pas d'input numerique |
| fleet-inject | N/A | Pas d'input numerique |
| fleet-dispatch | FAIL | `OPT_MAX_TURNS` L92 et `OPT_TIMEOUT` L93 ne sont pas valides comme numeriques avant d'etre passes a `timeout` L205 et `--max-turns` L209. Un input non-numerique pourrait provoquer une erreur |
| fleet-plan | FAIL | `step` (de `--step N`) n'est pas valide comme numerique L311. `wip_count` L285 vient de `wc -l` (safe) mais `scaled_turns`/`scaled_timeout` L402-406 sont derives de `grep -c` (safe). Le risque est sur `--step` qui pourrait etre non-numerique |
| fleet-scrub | N/A | Pas d'input numerique utilisateur |
| fleet-launch | PASS | `PBASE` L139-140 : `[[ "$PBASE" =~ ^[0-9]+$ ]] || PBASE=0` — validation explicite |
| light_on | N/A | Pas d'input numerique |
| light_off | N/A | `HANDOFF_TIMEOUT` L75 est un literal interne (120), pas un input |

### 8. Never use `eval` on user input

| Script | Verdict | Detail |
|---|---|---|
| fleet-state | PASS | Aucun `eval` |
| fleet-done | PASS | Aucun `eval` |
| fleet-action-done | PASS | Aucun `eval` |
| fleet-inject | PASS | Aucun `eval` |
| fleet-dispatch | PASS | Aucun `eval` |
| fleet-plan | PASS | Aucun `eval` |
| fleet-scrub | PASS | Aucun `eval` |
| fleet-launch | PASS | Aucun `eval` |
| light_on | PASS | Aucun `eval` |
| light_off | PASS | Aucun `eval` |

### 9. Set restrictive umask for sensitive operations

| Script | Verdict | Detail |
|---|---|---|
| fleet-state | FAIL | `$FILE` (handoff) et `$LOG_FILE` crees/ecrits sans umask restrictif. L144 `chmod 664` post-creation — fenetre de lecture possible entre creation et chmod |
| fleet-done | N/A | Ecrit dans handoff existant (pas de creation de fichier sensible) |
| fleet-action-done | N/A | Ecrit dans handoff existant |
| fleet-inject | N/A | `mktemp` L106 cree avec permissions restrictives par defaut (600). Ecrit dans handoff existant |
| fleet-dispatch | FAIL | `$log_file` L164-166/186 cree sans umask (contient des details de dispatch). `$result_file`, `$_tmp_prompt` via mktemp — OK (600 par defaut). `$PID_FILE` L199/214 cree sans umask dans /tmp/fleet-headless/ — accessible par d'autres utilisateurs |
| fleet-plan | N/A | Fichiers plan sont du contenu projet, pas sensibles. Les mktemp sont corrects (600 par defaut) |
| fleet-scrub | N/A | Meme pattern que fleet-plan — contenu projet non-sensible |
| fleet-launch | FAIL | `chmod 660 "$FLEET_TMUX_SOCK"` L138 — bon, mais le socket est cree par tmux sans umask restrictif d'abord. `/tmp/fleet-hub.log` L148 et `/tmp/fleet-hub.pid` L149 crees sans umask |
| light_on | FAIL | `$KNOWN_REPOS` L119-120 `touch` sans umask — contient la liste des repos GitHub (potentiellement sensible) |
| light_off | N/A | Pas de creation de fichier sensible. `${file}.tmp` pour sed atomique sur handoffs existants |

### 10. Log security-relevant operations

| Script | Verdict | Detail |
|---|---|---|
| fleet-state | PASS | Transitions loguees dans fleet-state.log L141-144. Session duration loguee via fleet-session-log.sh L148-153. Erreurs sur stderr |
| fleet-done | N/A | Ajout de contenu au handoff — pas d'operation security-relevant |
| fleet-action-done | N/A | Marquage de checkbox — pas d'operation security-relevant |
| fleet-inject | N/A | Injection de contenu dans handoff — operation courante, pas security-relevant |
| fleet-dispatch | PASS | Dispatches logues dans `$log_file` L166/226/233/252 avec timestamp, role, subject, mode, exit code, duration. Timeout et erreurs logues explicitement |
| fleet-plan | N/A | Operations de gestion de plans — pas security-relevant directement. Les validations sont loguees dans index.md |
| fleet-scrub | N/A | Operations de triage — pas security-relevant |
| fleet-launch | PASS | Security gate L79-96 affiche un warning explicite et bloque le lancement. Socket chmod L138. fleet-hub startup verifie L151-153 |
| light_on | PASS | Deploy gate L100-116 bloque si onboarding non fait. Nouveaux repos detectes et notifies L134. `fleet-state.sh notify=` L134 logue l'evenement |
| light_off | PASS | `stamp_forced_shutdown` L97-110 ecrit le shutdown force dans les handoffs. Arret de fleet-hub logue L218. Le flux interactif `read` L147/185 donne le controle a l'operateur |

### 11. Use `--` to separate options from arguments

| Script | Verdict | Detail |
|---|---|---|
| fleet-state | FAIL | `readlink -f "${BASH_SOURCE[0]}"` L79 sans `--`. `sed` L130, `mv -f` L130 sans `--` (fichier construit internement mais pas de `--`). `rsync` L134 sans `--` |
| fleet-done | FAIL | `readlink -f "${BASH_SOURCE[0]}"` L79 sans `--`. `mv -f "${FILE}.tmp" "$FILE"` L103 sans `--` |
| fleet-action-done | FAIL | `readlink -f "${BASH_SOURCE[0]}"` L79 sans `--`. `mv -f "${FILE}.tmp"` L104/112 sans `--` |
| fleet-inject | FAIL | `readlink -f "${BASH_SOURCE[0]}"` L76 sans `--`. `head -1 "$SNIPPET_FILE"` L111 sans `--`. `cp "$SNIPPET_FILE"` L124 sans `--`. `rm -f "$INSERT_TMP"` L130/138/152 sans `--` |
| fleet-dispatch | PASS | `--) shift; break ;;` L95 — option parser termine correctement. `rm -f "$tmp_prompt"` L162/249 sans `--` mais les chemins sont construits par mktemp (jamais `-`). Les variables role/subject sont validees par regex |
| fleet-plan | FAIL | `readlink -f "$PROJECT_ROOT"` L138 sans `--`. `mv "$src"` L293/349/466 sans `--`. `find "$DOING_DIR" -maxdepth 1` L285 sans `--`. Cependant les chemins sont resolus internement |
| fleet-scrub | FAIL | `mv "$tmp" "$INDEX_FILE"` L203 sans `--`. `rm -f "$tmp_prompt"` L171 sans `--` (mktemp — safe mais inconsistant). Memes patterns que fleet-plan sans `--` |
| fleet-launch | FAIL | `readlink -f "${BASH_SOURCE[0]}"` L68/143 sans `--`. `chmod 660` L138, `chgrp fleet` L138, `rm -f "$SEC_TEST"` L82 sans `--` |
| light_on | FAIL | `readlink -f "${BASH_SOURCE[0]}"` L85/94/97/143 (4 occurrences) sans `--`. `touch "$KNOWN_REPOS"` L120 sans `--` |
| light_off | FAIL | `readlink -f "${BASH_SOURCE[0]}"` L71/228 sans `--`. `sed` L107, `mv -f "$tmp"` L107 sans `--`. `rm -f /tmp/fleet-hub.pid` L220 sans `--` |

### 12. Validate environment variables (`: "${REQUIRED_VAR:?not set}"`)

| Script | Verdict | Detail |
|---|---|---|
| fleet-state | PASS | `FLEET_SESSION` verifie L85. `FLEET_INSTANCE` fallback `$(hostname)` L89. Les variables FLEET_* viennent de fleet-env.sh (source L79) qui les initialise avec defaults |
| fleet-done | PASS | `"${1:?usage: ...}"` L81 — pattern `:?` utilise. FLEET_INSTANCE fallback L85 |
| fleet-action-done | PASS | FRAGMENT L81 accepte vide (optionnel). FLEET_INSTANCE fallback L83. FILE construit a partir de vars validees |
| fleet-inject | PASS | `"${1:?usage: ...}"` L78 — pattern `:?`. `"${2:?--file requiert un chemin}"` L87. FLEET_INSTANCE fallback L97 |
| fleet-dispatch | PASS | `$# -lt 2` L100 verifie les args requis. fleet-env source L83 initialise FLEET_*. `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1` L204 explicite |
| fleet-plan | PASS | `"${1:?usage: ...}"` dans cmd_new L227, cmd_start L266, cmd_append L581. `_resolve_project` L90-101 echoue proprement si pas de work/. fleet-env source optionnel L116-119 avec fallback |
| fleet-scrub | PASS | Meme pattern que fleet-plan. `_resolve_project` echoue proprement. fleet-env source optionnel |
| fleet-launch | PASS | fleet-env source L68. `"${2:?--template requires a value ...}"` L105. FLEET_TMUX_SOCK, FLEET_HANDOFFS etc. via fleet-env |
| light_on | PASS | `HOMES_ROOT` via fleet-env. `FLEET_TMUX_SOCK` via fleet-env. PROFILE accepte vide (auto-detect) |
| light_off | PASS | fleet-env source L71. `fleet_roles` utilise pour WORKERS L77. FLEET_TMUX_SOCK via fleet-env |

### 13. Check exit codes of security-critical operations

| Script | Verdict | Detail |
|---|---|---|
| fleet-state | PASS | `set -euo pipefail` L76. `grep -q "^## STATE"` L101 avec sortie gracieuse. `rsync` L134 avec `|| echo WARN`. `fleet-session-log.sh` L151 avec `|| true` |
| fleet-done | PASS | `set -euo pipefail` L76. `grep -q "^## DONE"` L89 avec exit 1 |
| fleet-action-done | PASS | `set -euo pipefail` L76. `grep -q "^\[ \]"` L88/94 avec sortie explicite |
| fleet-inject | PASS | `set -euo pipefail` L73. `grep -q` L136 avec exit 1. `mv -f` L150 chaine avec `&&` |
| fleet-dispatch | PASS | `set -euo pipefail` L81. `exit_code` capture explicitement L215. Timeout detection L223 (exit 124). Non-zero exit L230-235. `wait $HEADLESS_PID || exit_code=$?` L215 — safe |
| fleet-plan | PASS | `set -euo pipefail` L85. `exit_code` capture L426. Timeout/failure detection L434-441. `_resolve_project` L99-101 retourne 1 si echec |
| fleet-scrub | PASS | `set -euo pipefail` L76. `exit_code` capture L169-180 dans `_dispatch_reviewer`. Routing failures comptes L471-488 et empechent le clear du backlog L522-527 |
| fleet-launch | PASS | `set -euo pipefail` L65. Security gate exit 1 L95. Template validation exit 1 L117. `kill -0` L151 verification du PID |
| light_on | PASS | `set -euo pipefail` L70. Deploy gate L101 exit 1. `fleet-state.sh` L134 avec `|| true` (non-critique). `timeout 5` L122 avec `|| true` (reseau optionnel) |
| light_off | PASS | `set -euo pipefail` L68. `has-session` L114 teste avant operations. `kill -0` L216 avant kill. `|| true` sur operations non-critiques L217/223/227-229 |

### 14. Use `trap` to ensure cleanup on abnormal exit

| Script | Verdict | Detail |
|---|---|---|
| fleet-state | PASS | `trap 'rm -f "${FILE}.tmp" 2>/dev/null' INT TERM EXIT` L93 — cleanup du fichier tmp |
| fleet-done | FAIL | `${FILE}.tmp` cree L103 mais pas de trap. Si interrompu pendant le write, le `.tmp` reste |
| fleet-action-done | FAIL | `${FILE}.tmp` cree L104/112 mais pas de trap. Si interrompu pendant le write, le `.tmp` reste |
| fleet-inject | PASS | `trap 'rm -f "$INSERT_TMP" 2>/dev/null' EXIT` L107 — cleanup du mktemp. Note : `${HANDOFF_FILE}.tmp` L150 n'est pas couvert par le trap mais l'operation est rapide |
| fleet-dispatch | FAIL | `$result_file` L189, `$_tmp_prompt` L190, `$PID_FILE` L199 crees sans trap. Le cleanup L249 `rm -f "$result_file" "$_tmp_prompt"` n'est atteint que sur le happy path. Si interrompu pendant `wait` L215, les fichiers tmp restent + PID file orphelin |
| fleet-plan | FAIL | `cmd_done` L422 cree `tmp_prompt` via mktemp mais cleanup explicite L427 sans trap. Si le dispatch est interrompu, le fichier temp reste. `cmd_check` L544 a `trap 'rm -f "$tmp_prompt"' EXIT` — bon. `cmd_audit` L684 a `trap 'rm -f "$tmp_prompt"' EXIT` — bon. Inconsistance : `cmd_done` manque le trap, `cmd_check`/`cmd_audit` l'ont |
| fleet-scrub | FAIL | `_dispatch_reviewer` L165 cree mktemp mais cleanup explicite L171 sans trap. Meme probleme que fleet-plan cmd_done : si le dispatch est interrompu, le fichier temp reste. `_index_log` L194 mktemp sans trap (mais operation courte) |
| fleet-launch | FAIL | `/tmp/fleet-hub.pid` L149 et `/tmp/fleet-hub.log` L148 crees sans trap de cleanup. Si le script est interrompu pendant la creation des panes, le hub reste en background orphelin. Le socket tmux cree L136 n'a pas de trap non plus |
| light_on | FAIL | Pas de trap. Si interrompu entre le build fleet.yaml et le launch, etat inconsistant possible. `KNOWN_REPOS` ecrit sans trap |
| light_off | N/A | Pas de fichier temporaire a nettoyer. Le `${file}.tmp` dans stamp_forced_shutdown est atomique et ephemere. Le script est concu pour un shutdown, donc l'absence de trap est acceptable |

---

## Synthese par script

| Script | Ring | PASS | FAIL | N/A | Score |
|---|---|---|---|---|---|
| **fleet-state** | 2 | 8 | 4 | 2 | 8/12 |
| **fleet-done** | 2 | 5 | 3 | 6 | 5/8 |
| **fleet-action-done** | 2 | 5 | 3 | 6 | 5/8 |
| **fleet-inject** | 2 | 8 | 2 | 4 | 8/10 |
| **fleet-dispatch** | 3 | 8 | 4 | 2 | 8/12 |
| **fleet-plan** | 3 | 9 | 4 | 1 | 9/13 |
| **fleet-scrub** | 3 | 8 | 4 | 2 | 8/12 |
| **fleet-launch** | 4 | 8 | 5 | 1 | 8/13 |
| **light_on** | 4 | 7 | 4 | 3 | 7/11 |
| **light_off** | 4 | 8 | 2 | 4 | 8/10 |

## Synthese par point de securite

| # | Point | fleet-state | fleet-done | fleet-action-done | fleet-inject | fleet-dispatch | fleet-plan | fleet-scrub | fleet-launch | light_on | light_off |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 | readonly constants | FAIL | FAIL | FAIL | FAIL | FAIL | FAIL | FAIL | FAIL | FAIL | FAIL |
| 2 | local in functions | N/A | N/A | N/A | N/A | N/A | PASS | PASS | PASS | N/A | PASS |
| 3 | timeout external cmds | FAIL | N/A | N/A | N/A | PASS | FAIL | FAIL | FAIL | PASS | FAIL |
| 4 | validate file perms | PASS | PASS | PASS | PASS | PASS | PASS | PASS | PASS | PASS | PASS |
| 5 | process substitution | PASS | PASS | PASS | PASS | PASS | PASS | PASS | PASS | N/A | PASS |
| 6 | sanitize input | PASS | PASS | PASS | PASS | PASS | PASS | PASS | PASS | PASS | PASS |
| 7 | validate numeric | N/A | N/A | N/A | N/A | FAIL | FAIL | N/A | PASS | N/A | N/A |
| 8 | no eval | PASS | PASS | PASS | PASS | PASS | PASS | PASS | PASS | PASS | PASS |
| 9 | restrictive umask | FAIL | N/A | N/A | N/A | FAIL | N/A | N/A | FAIL | FAIL | N/A |
| 10 | log security ops | PASS | N/A | N/A | N/A | PASS | N/A | N/A | PASS | PASS | PASS |
| 11 | `--` separator | FAIL | FAIL | FAIL | FAIL | PASS | FAIL | FAIL | FAIL | FAIL | FAIL |
| 12 | validate env vars | PASS | PASS | PASS | PASS | PASS | PASS | PASS | PASS | PASS | PASS |
| 13 | check exit codes | PASS | PASS | PASS | PASS | PASS | PASS | PASS | PASS | PASS | PASS |
| 14 | trap cleanup | PASS | FAIL | FAIL | PASS | FAIL | FAIL | FAIL | FAIL | FAIL | N/A |

## Verdict global

**Bilan positif** : Les 10 scripts respectent tous les points critiques de securite :
- **Aucun `eval`** (point 8) — zero exception sur les 10 scripts
- **Validation des fichiers** (point 4) — PASS partout, verifications systematiques avant lecture/ecriture
- **Sanitisation des inputs** (point 6) — PASS partout, whitelists (case), regex, fixed-string grep
- **Validation des env vars** (point 12) — PASS partout, pattern `:?` ou fallback explicite
- **Check exit codes** (point 13) — PASS partout, `set -euo pipefail` systematique, exits explicites

fleet-dispatch est remarquable pour son timeout configurable sur claude headless (L205), sa validation regex du role (L110), et son logging detaille (L166/226/233/252).

**Points faibles recurrents** (10 FAIL) :
1. **`readonly`** : aucun script ne declare ses constantes readonly — risque identique au Ring 0+1
2. **`--` separator** : 9/10 scripts n'utilisent pas `--` de maniere systematique (seul fleet-dispatch le fait dans son option parser L95)
3. **trap cleanup** : 6/10 scripts manquent de trap pour nettoyer les fichiers temporaires en cas d'interruption

**Points faibles ponctuels** :
- **timeout** : fleet-plan, fleet-scrub, fleet-launch, light_off n'ont pas de timeout sur les commandes externes longues (rsync, tmux, dispatch calls)
- **umask** : fleet-state (log file), fleet-dispatch (log file, PID file), fleet-launch (socket, PID, log), light_on (known-repos) creent des fichiers sans umask restrictif
- **validation numerique** : fleet-dispatch (`--max-turns`, `--timeout`) et fleet-plan (`--step`) n'ont pas de validation regex sur les inputs numeriques

**Comparaison Ring 0+1 vs Ring 2+3+4** :
Le niveau de maturite est comparable. Les memes 3 faiblesses systemiques (readonly, --, trap) se retrouvent dans les deux audits. Le code Ring 3 (dispatch, plan, scrub) est plus complexe mais maintient la discipline sur les points critiques. Le code Ring 4 (launch, light_on/off) gere correctement les gates de securite (WSL mount check, deploy gate, graceful shutdown).
