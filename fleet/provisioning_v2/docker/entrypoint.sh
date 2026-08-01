#!/usr/bin/env bash
# SOURCE: fleet/provisioning_v2/docker/entrypoint.sh
# AUTHOR: DrDree
# STARDATE: 2026-07-05
# STATUS: PROTO-V2 — entrypoint conteneur : converge le volume d'état puis exec sshd (login-manager)
#
# Modèle (etc/README.md du runtime) : l'humain SSH dans le conteneur EN TANT QUE LUI (sshd = le
# login-manager : auth + drop d'UID, zéro privilège custom) puis lance `fleet_v2 start`. Ce
# script est la transposition Docker du « re-run convergent » : l'image est immutable (build),
# le VOLUME /home converge ICI à chaque boot via LE MÊME `provision` que le chemin WSL.
#
# Un échec de convergence NE TUE PAS le conteneur : la boîte doit rester joignable pour être
# réparée (fail-loud dans les logs, pas fail-dead) — sshd démarre quoi qu'il arrive.
#
# Env d'entrée (compose/docker run) :
#   LCARS_HUMAN     login de l'humain (défaut : lcars) — créé s'il n'existe pas, home persistant
#   LCARS_UID       uid de l'humain (défaut : 1000) — stable = ownership du volume stable
#   LCARS_SSH_AUTHORIZED_KEYS  contenu authorized_keys (sinon : accès par `docker exec` seulement)
#   FORGE_BASE_URL  forge cible (avec le profil compose `forge` : http://forge:3000)

set -euo pipefail

# ─── MODE OUTIL : `verify <racine>` — valider un catalogue SANS booter la boîte ─────────────────
# `docker run --rm -v $PWD:/cat <image> verify /cat` : le code de sortie est le verdict
# (0 = catalogue OK, 1 = refusé), exploitable en CI ; le rapport s'imprime sur stdout et
# déclare ses hypothèses (la racine lue, les surcharges fines ignorées). Ne converge rien,
# ne crée personne : la seule chose exécutée est la release, en eval. Le binaire de release
# est appelé directement — `fleet_v2`, lui, porte le lancement per-humain (RELEASE_TMP dans
# ~/.lcars), des hypothèses qu'un mode outil n'a pas le droit d'avoir.
if [[ "${1:-}" == "verify" ]]; then
  root="${2:?verify: chemin de racine catalogue requis — usage : docker run --rm -v \$PWD:/cat IMAGE verify /cat}"
  # Le runtime REFUSE root (R-no-root-runtime, runtime.exs) et le mode outil respecte
  # l'invariant au lieu de le contourner : l'eval tombe sur nobody:fleet — le gid fleet
  # donne la lecture de l'install RO (/local, root:fleet), nobody ne possède rien d'autre.
  # LCARS_TOOL_EVAL=1 : `release eval` execute les config providers (runtime.exs ENTIER) avant
  # l'expression — ce drapeau saute le corps de config deploiement (ports, forge, credentials),
  # qu'une invocation outil n'a pas a fournir. Sans lui, l'eval exige l'env d'un boot de fleet.
  exec setpriv --reuid 65534 --regid 2000 --clear-groups \
    env HOME=/tmp RELEASE_TMP=/tmp LCARS_TOOL_EVAL=1 \
    /local/LCARS_v2/rel/fleet_umbrella/bin/fleet_umbrella eval \
    "Fleet.Application.CatalogueVerify.eval_main(\"${root}\")"
fi

LCARS_HUMAN="${LCARS_HUMAN:-lcars}"
LCARS_UID="${LCARS_UID:-1000}"
PROVISION=/opt/lcars/fleet/provisioning_v2/provision
HOST_KEYS_DIR=/home/.lcars-container/ssh

say() { echo "[lcars-entrypoint] $*"; }

# ─── 1. L'humain (idempotent — le home vit dans le volume, le user est recréé à l'identique) ─────
if ! getent passwd "$LCARS_HUMAN" >/dev/null; then
  useradd -m -u "$LCARS_UID" -s /bin/bash "$LCARS_HUMAN"
  say "humain $LCARS_HUMAN créé (uid $LCARS_UID)"
fi

