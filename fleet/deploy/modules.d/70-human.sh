#!/usr/bin/env bash
# SOURCE: fleet/deploy/modules.d/70-human.sh
# AUTHOR: DrDree
# STARDATE: 2026-07-05
# STATUS: PROTO-V2 — enrôlement per-humain : ~/.lcars, ~/pods, env seed-once, sondes creds (instruct-only)
# APPLY-ON: any
# CHECK-ON: any
# NEEDS: human
# AFTER: 20-groups

set -euo pipefail
# shellcheck source=../lib/provision-lib.sh
. "${PROVISION_LIB:?PROVISION_LIB non posé — lance via ./provision, pas le module nu}"

HOME_DIR="$(human_home)"
ENV_FILE="$HOME_DIR/.lcars/fleet_v2.env"
TEMPLATE="$PROV_PREFIX/etc/fleet_v2.env.template"

#
# ⚠ ET IL CONVERGE, il ne se seed PAS une fois. C'est l'inverse de `fleet_v2.env` juste en dessous,
# et la différence est le SUJET : l'env est la configuration d'un humain, ce bloc est une limite
# posée sur ce qu'un agent a le droit de faire. Une limite qu'un premier passage pose et qu'aucun
# suivant ne rétablit n'est pas une limite.
# La source vit dans le provisionnement lui-même — pas sous `$PROV_PREFIX/etc` comme le template
# d'env : celui-là dépend de `60-deploy`, et un garde-fou qui n'existe que si un autre module a
# réussi avant lui est absent précisément les jours où il compte.
AUTOMODE_SRC="$(repo_root)/fleet/deploy/agent/claude-automode.json"
CLAUDE_SETTINGS="$HOME_DIR/.claude/settings.json"

# Le fichier porte-t-il DÉJÀ le bloc canonique ? Comparaison sur la valeur normalisée (`jq -S`),
# pas sur les octets : un fichier ré-indenté par le harnais n'est pas une dérive.
automode_current() {
  [[ -r "$CLAUDE_SETTINGS" ]] || return 1
  jq -S -c '.autoMode // {} | {hard_deny, classifyAllShell}' "$CLAUDE_SETTINGS" 2>/dev/null
}
automode_wanted() {
  jq -S -c '{hard_deny, classifyAllShell}' "$AUTOMODE_SRC" 2>/dev/null
}

apply_automode() {
  [[ -r "$AUTOMODE_SRC" ]] || { p_fail "garde-fou d'écriture introuvable ($AUTOMODE_SRC)"; return 1; }
  [[ "$(automode_current)" == "$(automode_wanted)" ]] && return 0

  mkdir -p "$HOME_DIR/.claude" || { p_fail "mkdir ~/.claude"; return 1; }

  local base='{}'
  if [[ -f "$CLAUDE_SETTINGS" ]]; then
    jq -e . "$CLAUDE_SETTINGS" >/dev/null 2>&1 \
      || { p_fail "$CLAUDE_SETTINGS n'est pas du JSON valide — garde-fou NON posé, rien n'a été touché"; return 1; }
    base="$(cat "$CLAUDE_SETTINGS")"
  fi

  local tmp
  tmp="$(mktemp "$HOME_DIR/.claude/.settings.XXXXXX")" || { p_fail "tmp settings"; return 1; }
  # `*` fusionne les objets et REMPLACE les tableaux : les clefs voisines de l'humain survivent,
  # `hard_deny` est repris en entier — une règle à moitié reprise ne garde rien.
  if ! printf '%s' "$base" | jq --slurpfile a "$AUTOMODE_SRC" '.autoMode = ((.autoMode // {}) * $a[0])' > "$tmp"; then
    rm -f "$tmp"; p_fail "fusion du garde-fou en échec"; return 1
  fi
  chmod 0644 "$tmp"
  mv -f "$tmp" "$CLAUDE_SETTINGS" || { rm -f "$tmp"; p_fail "écriture de $CLAUDE_SETTINGS"; return 1; }
  PROV_CHANGED=$((PROV_CHANGED + 1))
  p_chg "garde-fou d'écriture fusionné dans $CLAUDE_SETTINGS (les autres clefs sont intactes)"
}

GITCONFIG_EMAIL() { git config --global --get user.email 2>/dev/null || true; }

