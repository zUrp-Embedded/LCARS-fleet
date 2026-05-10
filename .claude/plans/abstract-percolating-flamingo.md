# Plan — Audit sécurité et robustesse de la toolchain

## Contexte

Audit complet de l'état actuel de la toolchain fleet (Claude-directives + WSL-setup).
Résultats d'exploration : deux agents ont analysé ~25 scripts shell, hooks, scripts de déploiement, et l'infrastructure /home/commons.

Périmètre : Claude-directives (fleet scripts, hooks, deploy), WSL-setup (provisioning), IPC handoff.

Le système tourne dans un environnement single-user, non exposé réseau. Certains risques sont théoriques dans ce contexte mais réels si la configuration évolue (multi-tenant, CI, accès distant).

## Livrable

Un fichier `docs_and_plans/work/todo/audit-securite-robustesse.md` dans Claude-directives.
Structure : findings classés P0→P3, avec fichiers concernés et actions concrètes.

## Structure du document à créer

### En-tête
- Date d'audit, périmètre, scope

### Section 1 — Injections et sécurité directe (P0)
Findings actionnables maintenant, risque le plus élevé.

**1.1 — fleet-state.sh : injection sed via VAL**
- Fichier : `fleet/fleet-state.sh` (ligne ~34)
- Problème : `UPDATES+=("s|^${KEY}:.*|${KEY}: ${VAL}|")` — si VAL contient `|`, le script sed est corrompu. Exemple : `fleet-state.sh blocker="X|rm -f file"` casse silencieusement la mise à jour STATE.
- Fix : escaper `$VAL` avec `sed 's/|/\\|/g'` ou passer par `perl -pe` sans délimiteur flottant.

**1.2 — wake-instance.sh : aucune authentification IPC**
- Fichier : `fleet/wake-instance.sh`
- Problème : n'importe quel processus peut waker n'importe quelle instance avec un message arbitraire. Pas de whitelist d'appelants.
- Fix : vérifier que l'appelant est un process Claude Code connu (via parent PID ou capability token simple).

**1.3 — fleet-notify.sh : target non validée**
- Fichier : `fleet/fleet-notify.sh`
- Problème : target acceptée sans whitelist — n'importe quelle string est écrite dans le champ notify du handoff.
- Fix : whitelist des instances valides (dev, build-arm, build-x86-64, starfleet, architect, lordzurp, none).

### Section 2 — Robustesse locks et races (P1)
Risques de corruption d'état ou blocage en production.

**2.1 — handoff-lock-acquire.sh : race condition sur stale lock**
- Fichier : `.claude/hooks/handoff-lock-acquire.sh`
- Problème : entre `rm -rf $LOCK_DIR` (steal) et le `mkdir` suivant, une autre instance peut créer le dir → stale lock non récupéré. PPID réutilisé par l'OS → mauvaise instance identifiée comme owner.
- Fix : passer de PPID à `PID:hostname:timestamp` comme owner token. Utiliser `mkdir` + retry avec backoff exponentiel au lieu du sleep fixe.

**2.2 — handoff-lock-release.sh : relâche non-atomique**
- Fichier : `.claude/hooks/handoff-lock-release.sh`
- Problème : check PPID + rm -rf ne sont pas atomiques. Exit 0 même si la relâche échoue → silence sur lock non relâché.
- Fix : valider le owner token complet (PID:hostname:timestamp). Logger l'échec de relâche. Envisager un exit non-0 sur mismatch.

**2.3 — /tmp/handoff-locks : zombie locks après crash**
- Problème : si Claude Code crash pendant un hook, le lock-dir reste dans /tmp indéfiniment (pas de cleanup au boot).
- Fix : ajouter un script `fleet-lock-cleanup.sh` qui supprime les locks > 1h. L'appeler au démarrage de session (session-startup.sh) ou via cron systemd.

**2.4 — session-startup.sh : sentinel PPID réutilisé + jamais nettoyé**
- Fichier : `.claude/hooks/session-startup.sh`
- Problème : `/tmp/claude-session-${PPID}-started` — PPID réutilisé après reboot → une nouvelle session peut croire être déjà démarrée. Les fichiers sentinel s'accumulent dans /tmp.
- Fix : utiliser `$$` (PID courant) + timestamp dans le nom du sentinel. Ajouter un trap EXIT pour nettoyer.

### Section 3 — Validation d'entrées (P1-P2)
Risques de comportement inattendu sur inputs malformés.

**3.1 — post-install.sh : instance type non validé après lecture**
- Fichier : `#0_WSL-setup/post-install.sh` (ligne ~28)
- Problème : `INSTANCE_TYPE=$(cat ~/.wsl-instance-type)` sans whitelist — si le fichier est corrompu (Windows le modifie), le module ne charge pas silencieusement.
- Fix : ajouter le même `case` whitelist que wsl-setup.sh avec fallback `base`.

**3.2 — fleet-state.sh : pas de validation de la structure STATE**
- Fichier : `fleet/fleet-state.sh`
- Problème : si le fichier handoff n'a pas la structure STATE attendue (champs manquants, section absente), sed ne matche rien et le fichier est retourné inchangé sans erreur.
- Fix : vérifier que `## STATE` existe avant d'appliquer les sed. Logger un warning si la section est absente.