if [[ -n "${LCARS_SSH_AUTHORIZED_KEYS:-}" ]]; then
  HOME_DIR="$(getent passwd "$LCARS_HUMAN" | cut -d: -f6)"
  install -d -m 0700 -o "$LCARS_HUMAN" -g "$LCARS_HUMAN" "$HOME_DIR/.ssh"
  # Écriture atomique tmp+mv (doctrine lib) — un crash ne laisse pas un authorized_keys tronqué.
  tmp="$(mktemp "$HOME_DIR/.ssh/.authk.XXXXXX")"
  printf '%s\n' "$LCARS_SSH_AUTHORIZED_KEYS" > "$tmp"
  chmod 0600 "$tmp" && chown "$LCARS_HUMAN:$LCARS_HUMAN" "$tmp"
  mv -f "$tmp" "$HOME_DIR/.ssh/authorized_keys"
  say "authorized_keys posé pour $LCARS_HUMAN"
else
  say "pas de LCARS_SSH_AUTHORIZED_KEYS — accès par « docker exec -it -u $LCARS_HUMAN <ctr> bash » seulement"
fi

# ─── 1bis. Les zones catalogue : /home/projects + /home/projects.work, groupe fleet ──────────────
# Le sanctuaire bwrap des pods monte ces zones (cap-profile starfleet : les deux en rw) —
# ABSENTE, le spawn meurt (« catalogue mount path missing host-side », vu au premier E2E,
# une zone par crash). Sur WSL elles existent (histoire du substrat) ; ICI, l'entrypoint est
# le créateur de zones du conteneur (comme pour l'humain). setgid fleet : chaque humain du
# groupe y crée ses projets/worktrees.
install -d -m 2775 -g fleet /home/projects /home/projects.work
say "zones catalogue : /home/projects /home/projects.work (2775 root:fleet)"

# La SOURCE — l'auto-maintenance en dépend : c'est le checkout que la fleet lit, met à jour
# (`provision update`) et sur lequel ses agents travaillent.
#
# DEUX CHEMINS, ET UN SEUL EST CELUI D'UNE INSTALLATION. Le geste de dév est `./docker.sh
# source-push` : un `docker cp` depuis le clone de l'humain. Qui INSTALLE depuis une image tirée
# d'une registry n'a aucun clone à pousser — il a une URL. Le chemin nominal est donc un CLONE,
# fait ici, et il est possible sans credential : le dépôt est public en lecture (`git ls-remote`
# anonyme mesuré vivant sur la forge).
#
# LA RÈGLE QUI COMPTE : on ne clone que si le dossier est ABSENT. Une source déjà là n'est JAMAIS
# écrasée ni remise à niveau — un redémarrage du conteneur détruirait le travail en cours d'un
# agent, et ce serait le genre de perte qu'on ne remarque qu'après. Mettre à jour est un geste
# explicite (`provision update`), pas un effet de bord du boot.
LCARS_SOURCE_DIR="${LCARS_SOURCE_DIR:-/home/projects/LCARS}"

if [[ ! -d "$LCARS_SOURCE_DIR/.git" && -n "${LCARS_SOURCE_REMOTE:-}" ]]; then
  # `--branch` accepte une branche OU un tag, pas un sha nu : c'est la forme d'une ref publiée,
  # et un sha arbitraire exigerait `allowReachableSHA1InWant` côté serveur — dépendance qu'on ne
  # présume pas. Ref vide = branche par défaut du dépôt.
  clone_args=(--depth 1)
  [[ -n "${LCARS_SOURCE_REF:-}" ]] && clone_args+=(--branch "$LCARS_SOURCE_REF")
  say "clonage de la source : $LCARS_SOURCE_REMOTE${LCARS_SOURCE_REF:+ (ref $LCARS_SOURCE_REF)} → $LCARS_SOURCE_DIR"
  if git clone "${clone_args[@]}" "$LCARS_SOURCE_REMOTE" "$LCARS_SOURCE_DIR" 2>&1 | sed 's/^/[git] /'; then
    # Le clone est fait par root ; la source appartient à l'humain qui travaillera dedans. Le
    # groupe `fleet` parce que c'est celui des zones catalogue posées juste au-dessus.
    chown -R "$LCARS_HUMAN:fleet" "$LCARS_SOURCE_DIR"
    say "source clonée"
  else
    say "CLONAGE ÉCHOUÉ — la boîte démarre sans source (la fleet ne pourra pas se maintenir)"
  fi