# Le compte forge de PROV_HUMAN, en « full_name<TAB>email ». Vide si la forge ne répond pas, si le
# jeton système n'est pas là, ou si ce login n'a pas de compte — trois absences qu'on ne comble pas.
forge_account() {
  [[ -n "$PROV_FORGE_URL" ]] || return 0
  [[ -r "$PROV_SYSTEM_TOKEN_FILE" ]] || return 0
  forge_curl "$PROV_SYSTEM_TOKEN_FILE" -s -m 10 \
       "$PROV_FORGE_URL/api/v1/users/$PROV_HUMAN" 2>/dev/null \
    | jq -r 'if type=="object" and ((.email // "") != "") then "\(.full_name // "")\t\(.email)" else empty end' \
       2>/dev/null || true
}

# La sonde ne PARLE que si cette personne a un compte forge. « Pas de compte » est un fait que
# `50-forge` possède déjà et rapporte ; le redire ici en ferait deux, et deux voix sur un même fait
# divergent le jour où l'une des deux change.
check_git_identity() {
  local mail; mail="$(GITCONFIG_EMAIL)"
  if [[ -n "$mail" ]]; then
    p_ok "identité git posée pour $PROV_HUMAN <$mail> (le fichier lui appartient — on n'y revient pas)"
    return 0
  fi
  local acct; acct="$(forge_account)"
  [[ -n "$acct" ]] || return 0
  p_drift "identité git absente pour $PROV_HUMAN — ses commits signeront <login>@<hostname>, que la forge ne mappe sur aucun compte (ni attribution ni avatar) ; l'apply la pose depuis son compte forge"
}

apply_git_identity() {
  local mail; mail="$(GITCONFIG_EMAIL)"
  [[ -z "$mail" ]] || return 0
  local acct name email
  acct="$(forge_account)"
  if [[ -z "$acct" ]]; then
    return 0
  fi
  name="${acct%%$'\t'*}"
  email="${acct#*$'\t'}"
  [[ -n "$name" ]] || name="$PROV_HUMAN"
  git config --global user.name  "$name"  || { p_fail "git config user.name pour $PROV_HUMAN"; return 1; }
  git config --global user.email "$email" || { p_fail "git config user.email pour $PROV_HUMAN"; return 1; }
  PROV_CHANGED=$((PROV_CHANGED + 1))
  p_chg "identité git posée : $name <$email> (depuis son compte forge — c'est elle qui mappe ses commits, avatar compris)"
}

# Sondes d'identité — verdicts + consignes, AUCUNE mutation, TOUJOURS en warn : les credentials
# sont des gestes de l'humain, un apply ne peut ni les converger ni échouer dessus.
probe_identity() {
  if [[ -f "$HOME_DIR/.claude/.credentials.json" ]]; then
    p_ok "fichier de credentials claude présent — sa VALIDITÉ est tranchée au spawn par le runtime (Credentials.Gate), pas ici"
  else
    p_warn "credentials claude absentes — l'humain lance « claude », /login, bonjour, /exit (geste d'identité, jamais automatisé)"
  fi
  local tokfile code
  tokfile="$(env_field "$ENV_FILE" FORGE_TOKEN_FILE)"
  if [[ -z "$tokfile" ]]; then
    p_warn "aucun FORGE_TOKEN_FILE dans $ENV_FILE — la fleet retomberait sur ~/.gitea_token ; c'est le token système qui doit être câblé (50-forge puis re-apply)"
  elif [[ ! -r "$tokfile" ]]; then
    p_warn "FORGE_TOKEN_FILE=$tokfile illisible par $PROV_HUMAN — la fleet ne pourra pas parler à la forge (groupe $PROV_FLEET_GROUP ?)"
  elif [[ -z "$PROV_FORGE_URL" ]]; then
    p_ok "credential forge de la fleet câblé et lisible ($tokfile ; forge non sondable : URL absente)"
  else
    code="$(forge_curl "$tokfile" -s -o /dev/null -w '%{http_code}' -m 10 "$PROV_FORGE_URL/api/v1/user" 2>/dev/null || echo 000)"
    if [[ "$code" == "200" ]]; then
      p_ok "credential forge de la fleet valide ($tokfile)"
    else
      p_warn "$tokfile présent mais la forge répond $code — token mort ; re-mint par 50-forge (jamais un geste de $PROV_HUMAN)"
    fi
  fi
}