**3.3 — fleet-inject.sh, fleet-append.sh, fleet-done.sh : silence si anchor manquant**
- Fichiers : `fleet/fleet-inject.sh`, `fleet/fleet-append.sh`, `fleet/fleet-done.sh`
- Problème : si l'anchor awk (`## DONE`, `## ACTIONS`) est absent ou malformé, le fichier est retourné inchangé sans message d'erreur. L'appelant croit que l'injection a réussi.
- Fix : vérifier la présence de l'anchor avant injection. Sortir avec exit 1 si absent.

**3.4 — on-prompt.sh : échec de fleet-state.sh ignoré silencieusement**
- Fichier : `.claude/hooks/on-prompt.sh`
- Problème : si fleet-state.sh n'est pas trouvé ou échoue, on-prompt.sh sort avec exit 0 sans log. Le dashboard reste à l'état stale.
- Fix : logger un warning si fleet-state.sh est introuvable ou retourne non-0.

### Section 4 — Robustesse des chemins hardcodés (P2)
Fragilité sur changement d'environnement.

**4.1 — wake-instance.sh : chemin WSL hardcodé**
- `/mnt/c/Windows/System32/wsl.exe` — échoue si Windows n'est pas sur C:
- Fix : utiliser `command -v wsl.exe` ou `$(wslpath -w /mnt/c)/Windows/System32/wsl.exe` avec fallback.

**4.2 — deploy.sh : chemins instances hardcodés**
- Assumes `/home/wsl-root/#2_Home/<instance>` — silently skip si structure change.
- Fix : vérifier l'existence du dossier target avant deploy. Log explicite des targets ignorées.

**4.3 — handoff-lock : /tmp non partagé entre instances WSL**
- `/tmp/handoff-locks` est WSL-local (ext4), donc chaque instance a son propre /tmp. Le lock n'est pas cross-instance — il protège uniquement les accès concurrents depuis la même instance Claude Code (multi-thread).
- Implication : la protection contre les writes concurrents de deux instances différentes repose uniquement sur les garanties 9p/drvfs, pas sur le lock système.
- Fix : documenter cette limitation. Évaluer si le lock doit migrer vers /home/commons (drvfs partagé) avec un mécanisme différent (lockfile atomique dans le FS partagé).

**4.4 — handoff-trim.sh : liste d'exempts hardcodée**
- Nouveaux fichiers handoff ne sont pas exemptés automatiquement.
- Fix : lire les exempts depuis un fichier de config ou un pattern configurable.

### Section 5 — Backup et déploiement (P2-P3)
Robustesse des opérations d'infrastructure.

**5.1 — backup-wsl.sh : pas de validation des fichiers attendus**
- Problème : si un fichier critique manque, backup-wsl.sh complète silencieusement. La restauration sera incomplète.
- Fix : liste des fichiers obligatoires. Log explicite des fichiers manquants. Exit non-0 si fichier critique absent.

**5.2 — curl|bash pour Claude Code : pas de vérification d'intégrité**
- Fichier : `post-install.sh` ligne 61
- Problème : `curl -fsSL https://claude.ai/install.sh | bash` sans vérification de hash/signature.
- Acceptable pour un installer officiel Anthropic, mais documenter l'assumption.
- Fix (optionnel) : ajouter un commentaire expliquant pourquoi la vérification n'est pas possible (installer auto-contenu sans hash publié).

**5.3 — deploy.sh : filtrage skills non générique**
- Logique de filtrage cross-arm64 (pas sur build-x86) est hardcodée. Si de nouveaux skills sont ajoutés, le filtre doit être mis à jour manuellement.
- Fix : table de filtrage configurable (YAML ou fichier texte) lue par deploy.sh.

### Section 6 — Architecture IPC (P3 / réflexion)
Pas d'action immédiate — documenté pour réflexion future.

**6.1 — Aucune authentification inter-instances**
- N'importe quelle instance peut écrire dans le handoff d'une autre. Par design (fleet coopératif). Acceptable dans le modèle single-user actuel.
- À reconsidérer si : accès réseau, instances non-locales, ou modèle multi-tenant.

**6.2 — Identité instance = hostname (spoofable)**
- fleet-state.sh, on-prompt.sh, fleet-inject.sh dérivent l'identité de `$(hostname)`.
- Alternative plus robuste : fichier `~/.claude/instance-name` (déjà partiellement implémenté dans post-directional-handoff-reminder.sh).
- Fix : uniformiser l'identité → préférer `instance-name` à `hostname` dans tous les fleet scripts.

## Plan d'implémentation (pour la session d'implémentation)

### Phase 1 — Fixes P0 (Claude-directives uniquement, deploy + push)
1. fleet-state.sh : escape VAL
2. fleet-notify.sh : whitelist target

### Phase 2 — Robustesse locks (Claude-directives)
3. handoff-lock-acquire.sh : owner token PID:hostname:ts, backoff
4. handoff-lock-release.sh : validation + logging
5. session-startup.sh : sentinel PID+ts, trap EXIT cleanup
6. Créer fleet-lock-cleanup.sh + appel dans session-startup.sh

### Phase 3 — Validation + silence (Claude-directives)
7. fleet-state.sh : check structure STATE avant sed
8. fleet-inject.sh / fleet-done.sh / fleet-append.sh : check anchor avant écriture
9. on-prompt.sh : log si fleet-state.sh introuvable

### Phase 4 — WSL-setup
10. post-install.sh : whitelist instance type

### Phase 5 — Documentation
11. /tmp lock limitation cross-instance : documenter dans handoff.md
12. curl|bash : commenter l'assumption dans post-install.sh

## Commits prévus
- Claude-directives : `fix(fleet): security and robustness audit — P0/P1/P2 fixes`
- WSL-setup : `fix(post-install): validate instance type after read`
