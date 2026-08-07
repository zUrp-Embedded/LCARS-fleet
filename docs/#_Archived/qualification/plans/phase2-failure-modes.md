# Registre de modes de defaillance -- Phase 2 Kernel

**Date** : 2026-03-25
**Derniere revision** : 2026-03-25
**Statut** : initial
**Reference par** : work/TODO/v6-qualification-plan.md
**Derive de** : analyse code (16 scripts, 2 456 LOC) + FMEA agents (docs/qualification/fmea/)

---

## Vague 2.1 -- Fondation

### fleet-env.sh (206L)

**Role** : bootstrap fleet -- exporte 23 variables + 8 fonctions. SPOF absolu : tout en depend.
**Dependances** : yq, fleet.yaml, readlink, stat, awk, whoami
**Cross-ref FMEA** : SF-06 (RPN 256, GO-0 inference infra), SF-04 (RPN 90, fleet.yaml corrompu), SF-14 (RPN 147, source pendant git pull)

| # | Mode de defaillance | Severite | Test adversarial obligatoire |
|---|---|---|---|
| ENV-01 | yq absent du PATH | HIGH | `command -v yq` echoue -> verifier exit propre (return 1 / exit 1) et message stderr explicite |
| ENV-02 | fleet.yaml absent (aucun des 2 chemins) | MEDIUM | Supprimer fleet.yaml des 2 locations -> verifier WARN stderr + FLEET_YAML=/dev/null + fallbacks actifs pour toutes les variables |
| ENV-03 | fleet.yaml present mais vide ou syntaxe YAML invalide | HIGH | fleet.yaml = fichier vide, puis fichier avec YAML casse -> verifier que `_yq` retourne vide/null et que les fallbacks s'activent (LCARS_ROOT=/local/LCARS, etc.) |
| ENV-04 | yq retourne "null" pour chaque champ (fleet.yaml valide mais section manquante) | MEDIUM | fleet.yaml sans section `fleet.paths` -> verifier que chaque variable a son fallback (lignes 80-121) |
| ENV-05 | Variable FLEET_HUB_PORT deja definie dans l'environnement (collision env) | LOW | `export FLEET_HUB_PORT=9999` avant source -> verifier que la valeur pre-existante est preservee (ligne 116 : `${FLEET_HUB_PORT:-...}`) |
| ENV-06 | readlink -f echoue (symlink casse vers fleet-env.sh) | HIGH | Creer un symlink casse pointant vers fleet-env.sh -> verifier comportement FLEET_ENV_DIR |
| ENV-07 | BASH_SOURCE[0] vide (script source depuis un contexte non-standard) | HIGH | Simuler source avec BASH_SOURCE vide -> verifier que FLEET_ENV_DIR ne devient pas "/" |
| ENV-08 | fleet_find_pane appele sans tmux socket | MEDIUM | FLEET_TMUX_SOCK pointe vers fichier inexistant -> verifier retour vide sans erreur fatale |
| ENV-09 | fleet_role_field avec role contenant des metacaracteres yq | MEDIUM | `fleet_role_field '"; rm -rf /' "role"` -> verifier que yq ne fait pas d'injection (guillemets dans la query) |
| ENV-10 | `set -uo pipefail` sans `set -e` : erreur non fatale dans un pipe | LOW | Commande qui echoue dans un pipeline apres source fleet-env.sh -> verifier que pipefail propage l'erreur |
| ENV-11 | fleet_bin retourne chaine vide pour un binaire inexistant | LOW | `fleet_bin "inexistant-12345"` -> verifier retour chaine vide, pas d'erreur |
| ENV-12 | Fichier `$HOME/.claude/instance-name` absent et CLAUDE_AGENT_NAME non defini et hostname echoue | LOW | Unset CLAUDE_AGENT_NAME + supprimer instance-name -> verifier que FLEET_INSTANCE a une valeur (hostname fallback) |

---

### fleet-build-yaml.sh (110L)

