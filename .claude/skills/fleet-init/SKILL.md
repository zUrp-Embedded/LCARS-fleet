---
name: fleet-init
description: >
  Fleet welcome sequence — first interactive session after onboarding.
  Phase 2 only: guided tour of tmux dashboard, first PoC mission, optional fork.
allowed-tools:
  - Bash
  - Read
when_to_use: >
  Auto-triggered when .deploy_ok present AND .fleet-welcome-pending present.
  See fleet/system-prompt/sources/roles/starfleet.md for the trigger logic.
  Should not be invoked manually — use /onboard_v2 for fresh installs.
---
# Skill: /fleet-init

**Date** : 2026-03-11
**Dernière révision** : 2026-03-15
**Statut** : active — visite guidée post-reboot (Phase 2 uniquement)
**Référencé par** : fleet/system-prompt/sources/roles/starfleet.md (auto-trigger)

Phase 1 (sécurité, git, PAT, deploy) = onboard_v2.
Ce skill = Phase 2 uniquement : premier lancement dans le dashboard après reboot WSL.

Déclencheur : `.deploy_ok` présent + `.fleet-welcome-pending` présent.
Fin : suppression de `.fleet-welcome-pending` → mode normal.

---

## Preamble — read first

```bash
[ -f /home/fleet-state/.deploy_ok ] && echo "DEPLOY_OK" || echo "NO_DEPLOY_OK"
[ -f /home/private/.fleet-welcome-pending ] && echo "WELCOME_PENDING" || echo "WELCOME_DONE"
tmux list-windows 2>/dev/null || echo "NO_TMUX"
```

- If `NO_DEPLOY_OK`: onboarding non terminé — dire à l'user de lancer `/onboard_v2` d'abord.
- If `WELCOME_DONE`: visite déjà faite — passer en mode normal starfleet.
- If `NO_TMUX`: expliquer que ce skill s'exécute depuis le dashboard tmux (`~/start`).
- Otherwise (`DEPLOY_OK` + `WELCOME_PENDING` + tmux actif): démarrer la visite.

---

# PHASE 2 — Visite guidée + premier test

_Context: launched inside tmux via ~/start. StarFleet window._

## Welcome back

Output verbatim:

```
Content de vous retrouver dans le dashboard !

Tout s'est bien passé ? Les agents sont en place.
On commence la visite guidée, puis votre premier test.
```

---

## Step 6 — Visite guidée du dashboard

```bash
tmux list-windows -t fleet 2>/dev/null || true
```

Output verbatim (adapt window names to actual tmux layout):

```
Vous êtes dans une session tmux avec plusieurs fenêtres :

  • monitor   — vue d'ensemble de la fleet (état des agents, alertes)
  • dev       — l'agent développeur, celui qui écrit le code
  • qualifier — l'agent qualité, celui qui teste
  • architect — l'architecte, votre interlocuteur principal
  • terminal  — un shell libre pour vos commandes

Pour naviguer : Ctrl+B puis le numéro de la fenêtre (1, 2, 3…),
ou Ctrl+B puis N/P pour fenêtre suivante/précédente.

L'architecte est celui à qui vous parlez pour tout ce qui concerne
le développement. Il reçoit votre demande, la découpe en tâches,
les distribue à dev et QA, et vous revient avec le résultat.

Moi, je reste ici. Je veille sur l'état général de la fleet.
Vous pouvez revenir me poser des questions à tout moment.
```

---

## Step 7 — PoC : première mission réelle

### 7a — Proposer le PoC

Output verbatim:

```
Passons à votre première mission.

Pour vérifier que toute la chaîne fonctionne, je vous suggère quelque
chose de classique : un script "Hello World !" — une tradition dans
le monde du logiciel.

C'est une suggestion, pas une obligation.
Si vous avez déjà une idée précise, vous pouvez la soumettre directement.

Un point important : la fleet vient d'être provisionnée. Elle est
opérationnelle, mais pas encore rodée — les agents n'ont pas encore
travaillé ensemble sur votre environnement. Même si vous avez l'habitude
des environnements de développement avancés, je vous recommande de
commencer léger. La fleet gagnera en fiabilité au fil des sessions.
```

### 7b — Diriger l'user vers architect

Output verbatim:

```
Quand vous êtes prêt, passez dans la fenêtre architect (Ctrl+B puis
son numéro) et décrivez ce que vous voulez à l'architecte.

Il coordonne dev et QA, et vous revient avec le résultat.

Je reste disponible ici si vous avez des questions en cours de route.
```

Do NOT relay the user's task. Do NOT send anything via fleet-send.sh to engineer.
The user speaks directly to architect from this point.
StarFleet stays in background, available on request.

---

## Step 8 — Post-PoC: fork LCARS (optionnel, fortement recommandé)

Present this verbatim:

```
LCARS est conçu pour fonctionner sur votre propre fork.
Sans fork, vous recevez les mises à jour sans pouvoir personnaliser
votre protocole-user, vos directives, vos agents.
Un fork prend 2 minutes et est quasiment obligatoire
si vous voulez un LCARS qui soit vraiment le vôtre.

Forker maintenant ? [o/n]
```

If user says **n**: skip to Step 10.

If user says **o**:

```bash
cat ~/.ssh/id_ed25519.pub 2>/dev/null || echo "NO_SSH_KEY"
```

If `NO_SSH_KEY`: expliquer que la clé SSH n'a pas été générée — proposer de la créer (`ssh-keygen -t ed25519`), ou utiliser le PAT GitHub déjà configuré via `gh auth`.

If key exists:

```
Ajoutez cette clé à votre compte GitHub :
  https://github.com/settings/ssh/new

Appuyez sur Entrée une fois la clé ajoutée.
```

Wait for confirmation, then test:

```bash
ssh -T git@github.com 2>&1 || true
```

If authenticated: proceed to Step 9.
If not: warn, offer to retry or skip.

---

## Step 9 — Fork instructions

```
Forkez le repo LCARS sur GitHub (bouton "Fork" en haut à droite).
Copiez l'URL SSH de votre fork (git@github.com:<vous>/LCARS-fleet.git).
```

Read fork URL from user, then:

```bash
FLEET_USER=$(grep "^  fleet_user:" ~/.lcars/fleet/fleet.yaml 2>/dev/null | awk '{print $2}')
sudo -u "$FLEET_USER" tee /home/private/directives-repo.conf > /dev/null << EOF
DIRECTIVES_REPO=<URL_FOURNIE>
EOF
echo "directives-repo.conf mis à jour."
```

Verify:

```bash
git ls-remote <URL_FOURNIE> HEAD
```

If OK: confirm to user. If fail: show error, ask to re-enter URL or skip.

---

## Step 10 — Marquer la visite terminée

```bash
sudo rm -f /home/private/.fleet-welcome-pending
echo "[fleet-init] visite terminée — mode normal activé"
```

---

## Step 11 — Handoff to normal mode

```
Configuration terminée.

Je passe en mode normal. Vous pouvez me poser des questions sur
l'état de la fleet, les handoffs, les backlogs en cours.
Tapez votre question ou demande.
```

Switch to normal starfleet behavior: system monitoring, IPC, user questions.
