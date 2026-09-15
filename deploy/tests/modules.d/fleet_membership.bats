#!/usr/bin/env bats
# bats file_tags=structure
# SOURCE: deploy/tests/modules.d/fleet_membership.bats
# AUTHOR: bob
# STARDATE: 2026-09-15
# STATUS: témoin de structure — l'installeur ne met dans fleet que le siège et ses comptes de service nommés ; aucun humain
#
# Le convergeur d'humains est seul juge de l'appartenance d'un humain à fleet : il crée, ajoute et
# révoque d'après la team de la forge. Un geste de l'installeur qui mettrait un humain dans fleet
# (l'humain de la passe, un compte de la plage d'uid) le verrait révoqué au tour suivant (shell
# nologin, processus tués), puis remis à la passe d'après : la boucle du banc 63. Deux cibles restent
# permises, nommées : le siège (SEAT_LOGIN, dérivé de LCARS_SYSADMIN_UID, que le convergeur ne touche
# jamais) et un compte de service des constantes (PROV_*_USER).
#
# Le mur lit tout le code de l'installeur (deploy/ hors de ses témoins, et install.sh) : ensure_member,
# usermod -G, useradd -G, gpasswd -a/-M, adduser <compte> <groupe>, groupmems -a. Un groupe nommé par une
# variable qu'il ne reconnaît pas compte pour fleet. Une commande dans le texte d'un message
# (echo, printf, p_*, fail, die, say, stop) n'est pas une écriture ; le corps de la primitive
# ensure_member (provision-lib.sh) n'a pas de cible à lui.

load ../refute
load ../support/decor

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  MODULES="$REPO/deploy/modules.d"
  CONSTANTES="$REPO/deploy/installer-constants.env"
  [ -d "$MODULES" ]
  [ -f "$CONSTANTES" ]
  # ce témoin ne joue aucun lecteur du siège ni des bornes, il les nomme : le décor tient le mur I19
  decor_pose
}

code_of() { sed 's/#.*//' "$1"; }

# le code de l'installeur : les fichiers texte de deploy/ hors de ses témoins et de sa prose, et install.sh
corpus() {
  { find "$REPO/deploy" -type f -not -path "$REPO/deploy/tests/*" -not -name '*.md' -print
    printf '%s\n' "$REPO/install.sh"
  } | while IFS= read -r f; do grep -Iq . "$f" 2>/dev/null && printf '%s\n' "$f"; done | sort
}