**Role** : genere fleet.yaml a partir de fleet-system.yaml + profil. Blueprint builder.
**Dependances** : yq, fleet-system.yaml, profiles/*.yaml, chgrp, chmod
**Cross-ref FMEA** : SF-04 (RPN 90, fleet.yaml corrompu = output de ce script)

| # | Mode de defaillance | Severite | Test adversarial obligatoire |
|---|---|---|---|
| BLD-01 | yq absent du PATH | HIGH | `command -v yq` echoue -> verifier exit 1 avec message stderr |
| BLD-02 | fleet-system.yaml absent | HIGH | Supprimer fleet-system.yaml -> verifier exit 1 avec message indiquant le path |
| BLD-03 | Profil demande inexistant | HIGH | `fleet-build-yaml.sh nonexistent_profile` -> verifier exit 1 avec message incluant le nom du profil |
| BLD-04 | Chaine extends avec profil parent absent | HIGH | Profil avec `extends: missing_parent` -> verifier exit 1 avec message "base profile not found" |
| BLD-05 | Chaine extends circulaire (A extends B extends A) | HIGH | Creer deux profils mutuellement extends -> verifier que la boucle while ne boucle pas indefiniment (actuellement : **pas de guard**, boucle infinie potentielle) |
| BLD-06 | Permission denied sur $OUTPUT (fleet.yaml) | MEDIUM | `chmod 000 "$OUTPUT"` -> rm -f echoue silencieusement (|| true) mais `yq > $OUTPUT` echoue -> verifier exit code et message |
| BLD-07 | fleet-system.yaml syntaxe YAML invalide | HIGH | fleet-system.yaml avec YAML casse -> verifier que yq eval-all echoue proprement (set -e le capte) |
| BLD-08 | `chgrp fleet` echoue (groupe fleet inexistant) | LOW | Pas de groupe fleet -> `chgrp fleet ... 2>/dev/null || true` silencieux, verifier que fleet.yaml est quand meme ecrit |
| BLD-09 | FLEET_DIR pas defini et pas de fleet-system.yaml co-localisee | MEDIUM | Ni env ni /local/LCARS -> verifier que FLEET_DIR tombe sur dirname de BASH_SOURCE |

---

## Vague 2.2 -- Etat + IPC

### fleet-session-log.sh (88L)

**Role** : enregistre la duree de session dans un fichier CSV append-only. Signal drift si > 2h/3h.
**Dependances** : fleet-env.sh, date, mkdir, rm
**Cross-ref FMEA** : aucun mode FMEA specifique (utilitaire metrics)

| # | Mode de defaillance | Severite | Test adversarial obligatoire |
|---|---|---|---|
| LOG-01 | fleet-env.sh absent ou echoue au source | HIGH | fleet-env.sh introuvable -> verifier que le script echoue proprement (set -uo pipefail + source) |
| LOG-02 | Fichier start timestamp absent (/tmp/session-start-*) | LOW | Pas de fichier start -> verifier "unknown" dans le log et exit 0 (pas d'erreur fatale) |
| LOG-03 | Fichier start timestamp contient du texte non-numerique | MEDIUM | `echo "abc" > /tmp/session-start-test` -> `$START_TS -eq 0` : verifier que la comparaison arithmetique ne crash pas (bash: abc: integer expression expected) -> le `|| echo 0` couvre le cat mais pas le contenu non-numerique dans -eq |
| LOG-04 | Repertoire $FLEET_LOGS inaccessible (permission denied) | MEDIUM | mkdir -p reussit mais `>> "$LOG"` echoue -> verifier message d'erreur (set -uo pipefail le capte) |
| LOG-05 | Duree negative (START_TS dans le futur) | LOW | `echo $(($(date +%s) + 3600)) > /tmp/session-start-test` -> verifier comportement avec duree negative |

---

### fleet-state.sh (124L)

**Role** : met a jour les champs STATE du handoff actif. Interface d'ecriture du dashboard.
**Dependances** : fleet-env.sh, sed, grep, rsync, fleet-session-log.sh, fleet_bin()
**Cross-ref FMEA** : EN-03 (RPN 210, suivi taches perdu -- fleet-state est le mecanisme de tracking)

| # | Mode de defaillance | Severite | Test adversarial obligatoire |
|---|---|---|---|
| STA-01 | FLEET_SESSION non defini (session hors-fleet) | LOW | Unset FLEET_SESSION -> verifier exit 0 silencieux (guard ligne 59) |
| STA-02 | Zero arguments | MEDIUM | `fleet-state.sh` sans args -> verifier exit 1 avec usage |
| STA-03 | Cle inconnue dans les arguments | LOW | `fleet-state.sh foo=bar` -> verifier WARNING stderr + champ ignore |
| STA-04 | Handoff file absent (premier run) | MEDIUM | Supprimer le handoff -> verifier creation automatique avec template (printf ligne 68-69) avec les 7 champs STATE |
| STA-05 | Section ## STATE absente du handoff | MEDIUM | Handoff sans "## STATE" -> verifier WARNING et exit 0 (ligne 72, pas d'ecriture) |
| STA-06 | Valeur contenant des pipes `|` (metacaractere sed) | MEDIUM | `fleet-state.sh action="test|with|pipes"` -> verifier que l'echappement VAL_ESC (ligne 85) fonctionne |
| STA-07 | sed echoue sur le fichier (permission denied ou disque plein) | HIGH | `chmod 444 "$FILE"` -> sed ecrit dans .tmp mais mv echoue -> verifier que set -e attrape l'erreur |
| STA-08 | rsync vers ready-room echoue (drvfs indisponible) | LOW | FLEET_READY_ROOM pointe vers dir inexistant -> `rsync ... || true` silencieux, pas de crash |
| STA-09 | fleet-session-log.sh absent quand action=handoff | LOW | fleet_bin retourne vide -> `[[ -n "$SESSION_LOG_BIN" ]] && ...` ne s'execute pas, `|| true` couvre l'echec |

---

### fleet-send.sh (145L)

**Role** : IPC coeur -- depose un message dans inbox/<dest>/ puis wake le destinataire.
**Dependances** : fleet-env.sh, wake-instance.sh, date, tr, printf, chmod, chgrp
**Cross-ref FMEA** : EN-01 (RPN 84, dispatch au mauvais agent), EN-04 (RPN 120, ecriture concurrente)

| # | Mode de defaillance | Severite | Test adversarial obligatoire |
|---|---|---|---|
| SND-01 | Destination inbox inexistante ($INBOX_DIR absent) | HIGH | Role valide mais inbox pas creee (deploy.sh non execute) -> verifier exit 1 + message "run deploy.sh" |
| SND-02 | Source non autorisee a envoyer a la destination (matrice IPC) | HIGH | `FLEET_INSTANCE=dev fleet-send.sh qualifier "test"` -> dev->qualifier interdit, verifier exit 1 |
| SND-03 | Source = architect (interdit d'envoyer via fleet-send) | HIGH | `FLEET_INSTANCE=architect fleet-send.sh engineer "test"` -> verifier exit 1 + message |
| SND-04 | Source inconnue (pas dans la matrice case) | HIGH | `FLEET_INSTANCE=unknown fleet-send.sh dev "test"` -> verifier exit 1 "IPC authorization denied" |
| SND-05 | Subject avec caracteres speciaux (injection filename) | MEDIUM | Subject = `"../../etc/passwd"` -> verifier que SAFE_SUBJECT est sanitize (tr -cd alnum-dash) et que le fichier est ecrit dans INBOX_DIR, pas ailleurs |
| SND-06 | Content file specifie mais inexistant et ressemble a un path | LOW | `fleet-send.sh dev "test" /nonexistent/file.md` -> verifier WARN stderr + traitement comme inline content |
| SND-07 | Ecriture atomique interrompue (kill pendant write) | MEDIUM | Verifier pattern tmp+mv : `${MSG_FILE}.tmp` ecrit puis `mv -f` -> pas de fichier partiel visible dans inbox |
| SND-08 | Deux fleet-send.sh concurrents vers le meme destinataire | MEDIUM | Lancer 2 sends en parallele -> verifier que les deux messages arrivent (filenames differents grace au timestamp, mais race sur chmod/chgrp) |
| SND-09 | wake-instance.sh absent ou non executable | LOW | `chmod -x wake-instance.sh` -> `[ -x "$WAKE" ]` est false, `|| true` -> message delivre mais pas de wake |
| SND-10 | Stdin vide et pas de content file (pas de terminal) | LOW | `echo "" | fleet-send.sh dev "test"` -> verifier message cree avec envelope seule |
| SND-11 | Flag --type/--priority/--ref sans valeur | MEDIUM | `fleet-send.sh --type` (sans valeur) -> `${2:?}` doit echouer avec message "requires a value" |

---

### fleet-inbox-read.sh (126L)

**Role** : drain du spool inbox vers le contexte agent. Auto-ACK PING. Flock pour atomicite.
**Dependances** : fleet-env.sh, find, flock, mv, grep, sed, wc, head, cat, fleet-send.sh, fleet-alert.sh
**Cross-ref FMEA** : EN-03 (RPN 210, messages perdus = suivi perdu)

| # | Mode de defaillance | Severite | Test adversarial obligatoire |
|---|---|---|---|
| INB-01 | Instance non specifiee | LOW | `fleet-inbox-read.sh` sans args -> verifier exit 0 + message "skipping" stderr |
| INB-02 | Inbox dir inexistant pour l'instance | LOW | Instance valide mais pas de dir inbox -> verifier exit 0 silencieux |
| INB-03 | Inbox vide (aucun .md) | LOW | Inbox existe mais vide -> verifier exit 0 sans output |
| INB-04 | Message sans frontmatter YAML (pas de --- delimiteurs) | MEDIUM | Fichier .md sans `---` -> grep subject/from retournent vide -> verifier affichage "type:? priority:normal" et pas de crash |
| INB-05 | Message tronque (fichier vide de 0 octets) | MEDIUM | `touch inbox/agent/msg.md` -> verifier que le fichier est consomme sans crash (wc, cat sur fichier vide) |
| INB-06 | flock echoue (lock deja pris par un autre processus) | MEDIUM | `flock -n 200` echoue -> `exit 0` dans le subshell, mv non effectue -> message reste dans inbox (non consomme). Verifier qu'un deuxieme run le traite |
| INB-07 | Message > 200 lignes (truncation) | LOW | Message de 500 lignes -> verifier head -200 + message "truncated -- 500 lines total" |
| INB-08 | Race condition : message supprime entre find et mv | LOW | Supprimer le fichier apres find mais avant mv -> `mv ... 2>/dev/null || true` + `[ -f "$PROC_FILE" ] || continue` -> verifier no crash |
| INB-09 | Auto-ACK PING quand fleet-send.sh est absent | LOW | fleet-send.sh non executable -> `[ -x "$SEND" ]` false -> ACK non envoye mais pas de crash |
| INB-10 | fleet-alert.sh --stop echoue | LOW | fleet-alert.sh absent -> `[ -x "$ALERT_SCRIPT" ] && ... || true` -> verifier pas de crash |
| INB-11 | Permission denied sur .processing/ ou .consumed/ | HIGH | `chmod 000 inbox/.processing` -> mkdir -p OK mais mv echoue dans le flock subshell -> message non consomme. Verifier pas de perte |

---

### wake-instance.sh (157L)

**Role** : envoie un signal wake a une instance fleet via tmux. Gere wakeable/headless/standalone.
**Dependances** : fleet-env.sh, yq, tmux (via sudo si cross-UID), fleet-wake-notify.sh, fleet-alert.sh, pgrep, stat
**Cross-ref FMEA** : SF-12 (RPN 64, SPOF starfleet indisponible)

| # | Mode de defaillance | Severite | Test adversarial obligatoire |
|---|---|---|---|
| WAK-01 | Instance non specifiee | HIGH | `wake-instance.sh` sans args -> verifier message d'erreur usage (${1:?}) |
| WAK-02 | Subject contient des caracteres de controle (injection tmux send-keys) | HIGH | Subject avec `\n` et sequences escape -> verifier sanitization via `tr -cd '[:print:]'` (ligne 57) + truncation 200 chars |
| WAK-03 | Agent marque non-wakeable dans fleet.yaml | LOW | Role avec wakeable=false -> verifier gyrophare lance + exit 0 + message "non-wakeable" |
| WAK-04 | Agent headless (pas de pane tmux) | LOW | Role avec section headless dans fleet.yaml -> verifier exit 0 silencieux |
| WAK-05 | Pane tmux introuvable (ni fleet_find_pane ni session standalone) | MEDIUM | Agent sans pane tmux et sans session standalone -> verifier "no tmux pane, message in spool" + appel fleet-wake-notify.sh |
| WAK-06 | Socket tmux absent ($FLEET_TMUX_SOCK inexistant) | MEDIUM | FLEET_TMUX_SOCK pointe vers fichier absent -> stat echoue (ligne 79) -> fallback `echo "$FLEET_USER"` -> verifier pas de crash |
| WAK-07 | sudo vers tmux owner echoue (password required) | HIGH | sudo sans NOPASSWD pour l'user -> verifier que _tmux() retourne erreur, pas de blocage interactif |
| WAK-08 | Claude non detecte dans le pane apres 15s de polling | MEDIUM | pgrep -u user -f "claude" ne matche jamais -> verifier WARN apres timeout et `claude --resume` envoye |
| WAK-09 | Trust dialog detection false positive | LOW | Pane content contient "trust this folder" dans un autre contexte -> verifier que Enter est envoye (behavior actuel : pas de guard, false positive possible) |
| WAK-10 | fleet-wake-notify.sh absent ou non executable | LOW | Script absent -> `[ -x "$WAKE_NOTIFY" ]` false -> fallback `_tmux send-keys FLEET::WAKE::...` (ligne 153) |
| WAK-11 | _wait_for_claude boucle 10s/15s inutilement quand le process demarre vite | LOW | Claude demarre en <1s -> verifier que le polling sort des que pgrep matche (return 0) |

---

## Vague 2.3 -- Dispatch + Lifecycle

### fleet-dispatch.sh (241L)

**Role** : dispatcher hybride -- pane tmux active = async spool, sinon = claude -p headless sync.
**Dependances** : fleet-env.sh, yq, fleet_find_pane, fleet-send.sh, sudo, timeout, claude, mktemp
**Cross-ref FMEA** : EN-01 (RPN 84, mauvais agent), EN-02 (RPN 144, multi-scope), EN-04 (RPN 120, ecriture concurrente), DV-08 (RPN 80, max_turns), DV-10 (RPN 168, contexte insuffisant headless)

| # | Mode de defaillance | Severite | Test adversarial obligatoire |
|---|---|---|---|
| DIS-01 | Role format invalide (injection yq) | HIGH | `fleet-dispatch.sh '"; rm -rf /' "test"` -> verifier regex guard `^[a-z][a-z0-9_-]*$` bloque avec exit 1 |
| DIS-02 | Role valide syntaxiquement mais inexistant dans fleet.yaml | HIGH | `fleet-dispatch.sh zzzzz "test" <<< "prompt"` -> verifier "role not found in fleet.yaml" exit 1 |
| DIS-03 | Linux user du role inexistant (id echoue) | HIGH | Role dans fleet.yaml mais linux_user qui n'existe pas -> verifier exit 1 "linux user does not exist" |
| DIS-04 | Pas de prompt (ni fichier ni stdin ni terminal) | HIGH | `fleet-dispatch.sh dev "test"` avec stdin=tty et pas de $3 -> verifier exit 1 "no prompt provided" |
| DIS-05 | Fichier prompt specifie mais inexistant | HIGH | `fleet-dispatch.sh dev "test" /nonexistent` -> verifier exit 1 "prompt file not found" |
| DIS-06 | Headless timeout (claude -p depasse timeout_sec) | HIGH | Timeout court (1s) avec prompt long -> verifier exit 124 + message "timed out" + log + cleanup des tmp files |
| DIS-07 | claude -p exit code non-zero (crash headless) | HIGH | claude echoue avec exit 2 -> verifier exit 1 + message + log + cleanup |
| DIS-08 | sudo -u target_user echoue (permission denied) | HIGH | sudo sans autorisation vers l'user -> verifier que l'erreur est capturee (exit_code non-zero) |
| DIS-09 | _yq retourne "null" pour max_turns/timeout/allowed_tools (role sans section headless) | MEDIUM | Role sans config headless -> verifier fallbacks 20/300/"Read,Grep,Glob,Bash,Agent" |
| DIS-10 | Fichier tmp non nettoye apres timeout ou crash | MEDIUM | Simuler timeout -> verifier que $result_file et $_tmp_prompt sont supprimes (rm -f dans cleanup, mais si exit 124 est atteint avant le cleanup block final ?) |
| DIS-11 | IPC result send echoue (fleet-send.sh rate) | LOW | fleet-send.sh echoue -> `>/dev/null 2>&1 || true` -> verifier que le resultat est quand meme sur stdout |
| DIS-12 | Log dir inexistant ($HOME/.local/log/) | LOW | mkdir -p le cree (ligne 179), mais verifier que si $HOME est en read-only, le script ne crash pas fatalement (set -e) |
| DIS-13 | Deux dispatches simultanes vers le meme role headless | MEDIUM | Verifier que les PID files n'entrent pas en collision (timestamp dans le nom) et que les deux sessions concurrent fonctionnent |

---

### fleet-launch.sh (187L)

**Role** : lance la session fleet tmux avec layout multi-panes (monitor + agents). Demarre fleet-hub.py.
**Dependances** : fleet-env.sh, tmux, python3, fleet-hub.py, fleet-monitor.py, sudo, grep, chmod, chgrp
**Cross-ref FMEA** : SF-12 (RPN 64, fleet indisponible si launch echoue)

| # | Mode de defaillance | Severite | Test adversarial obligatoire |
|---|---|---|---|
| LCH-01 | Session fleet deja existante (re-launch) | LOW | Session tmux "fleet" deja up -> verifier attach si ATTACH=1, exit 0 sinon |
| LCH-02 | $FLEET_HANDOFFS dir inexistant | HIGH | HANDOFF absent -> verifier exit 1 avec message |
| LCH-03 | python3 absent ou fleet-hub.py introuvable | HIGH | python3 absent -> verifier que le background `&` ne bloque pas le launch complet. Actuellement : erreur silencieuse, hub non demarre |
| LCH-04 | tmux socket non creeable (permissions) | HIGH | Path socket dans dir sans write -> verifier erreur explicite |
| LCH-05 | Template invalide | MEDIUM | `fleet-launch.sh --template invalid` -> verifier exit 1 "unknown template" |
| LCH-06 | Security gate : C:\ monte en read-write (WSL) | HIGH | Simuler touch /mnt/c/tmp reussi -> verifier exit 1 avec message security gate |
| LCH-07 | pane-base-index non-numerique | LOW | `show -gv pane-base-index` retourne vide -> verifier fallback PBASE=0 via regex guard |
| LCH-08 | chgrp fleet ou chmod 660 sur socket echoue | LOW | Groupe fleet absent -> `|| true` couvre, verifier pas de crash |
| LCH-09 | sudo -i -u starfleet echoue dans send-keys | MEDIUM | User starfleet inexistant -> la commande est envoyee dans le pane mais echouera au runtime, pas au launch |
| LCH-10 | FLEET_HUB_PORT deja utilise par un autre processus | MEDIUM | Port 8765 occupe -> fleet-hub.py echoue en background, hub non demarre. Verifier que le reste du launch continue |

---

### fleet-shutdown-clean.sh (79L)

**Role** : deplace les ACTIONS pendantes vers DONE [interrupted] a l'arret fleet.
**Dependances** : fleet-env.sh, fleet_roles(), awk, sed (implicite via awk), mv
**Cross-ref FMEA** : aucun mode FMEA specifique

| # | Mode de defaillance | Severite | Test adversarial obligatoire |
|---|---|---|---|
| SDC-01 | fleet-env.sh echoue (yq absent) | HIGH | yq absent -> source echoue -> set -e arrete le script -> aucun handoff nettoye |
| SDC-02 | fleet_roles() retourne une liste vide | LOW | fleet.yaml sans instances -> boucle for vide, pas de crash, exit 0 |
| SDC-03 | Handoff sans section ## ACTIONS ou ## DONE | MEDIUM | Handoff avec seulement ## STATE -> awk ne matche pas -> actions vide -> skip. Mais si ## DONE absent, l'awk ne produit pas le bon output -> verifier que le fichier n'est pas corrompu |
| SDC-04 | Permission denied sur le handoff | MEDIUM | `chmod 444 handoff.md` -> awk > .tmp echoue -> set -e arrete -> les handoffs suivants ne sont pas traites |
| SDC-05 | ACTIONS contenant des metacaracteres awk (backslash, guillemets) | LOW | Actions avec `"quotes" and \backslash` -> verifier que la variable body dans awk est traitee correctement |

---

### light_on.sh (128L)

**Role** : point d'entree boot fleet. Build yaml, deploy gate, repo catalog, lance fleet-launch.
**Dependances** : fleet-build-yaml.sh, fleet-env.sh, fleet-launch.sh, yq, gh, jq, fleet-state.sh, fleet_tmux
**Cross-ref FMEA** : SF-04 (RPN 90, fleet.yaml corrompu a la generation), SF-12 (RPN 64, fleet indisponible)

| # | Mode de defaillance | Severite | Test adversarial obligatoire |
|---|---|---|---|
| LON-01 | Deploy gate : .deploy_ok absent | HIGH | Supprimer /home/fleet-state/.deploy_ok -> verifier exit 1 avec message onboarding |
| LON-02 | fleet-build-yaml.sh echoue (yq absent, profil manquant) | HIGH | Provoquer echec build-yaml -> set -e arrete light_on, fleet non lancee |
| LON-03 | fleet-env.sh echoue apres build-yaml | HIGH | fleet.yaml genere mais fleet-env.sh echoue -> set -e arrete, fleet non lancee |
| LON-04 | gh api user echoue (pas de token GitHub) | LOW | gh non configure -> `|| true` couvre, GH_LOGIN vide, repo catalog skip |
| LON-05 | gh repo list retourne JSON invalide ou vide | LOW | Aucun repo -> jq retourne vide, boucle while ne s'execute pas |
| LON-06 | Argument invalide (ni --fleet ni --projects ni --embedded) | MEDIUM | `light_on.sh --badarg` -> verifier exit 1 usage |
| LON-07 | fleet-launch.sh --no-attach echoue | HIGH | tmux absent ou socket probleme -> set -e arrete -> pas d'attach final |
| LON-08 | known-repos.txt inaccessible (permission denied) | LOW | touch echoue -> set -e arrete (pas couvert par || true). **Bug potentiel** : pas de guard sur touch "$KNOWN_REPOS" |
| LON-09 | fleet-state.sh absent quand notification architect necessaire | LOW | `fleet-state.sh ... 2>/dev/null || true` -> couvert |

---

### light_off.sh (213L)

**Role** : arret fleet. Verifie statuts, propose handoff/force/annuler. Kill session + hub.
**Dependances** : fleet-env.sh, fleet_tmux, fleet_roles, fleet-shutdown-clean.sh, tmux, grep, awk, sed, read, pkill
**Cross-ref FMEA** : aucun mode FMEA specifique (procedure d'arret)

| # | Mode de defaillance | Severite | Test adversarial obligatoire |
|---|---|---|---|
| LOF-01 | Session fleet absente (deja arretee) | LOW | Pas de session tmux "fleet" -> verifier message "rien a arreter" + exit 0 |
| LOF-02 | Tableau MPANES vide (panes monitor absents) | MEDIUM | Session fleet sans panes monitor -> MPANES[1] = vide -> WORKER_PANE["starfleet"]="" -> send-keys echoue silencieusement |
| LOF-03 | Input utilisateur inattendu au prompt read | LOW | `choice` = "x" ou vide -> case default -> "Arret annule" exit 1 |
| LOF-04 | Handoff timeout : workers toujours actifs apres 120s | MEDIUM | Worker bloque -> timeout atteint, prompt "Forcer quand meme?" -> verifier la boucle de polling ne boucle pas indefiniment (elapsed incremente par 5) |
| LOF-05 | stamp_forced_shutdown : sed echoue sur un handoff (permission) | MEDIUM | Handoff read-only -> sed > .tmp echoue -> cette boucle continue (pas de set -e dans la fonction car pas de return check) |
| LOF-06 | fleet-hub.pid absent ou PID stale | LOW | Pas de pid file -> pkill -f fallback. PID stale -> kill -0 false -> rm pid file |
| LOF-07 | fleet-shutdown-clean.sh absent des deux paths | LOW | Ni command -v ni path direct -> cleanup skip silencieusement |
| LOF-08 | --force sans session fleet | LOW | `--force` + pas de session -> FORCE=1 mais has-session false -> "rien a arreter" exit 0 (FORCE parse apres has-session check? Non : FORCE est parse avant. Verifier que la sequence est correcte) |
| LOF-09 | get_status retourne vide (grep ne matche pas "^status:") | LOW | Handoff sans ligne "status:" -> awk retourne vide -> comparaison `!= "offline"` = true -> worker liste comme non-offline |

---

### fleet-restart.sh (49L)

**Role** : wrapper light_off + sleep + light_on.
**Dependances** : fleet-env.sh, light_off.sh, light_on.sh
**Cross-ref FMEA** : aucun

| # | Mode de defaillance | Severite | Test adversarial obligatoire |
|---|---|---|---|
| RST-01 | light_off.sh echoue avec exit non-zero | LOW | Utilisateur annule l'arret -> `|| exit 0` -> restart avorte proprement |
| RST-02 | light_on.sh echoue apres light_off | HIGH | Fleet arretee mais light_on echoue -> fleet reste down. Verifier que l'erreur est visible |
| RST-03 | Paths hardcodes $HOME/fleet/ | MEDIUM | Script assume que light_off.sh et light_on.sh sont dans $HOME/fleet/ -- ne fonctionne pas si le script est dans un autre emplacement (deploy vs source repo) |
| RST-04 | Arguments $@ passes a light_off mais pas a light_on | LOW | `fleet-restart.sh --force` -> --force passe a light_off (correct) mais light_on est lance sans args (profil par defaut) |

---

## Vague 2.4 -- Session hooks

### on-stop.sh (82L)

**Role** : ecrit action=shutdown status=done dans le handoff au stop propre. Rsync handoffs + work vers ready-room.
**Dependances** : fleet-state.sh, fleet-env.sh, rsync, CLAUDE_AGENT_NAME, cat
**Cross-ref FMEA** : SF-09 (RPN 72, compact sans harvest -- on-stop est le last-chance save)

| # | Mode de defaillance | Severite | Test adversarial obligatoire |
|---|---|---|---|
| STP-01 | INSTANCE_NAME vide (ni CLAUDE_AGENT_NAME ni instance-name) | MEDIUM | Les deux absents -> `[ -z "$INSTANCE_NAME" ] && exit 0` -> stop hook ne fait rien, dashboard pas mis a jour |
| STP-02 | fleet-state.sh absent ($HOME/.local/bin/fleet-state.sh) | MEDIUM | Pas installe -> if block skip, aucune mise a jour STATE |
| STP-03 | fleet-env.sh absent des deux paths | MEDIUM | Ni .local/bin ni fleet/ -> _FLEET_ENV vide -> rsync skip, handoffs pas sauvegardes |
| STP-04 | source fleet-env.sh echoue (yq absent) | LOW | `source ... 2>/dev/null || true` -> erreur silencieuse, FLEET_HANDOFFS non defini, rsync skip |
| STP-05 | rsync handoffs echoue (ready-room mount down) | LOW | `rsync ... 2>/dev/null || true` -> erreur silencieuse, snapshot non mis a jour |
| STP-06 | Boucle rsync work/ sur un grand nombre de projets | LOW | 100 projets avec de gros work/ -> rsync sequentiel, pourrait etre lent. Verifier que le hook ne timeout pas |
| STP-07 | stdin non draine (payload JSON du hook Stop) | HIGH | `cat > /dev/null` en ligne 45 le draine. Si absent : JSON pourrait polluer le reste. Verifier que cette ligne reste |

---

### on-prompt.sh (151L)

**Role** : execute a chaque prompt Claude. Met a jour STATE, gere inbox, filtre input workers.
**Dependances** : jq, yq, fleet-state.sh, fleet-inbox-read.sh, fleet-context-check.sh, FLEET_YAML
**Cross-ref FMEA** : EN-03 (RPN 210, suivi perdu -- on-prompt est le trigger de drain inbox)

| # | Mode de defaillance | Severite | Test adversarial obligatoire |
|---|---|---|---|
| PRM-01 | jq absent (payload parsing echoue) | MEDIUM | jq absent -> `|| true` couvre, SESSION_ID vide, pas de context check |
| PRM-02 | Payload JSON invalide ou vide | MEDIUM | Hook appele avec stdin vide -> jq retourne vide, HOOK_PAYLOAD vide, toutes les extractions retournent vide -> verifier pas de crash |
| PRM-03 | yq absent (headless/wakeable check echoue) | MEDIUM | yq absent -> $_HAS_HEADLESS et $_WAKEABLE vides -> inbox drain execute pour les non-wakeable, ce qui est le fallback safe |
| PRM-04 | Handoff file absent | LOW | `[[ -f "$FILE" ]] || exit 0` -> hook sort sans rien faire |
| PRM-05 | fleet-state.sh action=thinking echoue | MEDIUM | fleet-state.sh plante -> echo WARNING stderr mais exit 0 (pas de set -e pour cette commande) |
| PRM-06 | Sentinel FLEET::WAKE::* avec exit 2 mais inbox vide | LOW | Sentinel recu mais inbox vide -> fleet-inbox-read.sh exit 0 -> exit 2 (bloque LLM pour rien, mais injecte le output vide) |
| PRM-07 | Worker recoit du texte libre en contexte fleet | LOW | Instance dev avec FLEET_CONTEXT=fleet et prompt != sentinel/keyword -> verifier "Input direct interdit" stderr + exit 2 |
| PRM-08 | fleet-context-check.sh echoue | LOW | `|| true` couvre l'echec, pas de crash |
| PRM-09 | AUTOCOMPACT_PCT_OVERRIDE non numerique | LOW | `AUTOCOMPACT_PCT="abc"` -> SOFT_THRESHOLD=$(( abc - 5 )) echoue en bash -> **bug potentiel** si la variable est non-numerique. Verifier guard |
| PRM-10 | Action courante = build/deploy/startup : exit 0 premature | LOW | Verifier que les etats speciaux ne bloquent pas indefiniment le hook (le script sort mais le STATE ne change jamais si le build/deploy ne finit pas) |

---

### session-startup.sh (370L)

**Role** : initialise l'etat instance au demarrage. Le plus complexe des hooks. Deploy gate, security gate, CLAUDE.md integrity, handoff restore, inbox drain, contexte per-instance.
**Dependances** : jq, yq, fleet-env.sh, fleet-state.sh, fleet-inbox-read.sh, fleet-lock-cleanup.sh, handoff-check-utf8.sh, drift-check.sh, fleet-check-coherence.sh, fleet-sanitize-memory.sh, rsync, find, grep, awk, head, cat, date, nohup
**Cross-ref FMEA** : SF-06 (RPN 256, GO-0 inference), SF-09 (RPN 72, compact sans harvest), SF-12 (RPN 64, SPOF -- si startup echoue, instance ne boot pas)

| # | Mode de defaillance | Severite | Test adversarial obligatoire |
|---|---|---|---|
| SST-01 | INSTANCE_NAME vide | MEDIUM | Ni CLAUDE_AGENT_NAME ni instance-name -> `[ -z "$INSTANCE_NAME" ] && exit 0` -> session demarre sans contexte fleet |
| SST-02 | Deploy gate : .deploy_ok absent sur agent non-starfleet | MEDIUM | .deploy_ok absent + instance=dev -> verifier message "FLEET NOT READY" + exit 0 (pas exit 2 : session autorisee mais degradee) |
| SST-03 | Security gate : C:\ monte RW (WSL) | HIGH | touch /mnt/c/tmp reussit -> verifier exit 2 (bloque la session) |
| SST-04 | Security gate : Windows interop active | HIGH | WSLInterop present dans binfmt_misc -> verifier exit 2 |
| SST-05 | CLAUDE.md absent | LOW | `[ -f "$CLAUDE_MD" ]` false -> skip integrity check, pas de crash |
| SST-06 | CLAUDE.md avec @include vers fichier absent | MEDIUM | @ref pointe vers fichier supprime -> verifier WARNING avec liste des refs cassees |
| SST-07 | CLAUDE.md avec @include vers symlink casse | MEDIUM | Symlink vers target supprimee -> verifier detection "broken symlink" dans le warning |
| SST-08 | fleet-env.sh absent des deux paths (relative + .local/bin) | HIGH | Ni le path relatif ni .local/bin -> FLEET_HANDOFFS non defini, fallback /home/handoffs -> verifier que le reste du script fonctionne avec les fallbacks |
| SST-09 | tmux socket absent au demarrage | LOW | FLEET_TMUX_SOCK absent -> WARN stderr mais pas de crash (continue) |
| SST-10 | Handoff file absent + handoff ready-room snapshot absent | MEDIUM | Aucun handoff -> C4 restore skip -> handoff cree de zero par fleet-state.sh (ou template printf ligne 171) |
| SST-11 | Handoff file absent + ready-room snapshot present mais rsync echoue | MEDIUM | rsync fail -> WARN "restore failed" -> handoff cree de zero (fallback) |
| SST-12 | Sentinel file /tmp/claude-session-*-started deja present (re-run) | LOW | Sentinel existe -> `exit 0` immediat, startup non re-execute (design intentionnel). Verifier que c'est bien le cas |
| SST-13 | SESSION_ID vide (jq echoue sur payload) | MEDIUM | SESSION_ID vide -> sentinel utilise $PPID (instable entre executions hook) -> startup pourrait re-executer a chaque prompt. **Bug potentiel** si PPID change |
| SST-14 | Instance decommissionnee | LOW | `status: decommissioned` dans handoff -> verifier message HALT et exit 0 (aucune action) |
| SST-15 | fleet-state.sh absent au demarrage (premiere installation) | MEDIUM | Pas dans .local/bin -> WARN stderr, STATE non mis a jour, mais script continue |
| SST-16 | backup-wsl.sh echoue en background (starfleet only) | LOW | nohup ... & -> erreur dans le log /tmp/backup-wsl-*.log, pas d'impact sur startup |
| SST-17 | fleet-lock-cleanup.sh absent | LOW | command -v false et path .local/bin absent -> skip silencieux |
| SST-18 | handoff-check-utf8.sh absent | LOW | Pareil : skip silencieux |
| SST-19 | yq absent quand on query LCARS_VER / DIR_REQ | LOW | yq absent -> `|| echo "unknown"` -> "lcars: unknown" affiche |
| SST-20 | find cleanup sentinels echoue (permission /tmp) | LOW | `2>/dev/null || true` couvre |
| SST-21 | inject_full sur fichier > 200 lignes | LOW | head -200 tronque -> pas de message de truncation (contrairement a inbox-read). Verifier si c'est un probleme |
| SST-22 | Multiplex : startup execute des sous-scripts bloquants (drift-check, fleet-check-coherence) | MEDIUM | Si drift-check.sh boucle ou timeout -> session bloquee au demarrage. Aucun `timeout` wrapping ces appels. **Risque reel** |
| SST-23 | .rpi-target contient une valeur non-reconnue par le case | LOW | `cat $HOME/.rpi-target` = "pi6" -> case ne matche rien -> seul "Cible active : pi6" affiche sans specs RAM/CPU |

---

## Synthese

### Statistiques

| Vague | Scripts | Modes identifies | HIGH | MEDIUM | LOW |
|---|---|---|---|---|---|
| 2.1 | 2 | 21 | 8 | 8 | 5 |
| 2.2 | 5 | 42 | 9 | 17 | 16 |
| 2.3 | 6 | 41 | 12 | 14 | 15 |
| 2.4 | 3 | 33 | 5 | 14 | 14 |
| **Total** | **16** | **137** | **34** | **53** | **50** |

### Bugs potentiels identifies pendant l'analyse

| Script | Mode | Description |
|---|---|---|
| fleet-build-yaml.sh | BLD-05 | Boucle `while true` sur chaine extends sans detection de cycle -> boucle infinie si extends circulaire |
| fleet-session-log.sh | LOG-03 | `$START_TS -eq 0` avec contenu non-numerique dans le fichier start -> bash erreur arithmetique non geree |
| light_on.sh | LON-08 | `touch "$KNOWN_REPOS"` sans `|| true` -> set -e arrete le script si permission denied |
| on-prompt.sh | PRM-09 | `AUTOCOMPACT_PCT_OVERRIDE` non-numerique -> erreur arithmetique bash non geree |
| session-startup.sh | SST-13 | SESSION_ID vide -> sentinel basee sur $PPID (instable) -> re-execution potentielle a chaque prompt |
| session-startup.sh | SST-22 | Sous-scripts (drift-check, fleet-check-coherence, fleet-sanitize-memory) appeles sans timeout -> blocage potentiel au boot |

### Modes FMEA les plus couverts par ce registre

| FMEA Ref | RPN | Modes registre associes |
|---|---|---|
| SF-04 (fleet.yaml corrompu) | 90 | ENV-02, ENV-03, ENV-04, BLD-03, BLD-05, BLD-07 |
| SF-06 (GO-0 inference) | 256 | ENV-09, DIS-01 (injection yq) |
| SF-12 (SPOF starfleet) | 64 | LCH-02, LCH-03, LCH-04, SST-08 |
| SF-14 (source pendant git pull) | 147 | ENV-06 (symlink casse post-pull) |
| EN-03 (suivi taches perdu) | 210 | INB-06, INB-11, PRM-06 |
| EN-04 (ecriture concurrente) | 120 | SND-08, DIS-13 |
| DV-08 (max_turns headless) | 80 | DIS-06, DIS-07 |
