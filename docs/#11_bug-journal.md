# Bug journal — LCARS Fleet

**Date** : 2026-03-03
**Dernière révision** : 2026-03-21
**Statut** : journal actif
**Référencé par** : fleet/system-prompt/sources/organisation/workflow.md

Errors encountered and fixed during fleet development.
Newest first. Format: Symptôme / Cause / Fix / Commits / Notes.

> **Note terminologique** : les entrées ci-dessous sont historiques. Certaines réfèrent des noms depuis renommés (`steward` → `starfleet`, `/home/commons/handoff/` → `/home/handoffs/`, `LCARS-fleet` → `LCARS`). Les entrées ne sont pas modifiées — elles reflètent l'état au moment du bug.

---

## 2026-03-08 — GIT_AUTHOR_NAME identique sur toutes les instances

**Symptôme** : tous les agents commitent sous le même nom — impossible de tracer quel agent a produit quel commit.

**Cause** : `post-install.sh` lit `git-identity.conf` (commun) et applique le même `user.name` partout.

**Fix** : `git config --global user.name "LCARS-<role>"` en fin de chaque `post-install-<role>.sh`.

**Convention** : `LCARS-dev`, `LCARS-builder`, `LCARS-qualifier`, `LCARS-starfleet`, `LCARS-engineer`.

---

## 2026-03-08 — fleet-broker.py : write non-atomique + STATE corrompu + message long

**Symptômes** :
1. `update_state()` : read→write non-atomique → corruption silencieuse du handoff
2. `ref:` absent du STATE si vide → format invalide (6 lignes au lieu de 7)
3. `blocker/waiting/notify` toujours écrasés à `none` — perte des valeurs existantes
4. `build-arm` absent du `HANDOFF_MAP`
5. `wake-instance.sh` : `send-keys -l` lent pour messages >200 chars

**Fix** :
1-3. `update_state()` : lit valeurs existantes via regex, toujours inclut `ref:`, écrit via `tempfile.mkstemp()` + `os.replace()`
4. Ajout dans `HANDOFF_MAP`
5. `tmux set-buffer` + `paste-buffer` si `${#msg} > 200`

---

## 2026-03-08 — deploy.sh échoue silencieusement + paths handoff incorrects

**Symptômes** :
1. deploy.sh s'arrête à mi-chemin — scripts instance non mis à jour
2. 24 scripts utilisaient un ancien chemin handoff
3. Consistency check cherchait CLAUDE.md au mauvais endroit

**Fix** :
1. `mkdir -p "$(dirname "$DST_FILE")"` avant chaque `cp`
2. sed propagation du nouveau chemin sur 24 fichiers
3. Correction du path source

**Pattern** : deploy partiel silencieux — `set -e` tue sans message sur la ligne fautive.

---

## 2026-03-05 — Paths `~/.lcars/fleet/` morts post-migration ext4

**Tags** : [resolved] [session-startup] [skills] [migration]

**Symptôme** : qualifier BLOCKED — `drift-check.sh` introuvable. Scripts référençaient l'ancien symlink `~/.lcars` supprimé lors de la migration.

**Fix** : paths corrigés vers `$HOME/.local/bin/` (distribué via INSTANCE_UTILS).

**Pattern canonique établi** : tout script distribué passe par `fleet/` + INSTANCE_UTILS + `~/.local/bin/`. Jamais `~/.lcars/`.

**Commits** : `9f222f7`, `d03513d`

---

## 2026-03-04 — Execute bit strippé (drvfs + tmp→rename)

**Tags** : [resolved] [toolbox] [drvfs]

**Symptôme** : script non exécutable après traitement par `apply-headers.py`.

**Cause** : `tmp.rename(filepath)` sur drvfs (NTFS) ne préserve pas les modes Unix.

**Fix** : `chmod +x` + `git update-index --chmod=+x`.

**Commit** : `7b06835`

**Classe de bug récurrente sur drvfs** — toute opération de remplacement de fichier hors script peut ré-introduire le problème.

---

## 2026-03-03 — Workers lancent le mauvais rôle (migration tmux)

**Tags** : [resolved] [engineer]

**Symptôme** : tous les panes workers affichent Claude Code en contexte du mauvais agent.

**Cause** : `/mnt/c` non monté sur l'instance hébergeant tmux — `wsl.exe -d <distro>` échoue silencieusement.

**Fix** : entrée drvfs manquante dans `/etc/fstab`.

---

## 2026-03-06 — WSLInterop : flag P manquant

**Tags** : [resolved] [steward]

**Symptôme** : `-d dev` interprété comme commande shell au lieu d'argument wsl.exe.

**Cause** : binfmt_misc sans flag `P` (preserve argv[0]).

**Fix** : `:WSLInterop:M::MZ::/init:P` dans `/etc/binfmt.d/WSLInterop.conf` + guards runtime.

**Commits** : `73339c7`, `35d7d71`

---

## 2026-03-06 — WSLInterop non persistant après reprise WSL2

**Tags** : [resolved] [steward]

**Symptôme** : `Exec format error` après reprise WSL2 sans reboot.

**Cause** : drop-in systemd WSL écrase `/etc/binfmt.d/` quand `protectBinfmt=true`.

**Fix** : `protectBinfmt=false` dans `/etc/wsl.conf` + `/etc/binfmt.d/WSLInterop.conf` pour registration permanente.

**Commits** : `9d6063c`, `73339c7`, `35d7d71`

---

## 2026-03-06 — tmux split-window "size missing" en session détachée

**Tags** : [resolved] [steward]

**Symptôme** : `-p N` (pourcentage) requiert un client attaché.

**Fix** : remplacer `-p 30` par `-l 12` (taille absolue).

**Commit** : `fe12dfa`

---

## 2026-03-06 — Workers lancent le mauvais rôle (CLAUDE_DELAY trop court)

**Tags** : [resolved] [steward]

**Symptôme** : distros WSL2 à l'état STOPPED mettent 5-10s à booter. `CLAUDE_DELAY=2s` insuffisant.

**Fix** : `CLAUDE_DELAY=15`.

**Commit** : `fe12dfa`