check() {
  [[ -n "$HOME_DIR" && -d "$HOME_DIR" ]] || { p_fail "home de $PROV_HUMAN introuvable"; verdict_check; }

  local d
  # ⚠ `.lcars/log` EST DANS LA BOUCLE, et son absence y etait un angle mort DOUBLE. L'apply le cree
  # par `mkdir -p` puis chmode `.lcars` et `pods` — pas lui : il naissait au umask (0755 mesure chez
  # les deux humains de la machine), alors que la table affirme 0700. Et ce check ne le regardait pas
  # non plus : le doctor serait donc reste aveugle APRES le correctif, sur un repertoire qui porte les
  # journaux d'un humain.
  for d in "$HOME_DIR/.lcars" "$HOME_DIR/.lcars/log" "$HOME_DIR/pods"; do
    if [[ -d "$d" && "$(stat -c '%a %U' "$d")" == "700 $PROV_HUMAN" ]]; then
      p_ok "$d (0700 $PROV_HUMAN)"
    else
      p_drift "$d absent ou pas 0700 $PROV_HUMAN"
    fi
  done

  if [[ -f "$ENV_FILE" ]]; then
    if grep -q '^FORGE_BASE_URL=' "$ENV_FILE"; then
      p_ok "fleet_v2.env présent (FORGE_BASE_URL posé)"
    else
      p_drift "fleet_v2.env présent mais FORGE_BASE_URL manquant — fleet_v2 start refusera ; édite $ENV_FILE"
    fi
    if [[ -r "$PROV_SYSTEM_TOKEN_FILE" ]] && ! grep -q '^FORGE_TOKEN_FILE=' "$ENV_FILE"; then
      p_drift "token système minté mais non câblé dans $ENV_FILE — l'apply le câble (FORGE_TOKEN_FILE + FORGE_BOT_LOGIN), puis « fleet_v2 stop && start »"
    fi
  else
    p_drift "fleet_v2.env absent ($ENV_FILE)"
  fi

  if [[ ! -r "$AUTOMODE_SRC" ]]; then
    p_fail "garde-fou d'écriture introuvable ($AUTOMODE_SRC) — le provisionnement est incomplet"
  elif [[ "$(automode_current)" == "$(automode_wanted)" ]]; then
    p_ok "garde-fou d'écriture des agents en place ($CLAUDE_SETTINGS)"
  else
    p_drift "garde-fou d'écriture absent ou divergent dans $CLAUDE_SETTINGS — l'apply le fusionne, le reste du fichier n'est pas touché"
  fi

  check_git_identity
  probe_identity
  verdict_check
}