fi

# LE CORPUS work/ops — même contrat que les projets nés ici : un projet canon a DEUX arbres,
# `main` (le code, ci-dessus) et `work/ops` (plans, journaux, gate-briefs), checkouté dans le
# dual-dir /home/projects.work/<nom>. Si le remote porte la branche, on la pose ; sinon on le
# dit et la boîte vit sans (une source sans corpus reste maintenable, elle est juste amnésique).
# Même règle de non-écrasement : un dual-dir déjà là n'est jamais touché.
LCARS_WORK_DIR="/home/projects.work/$(basename "$LCARS_SOURCE_DIR")"
if [[ ! -d "$LCARS_WORK_DIR/.git" && -n "${LCARS_SOURCE_REMOTE:-}" ]]; then
  if git ls-remote --exit-code --heads "$LCARS_SOURCE_REMOTE" work/ops >/dev/null 2>&1; then
    say "clonage du corpus work/ops → $LCARS_WORK_DIR"
    if git clone --depth 1 --branch work/ops "$LCARS_SOURCE_REMOTE" "$LCARS_WORK_DIR" 2>&1 | sed 's/^/[git] /'; then
      chown -R "$LCARS_HUMAN:fleet" "$LCARS_WORK_DIR"
      say "corpus work/ops posé"
    else
      say "CLONAGE work/ops ÉCHOUÉ — dual-dir absent (adoptable plus tard, rien de fatal)"
    fi
  else
    say "pas de branche work/ops sur le remote — dual-dir non posé (le corpus arrive par l'adopt)"
  fi
fi

# L'IDENTITÉ GIT DE L'HUMAIN — seed-once, comme fleet_v2.env : sans user.email, git signe
# `<user>@<hostname>` et la forge ne peut mapper le commit sur AUCUN compte (l'attribution
# auteur-humain devient un fantôme sans avatar). L'email doit être CELUI du compte forge de
# l'humain ; il arrive par l'environnement d'install. Absent = dit, jamais inventé.
if [[ -n "${LCARS_HUMAN_EMAIL:-}" ]]; then
  HOME_DIR="$(getent passwd "$LCARS_HUMAN" | cut -d: -f6)"
  if ! su - "$LCARS_HUMAN" -c 'git config --global user.email' >/dev/null 2>&1; then
    su - "$LCARS_HUMAN" -c "git config --global user.name '$LCARS_HUMAN' && git config --global user.email '$LCARS_HUMAN_EMAIL'"
    say "identité git seedée : $LCARS_HUMAN <$LCARS_HUMAN_EMAIL> (à l'humain ensuite)"
  fi
else
  say "LCARS_HUMAN_EMAIL non posé — les commits de l'humain signeront <user>@<hostname>, la forge ne les mappera pas"
fi

if [[ -d "$LCARS_SOURCE_DIR/.git" ]]; then
  # git refuse un repo d'un autre owner (« dubious ownership ») : le clone vient de l'hôte,
  # son uid n'a aucune raison d'être celui du conteneur. Déclaré safe pour TOUS les humains.
  git config --system --replace-all safe.directory "$LCARS_SOURCE_DIR" 2>/dev/null || true
  src_rev="$(git -C "$LCARS_SOURCE_DIR" rev-parse --short=8 HEAD 2>/dev/null || echo '?')"
  say "source LCARS : $LCARS_SOURCE_DIR ($src_rev) — auto-maintenance possible"

  # LE CONTRÔLE QUI FERME LA BOUCLE. Le binaire qui tourne vient de l'IMAGE ; la source vient du
  # clone. Rien ne garantit que ce sont les mêmes commits — et une source en avance est le cas
  # NORMAL (c'est le but de l'auto-maintenance), pas une panne. Ce qui n'est pas normal, c'est de
  # ne pas le savoir : on lit du code qui n'est pas celui qui s'exécute. On déclare l'écart, on ne
  # le corrige pas et on ne bloque rien.
  img_rev="${LCARS_IMAGE_REVISION:-unknown}"
  if [[ "$img_rev" == "unknown" ]]; then
    say "  révision de l'image INCONNUE — écart image/source invérifiable (image bâtie sans GIT_SHA)"
  elif [[ "$src_rev" != "$img_rev" ]]; then
    say "  ÉCART image/source : le runtime qui tourne est bâti sur $img_rev, la source est sur $src_rev"
    say "  (ce n'est pas une panne : lire la source ne renseigne pas sur le binaire, et inversement)"
  else
    say "  image et source sur la même révision ($img_rev)"
  fi
