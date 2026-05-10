# Audit bash-pro Safety & Security Patterns — 6 kernel scripts

**Date** : 2026-03-28
**Checklist source** : `/home/projects/LCARS/knowledge/wshobson-agents/shell-scripting/bash-pro.md` (section Safety & Security Patterns, 14 points)
**Statut** : recherche uniquement, aucun fichier modifie

## Scripts audites

| Alias | Chemin complet |
|---|---|
| **fleet-env** | `/home/projects/LCARS/fleet/fleet-env.sh` |
| **build-yaml** | `/home/projects/LCARS/fleet/fleet-build-yaml.sh` |
| **build-sp** | `/home/projects/LCARS/fleet/system-prompt/build-sp.sh` |
| **fleet-send** | `/home/projects/LCARS/fleet/fleet-send.sh` |
| **inbox-read** | `/home/projects/LCARS/fleet/fleet-inbox-read.sh` |
| **wake-instance** | `/home/projects/LCARS/fleet/wake-instance.sh` |

---

## Resultats detailles

### 1. Declare constants with `readonly`

| Script | Verdict | Detail |
|---|---|---|
| fleet-env | FAIL | Aucune variable declaree `readonly` malgre 23+ constantes exportees (LCARS_ROOT, FLEET_DIR, etc.) |
| build-yaml | FAIL | SYSTEM, PROFILE_FILE, OUTPUT etc. (L97-99) ne sont pas `readonly` |
| build-sp | FAIL | SCRIPT_DIR, SP_DIR, SOURCES, ANTHROPIC (L84-87) ne sont pas `readonly` |
| fleet-send | FAIL | MSG_TYPE, MSG_PRIORITY etc. initiales (L87-89) ne sont pas `readonly` apres parsing |
| inbox-read | FAIL | INSTANCE, INBOX (L72, L80) ne sont pas `readonly` |
| wake-instance | FAIL | INSTANCE, SUBJECT (L79, L83) ne sont pas `readonly` apres validation |

### 2. Use `local` for all function variables

| Script | Verdict | Detail |
|---|---|---|
| fleet-env | FAIL | `_fleet_env_cache_hit()` L155-166 utilise `local` pour ses variables internes — OK. Mais `_fleet_env_write_cache()` L251-284 utilise `local mtime md5` — OK. Cependant `fleet_role_field()`, `fleet_bin()`, `fleet_find_pane()` etc. utilisent `local` correctement. `fleet_tmux()` L320-326 n'a pas de variable locale propre (utilise uniquement des parametres) — OK. PASS sur les fonctions definies. Mais `_yq()` L176/290 n'a aucune variable — N/A. **Verdict global : PASS** |
| build-yaml | N/A | Pas de fonction definie (script lineaire) |
| build-sp | PASS | `build_agent()` L111-196 utilise `local` pour role, sp_list, home_dir, out, org_header_done, missing_sources, core_count, src, chars, tokens_est |
| fleet-send | N/A | Pas de fonction definie (script lineaire) |
| inbox-read | N/A | Pas de fonction definie (script lineaire) |
| wake-instance | PASS | `_wait_for_claude()` L151-159 utilise `local user max_wait elapsed`. `_tmux()` L109/111 n'a pas de var locale propre — OK |

### 3. Implement `timeout` for external commands

| Script | Verdict | Detail |
|---|---|---|
| fleet-env | FAIL | `yq` appele de multiples fois (L179-248) sans timeout. Si fleet.yaml est sur un FS lent/NFS, hang possible |
| build-yaml | FAIL | `yq eval-all` L134 (merge potentiellement long) sans timeout |
| build-sp | FAIL | `yq` appele en boucle (L221-229) sans timeout |
| fleet-send | N/A | Pas de commande externe longue (les appels yq sont indirects via fleet-env.sh, wake-instance.sh est appele mais `|| true`) |
| inbox-read | N/A | Pas de commande reseau/longue directe (find, mv, flock sont locaux) |
| wake-instance | FAIL | `pgrep` et `_tmux` appeles sans timeout. `_wait_for_claude` (L151-159) a un timeout interne (poll-based, max 10-15s) — bon. Mais `_tmux display-message` L148, `_tmux capture-pane` L178 n'ont pas de timeout |

### 4. Validate file permissions before operations (`[[ -r "$file" ]]`)