apply() {
  [[ -n "$HOME_DIR" && -d "$HOME_DIR" ]] || { p_fail "home de $PROV_HUMAN introuvable"; verdict_apply; }

  mkdir -p "$HOME_DIR/.lcars" "$HOME_DIR/.lcars/log" "$HOME_DIR/pods" || { p_fail "mkdir ~/.lcars ~/pods"; verdict_apply; }
  chmod 0700 "$HOME_DIR/.lcars" "$HOME_DIR/.lcars/log" "$HOME_DIR/pods" || { p_fail "chmod 0700"; verdict_apply; }

  apply_automode

  if [[ ! -f "$ENV_FILE" ]]; then
    if [[ -r "$TEMPLATE" ]]; then
      local tmp
      tmp="$(mktemp "$HOME_DIR/.lcars/.env.XXXXXX")" || { p_fail "tmp env"; verdict_apply; }
      if [[ -n "$PROV_FORGE_URL" ]]; then
        # Le template ne porte AUCUN FORGE_BASE_URL actif (une valeur en dur viserait une forge
        # réelle pour toute boîte seedée) : l'URL connue du provisioning s'APPEND. Un sed sur la
        # ligne du template réécrirait du commentaire et n'injecterait rien.
        { cat "$TEMPLATE"; echo ""; echo "FORGE_BASE_URL=$PROV_FORGE_URL"; } > "$tmp"
      else
        cat "$TEMPLATE" > "$tmp"
      fi
      # L'exposition des listeners est une propriété du DÉPLOIEMENT, pas de l'humain : le runtime
      # lie en loopback par défaut, ce qui dans un conteneur rend le deck injoignable depuis un
      # navigateur (la loopback est celle du conteneur). Elle voyage donc par l'environnement du
      # substrat — et doit atterrir ICI, parce que `fleet_v2` lit ce fichier et non l'environnement
      # du conteneur : un `su - <humain>` repart d'un environnement vierge.
      if [[ -n "${LCARS_BIND_HOST:-}" ]]; then
        { echo ""; echo "LCARS_BIND_HOST=$LCARS_BIND_HOST"; } >> "$tmp"
      fi
      if [[ -r "$PROV_SYSTEM_TOKEN_FILE" ]]; then
        {
          echo ""
          echo "# — posé par le seed 70-human (D4) : les marqueurs système sont signés system_starfleet —"
          echo "FORGE_TOKEN_FILE=$PROV_SYSTEM_TOKEN_FILE"
          echo "FORGE_BOT_LOGIN=$PROV_SYSTEM_ACCOUNT"
        } >> "$tmp"
      fi
      chmod 0600 "$tmp"
      mv -f "$tmp" "$ENV_FILE"
      PROV_CHANGED=$((PROV_CHANGED + 1))
      p_chg "fleet_v2.env seedé depuis le template${PROV_FORGE_URL:+ (FORGE_BASE_URL=$PROV_FORGE_URL)} — désormais À L'HUMAIN, plus jamais réécrit ici"
    else
      p_fail "template absent ($TEMPLATE) — lance d'abord 60-deploy"
    fi
  fi

  if [[ -f "$ENV_FILE" ]] && [[ -n "$PROV_FORGE_URL" ]] \
     && ! grep -q '^FORGE_BASE_URL=' "$ENV_FILE"; then
    local tmpu
    tmpu="$(mktemp "$HOME_DIR/.lcars/.env.XXXXXX")" || { p_fail "tmp env (adresse forge)"; verdict_apply; }
    {
      cat "$ENV_FILE"
      echo ""
      echo "# — posé par 70-human : l'adresse de la forge, connue du provisionnement —"
      echo "FORGE_BASE_URL=$PROV_FORGE_URL"
    } > "$tmpu"
    chmod 0600 "$tmpu"
    mv -f "$tmpu" "$ENV_FILE"
    PROV_CHANGED=$((PROV_CHANGED + 1))
    p_chg "adresse de la forge câblée dans $ENV_FILE (FORGE_BASE_URL=$PROV_FORGE_URL)"
  elif [[ -f "$ENV_FILE" ]] && ! grep -q '^FORGE_BASE_URL=' "$ENV_FILE"; then
    p_drift "fleet_v2.env sans FORGE_BASE_URL et aucune forge connue — fleet_v2 start refusera ; monte la forge (48-forge-host) ou édite $ENV_FILE"
  fi

  # POURQUOI CE N'EST PAS « RÉÉCRIRE LE FICHIER DE L'HUMAIN ». Une clé ABSENTE n'est pas un choix :
  # le runtime ne la lit pas, il RETOMBE sur un dernier recours que sa propre doc nomme ainsi.
  # Une clé PRÉSENTE est un choix, et celui-là on n'y touche jamais — l'humain qui veut un autre
  # jeton écrit une valeur, il n'efface pas une ligne. La convergence porte donc sur le trou, pas
  # sur la décision, et elle ne demande aucune sentinelle pour savoir où elle en est.
  if [[ -f "$ENV_FILE" ]] && [[ -r "$PROV_SYSTEM_TOKEN_FILE" ]] \
     && ! grep -q '^FORGE_TOKEN_FILE=' "$ENV_FILE"; then
    local tmp2
    tmp2="$(mktemp "$HOME_DIR/.lcars/.env.XXXXXX")" || { p_fail "tmp env (câblage)"; verdict_apply; }
    {
      cat "$ENV_FILE"
      echo ""
      echo "# — posé par 70-human (D4) : les marqueurs système sont signés system_starfleet —"
      echo "FORGE_TOKEN_FILE=$PROV_SYSTEM_TOKEN_FILE"
      echo "FORGE_BOT_LOGIN=$PROV_SYSTEM_ACCOUNT"
    } > "$tmp2"
    chmod 0600 "$tmp2"
    mv -f "$tmp2" "$ENV_FILE"
    PROV_CHANGED=$((PROV_CHANGED + 1))
    p_chg "jeton système câblé dans $ENV_FILE (FORGE_TOKEN_FILE + FORGE_BOT_LOGIN) — « fleet_v2 stop && start » pour l'appliquer"
  fi

  apply_git_identity
  probe_identity
  verdict_apply
}

case "${1:?usage: 70-human.sh <check|apply>}" in
  check) check ;;
  apply) apply ;;
  *) p_die "mode inconnu: $1 (check|apply)" ;;
esac