else
  say "PAS de source LCARS sous $LCARS_SOURCE_DIR — la fleet ne peut PAS se maintenir elle-même"
  say "  install : LCARS_SOURCE_REMOTE=<url> [LCARS_SOURCE_REF=<branche|tag>] au démarrage"
  say "  dév     : ./docker.sh source-push (docker cp depuis ton clone)"
fi

# ─── 2. Identité SSH du conteneur : clés d'hôte PERSISTANTES dans le volume ──────────────────────
# (Un conteneur recréé qui change de clés d'hôte = « WARNING: REMOTE HOST IDENTIFICATION HAS
# CHANGED » chez chaque humain — l'identité vit avec l'état, pas avec l'éphémère.)
install -d -m 0700 "$HOST_KEYS_DIR"
if ls "$HOST_KEYS_DIR"/ssh_host_*_key >/dev/null 2>&1; then
  cp "$HOST_KEYS_DIR"/ssh_host_* /etc/ssh/
  chmod 0600 /etc/ssh/ssh_host_*_key
  say "clés d'hôte SSH restaurées depuis le volume"
else
  ssh-keygen -A >/dev/null            # génère dans /etc/ssh les types manquants
  cp /etc/ssh/ssh_host_*_key /etc/ssh/ssh_host_*_key.pub "$HOST_KEYS_DIR/"
  chmod 0600 "$HOST_KEYS_DIR"/ssh_host_*_key
  say "clés d'hôte SSH générées → $HOST_KEYS_DIR (persistantes)"
fi

# ─── 3. Convergence de l'état — LE MÊME provision que le chemin WSL, substrat docker ─────────────
# rc capturé, jamais fatal : le doctor dira la vérité, sshd doit démarrer pour permettre la
# réparation. (Le détail des verdicts est dans les logs du conteneur.)
if "$PROVISION" apply --substrate docker --human "$LCARS_HUMAN"; then
  say "provision apply : convergé"
else
  say "provision apply : AU MOINS UN ÉCHEC (rc=$?) — la boîte démarre quand même ; diagnose : $PROVISION doctor"
fi

# ─── 3bis. La console web (ttyd sous l'humain, port dérivé de son UID) ───────────────────────────
# Lancée APRÈS la convergence (elle a besoin de l'humain et de son home) et AVANT sshd (qui prend
# le premier plan). Son échec n'est pas fatal — même règle que la convergence : la boîte doit
# rester joignable pour être réparée. La console est un CONFORT, ssh reste la porte d'admin.
if [[ "${LCARS_CONSOLE:-1}" == "1" ]]; then
  # `--all` : UNE console par humain éligible, chacune sur SON port dérivé de son uid. La formule
  # donne déjà des ports disjoints, donc le multi-humain ne coûte aucune coordination — pas de
  # proxy, pas de registre, pas d'auth (étape 2). L'éligibilité et la garde anti-système (root et
  # l'uid 1000 partagent le bloc 21000) vivent dans console-humans.sh, source unique.
  /opt/lcars/console.sh --all || say "console web NON lancée (rc=$?) — ssh reste la porte"

  # La home de la boîte : sidebar + statut, sur un port HORS de l'espace des blocs humains. Elle
  # n'appartient à aucun humain — c'est la porte de la boîte. Échec non fatal comme le reste.
  if [[ "${LCARS_LANDING:-1}" == "1" ]]; then
    /opt/lcars/console-landing.sh || say "home NON lancée (rc=$?) — les consoles restent joignables par leur port"
  fi
else
  say "console web désactivée (LCARS_CONSOLE=0)"
fi

# ─── 4. sshd au premier plan (tini est PID 1 : reap + signaux ; exec = sshd reçoit les signaux) ──
say "sshd prêt — ssh $LCARS_HUMAN@<hôte> -p <port mappé> puis « fleet_v2 start »"
exec /usr/sbin/sshd -D -e