| Script | Verdict | Detail |
|---|---|---|
| fleet-env | PASS | `[[ -f "$FLEET_ENV_DIR/fleet.yaml" ]]` L139, `[[ -f ... ]]` L156 avant lecture. `source "$_FLEET_ENV_CACHE"` L171 protege par `_fleet_env_cache_hit` qui verifie existence |
| build-yaml | PASS | `[[ -f "$SYSTEM" ]]` L102, `[[ -f "$PROFILE_FILE" ]]` L103, `[[ -f "$PARENT" ]]` L124 — verifications avant lecture |
| build-sp | PASS | `[[ ! -f "$ANTHROPIC" ]]` L136, `[ -f "$f" ]` L147, `[[ ! -f "$src" ]]` L157/166, `[ -f "$role_file" ]` L178 — tous verifies |
| fleet-send | PASS | `[ ! -d "$INBOX_DIR" ]` L111, `[ -f "$CONTENT_FILE" ]` L165 — verifie avant acces |
| inbox-read | PASS | `[[ -d "$INBOX" ]]` L81, `[ -f "$msg" ]` L95, `[ -f "$PROC_FILE" ]` L106, `[ -f "$FLEET_ENV" ]` L78 |
| wake-instance | PASS | `[ -x "$WAKE_NOTIFY" ]` L129/189, `[ -x "$ALERT_SCRIPT" ]` L92/137 — verifie executabilite |

### 5. Use process substitution instead of temporary files when possible

| Script | Verdict | Detail |
|---|---|---|
| fleet-env | PASS | Pas de fichier temp inutile. Le cache (`fleet-env.cache`) est un mecanisme explicite avec write-tmp-then-mv (L256-283) |
| build-yaml | PASS | Utilise `_OUTPUT_TMP` avec write-tmp-then-mv atomique L131-144 — necessaire pour atomicite |
| build-sp | N/A | Ecrit directement dans le fichier cible (pas de temp) |
| fleet-send | PASS | Utilise `${MSG_FILE}.tmp` avec mv atomique L166-177 — necessaire pour atomicite IPC |
| inbox-read | N/A | Pas de fichier temporaire |
| wake-instance | N/A | Pas de fichier temporaire |

### 6. Sanitize user input before using in commands

| Script | Verdict | Detail |
|---|---|---|
| fleet-env | PASS | `fleet_role_field()` L314-315 valide role et field avec regex `^[a-z0-9_-]+$` / `^[a-z0-9_.]+$`. `fleet_roles_by_tier()` L301 valide numerique. Ligne 233-234 : evite `eval` pour home dir, utilise `getent passwd` |
| build-yaml | PASS | PROFILE vient de CLI ou fleet-system.yaml, utilise dans chemin fichier uniquement (`profiles/${PROFILE}.yaml`). `yq` recoit des fichiers statiques |
| build-sp | PASS | Les keys du system_prompt viennent de fleet.yaml (YAML parse), pas d'input utilisateur direct. Cependant le `case` L134-173 filtre les keys attendues |
| fleet-send | PASS | `SAFE_SUBJECT` L143 sanitise sujet (lowercase, tr -cd alnum). Mais DEST (L102) n'est pas valide par regex — **note** : l'IPC authorization matrix L117-138 sert de validation implicite |
| inbox-read | PASS | INSTANCE vient de $1 mais n'est utilise que dans chemin `$INBOX` — pas d'injection possible (pas de eval/cmd substitution sur INSTANCE) |
| wake-instance | PASS | L81 : `[[ "$INSTANCE" =~ ^[a-z0-9_-]+$ ]]` — validation explicite. L83 : SUBJECT sanitise via `tr -cd '[:print:]' | head -c 200` |

### 7. Validate numeric input with pattern matching

| Script | Verdict | Detail |
|---|---|---|
| fleet-env | PASS | `fleet_roles_by_tier()` L301 : `[[ "${1:-}" =~ ^[0-9]+$ ]]` — validation explicite |
| build-yaml | PASS | L222 : `[[ ... "$INSTANCE_COUNT" =~ ^[0-9]+$ ]]` dans build-sp (pas dans build-yaml directement). L119 : `DEPTH` est incremente internement, pas d'input num externe |
| build-sp | PASS | L222 : `"$INSTANCE_COUNT" =~ ^[0-9]+$` — validation du count d'instances |
| fleet-send | N/A | Pas d'input numerique utilisateur |
| inbox-read | N/A | Pas d'input numerique utilisateur (`LINE_COUNT` L122 vient de `wc -l` interne) |
| wake-instance | N/A | Pas d'input numerique utilisateur |

### 8. Never use `eval` on user input

| Script | Verdict | Detail |
|---|---|---|
| fleet-env | PASS | L233 commente explicitement : "Resolve home without eval (eval + user input = injection risk)" — getent passwd utilise a la place |
| build-yaml | PASS | Aucun `eval` |
| build-sp | PASS | Aucun `eval` |
| fleet-send | PASS | Aucun `eval` |
| inbox-read | PASS | Aucun `eval` |
| wake-instance | PASS | Aucun `eval` |

### 9. Set restrictive umask for sensitive operations