# code_lignes <fichier> — une ligne par ligne du fichier : commentaire ôté, continuation jointe à sa
# première ligne, corps de la primitive ensure_member blanchi
code_lignes() {
  awk '
    /^[[:space:]]*ensure_member\(\)[[:space:]]*\{/ { prim = 1 }
    prim { if ($0 ~ /^\}/) prim = 0; print ""; next }
    {
      l = $0; sub(/(^|[[:space:]])#.*$/, "", l)
      if (acc != "") { acc = acc " " l; vides++ } else { acc = l }
      if (acc ~ /\\$/) { sub(/\\$/, "", acc); next }
      print acc; for (; vides > 0; vides--) print ""; acc = ""
    }
    END { if (acc != "") print acc }
  ' "$1"
}

nu() { local t="$1"; t="${t//\"/}"; t="${t//\'/}"; t="${t//\{/}"; t="${t//\}/}"; printf '%s' "$t"; }

groupe_de_fleet() { # groupe_de_fleet <jeton> → 0 si le groupe est fleet, ou une variable que le mur ne sait pas lire
  local g; g="$(nu "$1")"
  [[ "$g" == fleet || "$g" == '$PROV_FLEET_GROUP' ]] && return 0
  [[ "$g" =~ ^\$PROV_[A-Z_]+_GROUP$ ]] && return 1
  [[ "$g" =~ ^[a-z_][a-z0-9_-]*$ ]] && return 1
  return 0
}

cible_permise() { # cible_permise <jeton> → 0 pour le siège ou un compte de service des constantes
  local u; u="$(nu "$1")"
  [[ "$u" == '$SEAT_LOGIN' ]] && return 0
  [[ "$u" =~ ^\$(PROV_[A-Z_]+_USER)$ ]] && grep -qE "^${BASH_REMATCH[1]}=" "$CONSTANTES" && return 0
  [[ -n "$u" ]] && grep -qE "^PROV_[A-Z_]+_USER=${u}\$" "$CONSTANTES" && return 0
  return 1
}

# ecritures <fichier> — « VU <fichier>:<n> <commande> » pour une écriture permise, « REFUS … » sinon
ecritures() {
  local f="$1" n=0 ligne reste avant cmd guillemets
  local re='(^|[[:space:];&|(`"])(ensure_member|usermod|useradd|gpasswd|adduser|groupmems)[[:space:]]+(.*)$'
  while IFS= read -r ligne; do
    n=$((n + 1))
    reste="$ligne"
    while [[ "$reste" =~ $re ]]; do
      cmd="${BASH_REMATCH[2]}"
      avant="${reste%%"${BASH_REMATCH[0]}"}${BASH_REMATCH[1]}"
      reste="${BASH_REMATCH[3]}"
      guillemets="${avant//[^\"]/}"
      local -a toks=() positionnels=()
      local corps="$reste" user="" grp="" i t
      if (( ${#guillemets} % 2 == 1 )); then
        # dans une chaîne : le texte d'un message n'écrit rien ; « bash -c "usermod …" » écrit
        grep -qE '(^|[[:space:];&|({])(echo|printf|p_[a-z]+|fail|die|say|stop)[[:space:]]' <<<"$avant" && continue
        corps="${corps%%\"*}"
      fi
      corps="${corps%%||*}"; corps="${corps%%&&*}"; corps="${corps%%;*}"; corps="${corps%%|*}"; corps="${corps%%)*}"
      read -ra toks <<<"$corps"
      for t in "${toks[@]}"; do [[ "$t" == -* ]] || positionnels+=("$t"); done
      case "$cmd" in
        ensure_member)
          user="${toks[0]:-}"; grp="${toks[1]:-}" ;;
        usermod|useradd)
          for ((i = 0; i < ${#toks[@]}; i++)); do
            case "${toks[i]}" in
              -G|--groups) grp="${toks[i+1]:-}" ;;
              --groups=*) grp="${toks[i]#--groups=}" ;;
              -[a-zA-Z]*G) grp="${toks[i+1]:-}" ;;
            esac
          done
          [[ -n "$grp" ]] || continue
          user="${toks[${#toks[@]}-1]}" ;;
        gpasswd)
          for ((i = 0; i < ${#toks[@]}; i++)); do
            case "${toks[i]}" in
              -a|--add) user="${toks[i+1]:-}" ;;
              -M|--members) user="(liste)" ;;
            esac
          done
          [[ -n "$user" ]] || continue
          grp="${toks[${#toks[@]}-1]}" ;;
        adduser)
          [[ "${#positionnels[@]}" -eq 2 ]] || continue
          user="${positionnels[0]}"; grp="${positionnels[1]}" ;;
        groupmems)
          for ((i = 0; i < ${#toks[@]}; i++)); do
            case "${toks[i]}" in
              -a|--add) user="${toks[i+1]:-}" ;;
              -g|--group) grp="${toks[i+1]:-}" ;;
            esac
          done
          [[ -n "$user" ]] || continue ;;
      esac
      groupe_de_fleet "$grp" || continue
      if cible_permise "$user"; then
        printf 'VU %s:%d %s %s %s\n' "$f" "$n" "$cmd" "$(nu "$user")" "$(nu "$grp")"
      else
        printf 'REFUS %s:%d %s %s %s\n' "$f" "$n" "$cmd" "$(nu "$user")" "$(nu "$grp")"
      fi
    done
  done < <(code_lignes "$f")
}

@test "aucun module ne lit la population des humains et n'écrit une appartenance de groupe" {
  local m bad=0 lecteurs=0
  for m in "$MODULES"/[0-9][0-9]-*.sh; do
    code_of "$m" | grep -qE 'fleet_humans|prov_uid_bounds' || continue
    lecteurs=$((lecteurs + 1))
    if code_of "$m" | grep -qE 'ensure_member|usermod|gpasswd|adduser'; then
      echo "${m##*/} lit la population des humains et écrit une appartenance de groupe : le convergeur est seul juge de fleet" >&2
      bad=1
    fi
  done
  # garde d'instrument : 64-services lit encore la population ; sans lecteur, le mur ne mesure rien
  [ "$lecteurs" -gt 0 ] || { echo "aucun module ne lit fleet_humans ni prov_uid_bounds : le mur ne lit plus le corpus" >&2; return 1; }
  [ "$bad" -eq 0 ]
}

@test "dans tout l'installeur, une écriture dans fleet ne vise que le siège ou un compte de service nommé" {
  local f sortie="" refus vus
  while IFS= read -r f; do sortie+="$(ecritures "$f")"$'\n'; done < <(corpus)
  refus="$(grep '^REFUS ' <<<"$sortie" || true)"
  [ -z "$refus" ] || {
    echo "écriture dans fleet vers un compte qui n'est ni le siège (\$SEAT_LOGIN) ni un compte de service des constantes :" >&2
    echo "$refus" >&2
    echo "l'appartenance d'un humain à fleet est l'affaire du convergeur d'humains (team de la forge)" >&2
    return 1
  }
  # garde d'instrument : les deux écritures nommées d'aujourd'hui se lisent — sans elles, le mur ne lit plus rien
  vus="$(grep '^VU ' <<<"$sortie" || true)"
  grep -qE '^VU .*/deploy/modules\.d/20-groups\.sh:[0-9]+ ensure_member \$SEAT_LOGIN \$PROV_FLEET_GROUP$' <<<"$vus" \
    || { echo "l'ajout du siège par 20-groups ne se lit plus : $vus" >&2; return 1; }
  grep -qE '^VU .*/deploy/modules\.d/21-service-accounts\.sh:[0-9]+ ensure_member \$PROV_AUTHORITY_USER \$PROV_FLEET_GROUP$' <<<"$vus" \
    || { echo "l'ajout du compte d'autorité par 21-service-accounts ne se lit plus : $vus" >&2; return 1; }
}

@test "le siège que le mur permet est celui de LCARS_SYSADMIN_UID : toute affectation de SEAT_LOGIN en dérive" {
  local f n=0 ligne
  while IFS= read -r f; do
    while IFS= read -r ligne; do
      n=$((n + 1))
      [[ "$ligne" == *LCARS_SYSADMIN_UID* ]] || { echo "SEAT_LOGIN affecté sans LCARS_SYSADMIN_UID dans $f : $ligne" >&2; return 1; }
    done < <(code_lignes "$f" | grep -E '(^|[[:space:];])(local |export |declare [-a-z]+ )?SEAT_LOGIN=' || true)
  done < <(corpus)
  [ "$n" -gt 0 ] || { echo "aucune affectation de SEAT_LOGIN : le siège n'est plus dérivé nulle part" >&2; return 1; }
}

@test "garde d'instrument : le mur refuse chaque forme d'écriture vers un humain, et laisse le siège, le service et les messages" {
  local d="$BATS_TEST_TMPDIR/corpus" sortie
  mkdir -p "$d"
  cat > "$d/refus.sh" <<'EOF'
ensure_member "$PROV_HUMAN" "$PROV_FLEET_GROUP" || verdict_apply
ensure_member "$u" fleet
run_quiet usermod -aG fleet "$login" || return 1
usermod -a -G "$PROV_FLEET_GROUP" zoe
useradd -m -G fleet "$h"
gpasswd -a "$h" "$PROV_FLEET_GROUP"
gpasswd -M "$liste" fleet
adduser "$h" fleet
groupmems -a "$h" -g fleet
for g in "$PROV_FLEET_GROUP" "$PROV_CONSOLE_GROUP"; do ensure_member "$h" "$g"; done
bash -c "usermod -aG fleet $h"
getent passwd | while read -r l; do \
  ensure_member "${l%%:*}" "$PROV_FLEET_GROUP"; done
EOF
  cat > "$d/permis.sh" <<'EOF'
ensure_member "$SEAT_LOGIN" "$PROV_FLEET_GROUP" || verdict_apply
ensure_member "$PROV_AUTHORITY_USER" "$PROV_FLEET_GROUP" || true
usermod -aG fleet lcars-authority
ensure_member "$h" "$PROV_CONSOLE_GROUP"
usermod -aG docker "$h"
gpasswd -d "$h" fleet
adduser --system "$h"
echo "ajouter le compte au groupe : « sudo usermod -aG $grp $me »"
p_fail "ensure_member: user inconnu: $user"
# ensure_member "$PROV_HUMAN" "$PROV_FLEET_GROUP"
ensure_member() {
  run_quiet usermod -aG "$grp" "$user" || return 1
}
EOF
  sortie="$(ecritures "$d/refus.sh")"
  [ "$(grep -c '^REFUS ' <<<"$sortie")" -eq 12 ] || { echo "$sortie"; return 1; }
  refute grep -q '^VU ' <<<"$sortie"
  sortie="$(ecritures "$d/permis.sh")"
  refute grep -q '^REFUS ' <<<"$sortie" || { echo "$sortie"; return 1; }
  [ "$(grep -c '^VU ' <<<"$sortie")" -eq 3 ] || { echo "$sortie"; return 1; }
}