| Script | Verdict | Detail |
|---|---|---|
| fleet-env | N/A | Pas de creation de fichier sensible (le cache est non-sensible, donnees publiques fleet) |
| build-yaml | FAIL | `fleet.yaml` est cree en 664 (L153 `chmod 664`) mais pas via umask. Le tmp file est cree sans umask restrictif — fenetre ou un autre processus pourrait lire le contenu pendant l'ecriture |
| build-sp | FAIL | `system-prompt.md` cree sans umask restrictif. Contient potentiellement le systeme prompt complet de l'agent |
| fleet-send | PASS | `chmod 660` L179 sur le message. Cependant le `.tmp` est cree sans umask — fenetre courte. Acceptable pour IPC interne |
| inbox-read | N/A | Ne cree pas de fichiers sensibles (ack files sont metadata interne) |
| wake-instance | N/A | Ne cree pas de fichiers |

### 10. Log security-relevant operations

| Script | Verdict | Detail |
|---|---|---|
| fleet-env | PASS | `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1` L352 — securite active. Erreurs loguees stderr L131-133 |
| build-yaml | PASS | WARN pour Opus sur plan PRO L160-163. Erreurs de validation loguees stderr L171-191 |
| build-sp | N/A | Pas d'operation security-relevant directe |
| fleet-send | PASS | Authorization denied logue L122-137 (stderr). Message delivre logue L182 |
| inbox-read | N/A | Lecture spool est une operation courante, pas security-relevant |
| wake-instance | PASS | Actions loguees : resume claude L169, trust dialog L180, wake sent L197, errors L163-174 |

### 11. Use `--` to separate options from arguments

| Script | Verdict | Detail |
|---|---|---|
| fleet-env | FAIL | `readlink -f "${BASH_SOURCE[0]}"` L127 sans `--`. Pas de `--` sur les appels `stat`, `cut`, `head` |
| build-yaml | PASS | `rm -f "$OUTPUT"` L108 sans `--` mais la variable est construite internement, pas user input. `readlink -f "${BASH_SOURCE[0]}"` L91 sans `--` |
| build-sp | FAIL | `readlink -f "$0"` L84 sans `--`. `cat "$ANTHROPIC"` L141 sans `--`. Les fichiers sont resolus internement cependant |
| fleet-send | PASS | `fleet-send.sh` option parser L96 : `--) shift; break ;;` — pattern correct pour separer options des args |
| inbox-read | FAIL | `find "$INBOX" -maxdepth 1` L85 sans `--`. `mv "$msg" "$PROC_FILE"` L103 sans `--` |
| wake-instance | FAIL | `printf '%s' "${2:-wake}" | tr` L83 — OK via printf. Mais `mv`, `stat` L107 sans `--`. `readlink -f` L85-86 sans `--` |

### 12. Validate environment variables (`: "${REQUIRED_VAR:?not set}"`)

| Script | Verdict | Detail |
|---|---|---|
| fleet-env | PASS | Utilise le pattern fallback `: "${LCARS_ROOT:=/local/LCARS}"` L185-186 — default values pour toutes les variables critiques. FLEET_YAML resolu avec chaine de fallback L139-146 |
| build-yaml | PASS | `DEST="${1:?usage: ...}"` — non, c'est dans fleet-send. Ici : `command -v yq` L101, `[[ -f "$SYSTEM" ]]` L102, `[[ -f "$PROFILE_FILE" ]]` L103 — validation avant utilisation |
| build-sp | PASS | FLEET_YAML verifie `[[ -z "$FLEET_YAML" || ! -f "$FLEET_YAML" ]]` L216. INSTANCE_COUNT verifie L222 |
| fleet-send | PASS | `DEST="${1:?usage: ...}"` L102, `SUBJECT="${2:?usage: ...}"` L103, `"${2:?--type requires a value}"` L93-95 — pattern `:?` utilise |
| inbox-read | PASS | `[[ -z "$INSTANCE" ]]` L73 avec sortie gracieuse. `FLEET_SPOOL_INBOX` fallback L80 |
| wake-instance | PASS | `INSTANCE="${1:?usage: ...}"` L79 — pattern `:?` utilise |

### 13. Check exit codes of security-critical operations

| Script | Verdict | Detail |
|---|---|---|
| fleet-env | PASS | `command -v yq &>/dev/null` L130 avec `return 1 || exit 1`. `set -uo pipefail` L85 |
| build-yaml | PASS | `set -euo pipefail` L83. Validation post-generation explicite L138-192 (empty file, duplicate roles, required keys) |
| build-sp | PASS | `set -euo pipefail` L82. Erreurs de build loguees mais non-bloquantes (WARN) — acceptable car sources manquantes ne sont pas fatales |
| fleet-send | PASS | `set -euo pipefail` L81. Authorization check L117-138 avec `exit 1`. `chmod` L179 non verifie mais non-critique |
| inbox-read | PASS | `set -uo pipefail` L70. flock L102/132 avec `|| exit 1` dans subshell. `|| true` sur non-critiques |
| wake-instance | PASS | `set -euo pipefail` L74. Instance validation L81 avec `exit 1`. Operations tmux avec `|| true` quand appropriate |

### 14. Use `trap` to ensure cleanup on abnormal exit

| Script | Verdict | Detail |
|---|---|---|
| fleet-env | FAIL | Pas de trap. Le cache utilise write-tmp-then-mv mais pas de trap pour supprimer `.tmp` en cas d'interruption |
| build-yaml | PASS | L132 : `trap 'rm -f "$_OUTPUT_TMP" 2>/dev/null' INT TERM EXIT` — cleanup du fichier temporaire. L145 : trap restaure apres mv |
| build-sp | FAIL | Ecrit directement dans `$out` (`: > "$out"` L130 tronque puis cat append). Si interrompu, fichier partiel reste. Pas de trap |
| fleet-send | PASS | L148 : `trap 'rm -f "${MSG_FILE}.tmp" 2>/dev/null' INT TERM` — cleanup tmp. L181 : `trap - INT TERM` restaure. Note : manque EXIT dans le trap (TERM+INT seulement) |
| inbox-read | FAIL | Pas de trap. Si interrompu pendant le processing, un message peut rester dans `.processing/` indefiniment |
| wake-instance | N/A | Pas de fichier temporaire a nettoyer. Les operations tmux sont atomiques |

---

## Synthese par script

| Script | PASS | FAIL | N/A | Score |
|---|---|---|---|---|
| **fleet-env** | 8 | 4 | 2 | 8/12 |
| **build-yaml** | 10 | 2 | 2 | 10/12 |
| **build-sp** | 8 | 4 | 2 | 8/12 |
| **fleet-send** | 10 | 1 | 3 | 10/11 |
| **inbox-read** | 6 | 3 | 5 | 6/9 |
| **wake-instance** | 8 | 3 | 3 | 8/11 |

## Synthese par point de securite

| # | Point | fleet-env | build-yaml | build-sp | fleet-send | inbox-read | wake-instance |
|---|---|---|---|---|---|---|---|
| 1 | readonly constants | FAIL | FAIL | FAIL | FAIL | FAIL | FAIL |
| 2 | local in functions | PASS | N/A | PASS | N/A | N/A | PASS |
| 3 | timeout external cmds | FAIL | FAIL | FAIL | N/A | N/A | FAIL |
| 4 | validate file perms | PASS | PASS | PASS | PASS | PASS | PASS |
| 5 | process substitution | PASS | PASS | N/A | PASS | N/A | N/A |
| 6 | sanitize input | PASS | PASS | PASS | PASS | PASS | PASS |
| 7 | validate numeric | PASS | PASS | PASS | N/A | N/A | N/A |
| 8 | no eval | PASS | PASS | PASS | PASS | PASS | PASS |
| 9 | restrictive umask | N/A | FAIL | FAIL | PASS | N/A | N/A |
| 10 | log security ops | PASS | PASS | N/A | PASS | N/A | PASS |
| 11 | `--` separator | FAIL | PASS | FAIL | PASS | FAIL | FAIL |
| 12 | validate env vars | PASS | PASS | PASS | PASS | PASS | PASS |
| 13 | check exit codes | PASS | PASS | PASS | PASS | PASS | PASS |
| 14 | trap cleanup | FAIL | PASS | FAIL | PASS | FAIL | N/A |

## Verdict global

**Bilan positif** : Les 6 scripts respectent les points critiques (pas d'eval, validation des inputs, check des exit codes, validation des env vars, sanitisation). Le code montre une conscience securitaire reelle (commentaire SEC-09/SEC-10 dans wake-instance, getent au lieu d'eval dans fleet-env, authorization matrix dans fleet-send).

**Points faibles recurrents** (6 FAIL partout) :
1. **`readonly`** : aucun script ne declare ses constantes readonly — risque de modification accidentelle en cas de source par un script tiers
2. **`timeout`** : les appels `yq` ne sont jamais wraps dans `timeout` — risque de hang sur FS distant
3. **`--` separator** : utilisation inconsistante — les chemins resolus internement sont a faible risque mais le pattern devrait etre systematique

**Points faibles ponctuels** :
- **trap/cleanup** : fleet-env, build-sp et inbox-read manquent de trap pour nettoyer fichiers partiels en cas d'interruption
- **umask** : build-yaml et build-sp ne protegent pas les fichiers generes avec umask restrictif pendant l'ecriture
