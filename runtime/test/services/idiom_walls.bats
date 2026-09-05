#!/usr/bin/env bats
# SOURCE: runtime/test/services/idiom_walls.bats
# AUTHOR: bob
# STARDATE: 2026-09-04
# STATUS: bats walls — les idiomes qui coutent cher, coté PRODUIT (le jumeau de deploy/tests/idiom_walls.bats)
#
# ⚖ user 2026-09-04 (Q4) : chaque logiciel joue son gate. Le mur I2 de l'installeur ne lit que
# deploy/ ; les gestes que le lot 6 a ramenes cote produit (forge.d, container, le convergeur, forge-gestures)
# parlent a la forge avec un jeton, et un `-H "Authorization: token …"` en argv est lisible par tout
# compte de la boite dans /proc/<pid>/cmdline. Relecture hostile du 2026-09-04 : le convergeur le
# faisait toutes les 30 s, a vie.

load ../support/refute

setup() {
  SERVICES="$(cd "$BATS_TEST_DIRNAME/../../services" && pwd)"
  mapfile -t SOURCES < <(ls "$SERVICES"/*.sh "$SERVICES"/forge.d/*.sh "$SERVICES"/human.d/*.sh "$SERVICES"/container/*.sh "$SERVICES"/lib/*.sh)
  [ "${#SOURCES[@]}" -ge 15 ]
}
code() { grep -vE '^\s*#' "$1"; }

@test "MUR I2 (produit) : aucun jeton de forge ne passe par argv — un fichier de config sur stdin le porte" {
  local f bad=0
  for f in "${SOURCES[@]}"; do
    if code "$f" | grep -qE -- '-H ["'"'"']?Authorization: token'; then echo "jeton en argv : $f" >&2; bad=1; fi
  done
  [ "$bad" -eq 0 ]
  # temoin du temoin : le motif mord bien la forme interdite et laisse passer la forme voulue
  echo '  curl -s -H "Authorization: token $tok" "$url"' | grep -qE -- '-H ["'"'"']?Authorization: token'
  refute grep -qE -- '-H ["'"'"']?Authorization: token' <<<'  printf '"'"'header = "Authorization: token %s"\n'"'"' "$tok" | curl -K - "$url"'
}

@test "MUR I2 (produit) : les porteurs sont nommes — forge_curl (protocole), hcurl (forge-gestures), le convergeur" {
  grep -qE 'curl -K -' "$SERVICES/lib/module-protocol.sh"
  grep -qE '^hcurl\(\)' "$SERVICES/forge-gestures.sh"
  grep -qE 'curl -s -m 15 -K -' "$SERVICES/human-converger.sh"
}

# ─── MUR I18 : AUCUN LITTERAL 1000 / 60000 COMME REPLI DE BORNE D'UID ──────────────────────────
#
# ⚖ user 2026-09-05 (lot 14, solution A + C + E) : la frontiere systeme/humain est celle que
# `login.defs` declare, et elle est FAIL-CLOSED — le BEAM refuse de booter sans elle (runtime.exs,
# R-no-uid-min), `console-humans.sh` ne rend aucune liste, le protocole (`uid_bounds`) rend non a
# tout le monde. Quatre lecteurs shell devinaient 1000 (et 60000) : ce mur est le temoin du temoin —
# il prouve que le repli n'est plus ECRIT nulle part, dans les quatre fichiers du PRODUIT qui
# lisent la borne.
#
# UN MUR PAR COTE (lot 15). Le cinquieme lecteur, `deploy/lib/provision-lib.sh`, est l'affaire de
# son propre logiciel : son JUMEAU vit dans `deploy/tests/idiom_walls.bats` (MUR I18, meme motif,
# population 1). Chaque cote grep SES fichiers ; aucun mur ne traverse la couture runtime↔deploy.
# Ce que les deux corps ont en commun — la regle — est tenu par un temoin d'EGALITE
# (`deploy/tests/lib/provision-lib.bats`, 4 login.defs × 4 logins), qui lit les deux par nature.
#
# La forme mordue : une ligne de CODE qui porte le nombre 1000 ou 60000 ET parle d'uid. Hors mur,
# et c'est dit ici pour que personne ne l'y ajoute : `LCARS_UID="${LCARS_UID:-1000}"` dans `container/
# init.sh` et `container/boot.sh` est l'uid du SIEGE dans la boite (pose par le compose), pas une borne
# de la frontiere ; et `… / 1000` dans `bin/fleet` convertit des millisecondes.
I18_RE='(^|[^0-9])(1000|60000)([^0-9]|$)'

@test "MUR I18 (produit) : aucun litteral 1000/60000 comme repli de borne d'uid dans les quatre lecteurs du produit" {
  local root f hits=0 pop=0 trouve
  root="$(cd "$SERVICES/../.." && pwd)"
  # LA POPULATION EST NOMMEE, PAS DECOUVERTE : les quatre lecteurs de la borne cote produit — le
  # protocole (la regle), le convergeur et la console (ses appelants), le lanceur (sa copie de cinq
  # lignes, sous temoin d'egalite dans bin/fleet.bats). Aucun chemin de deploy/ ici : le jumeau.
  for f in "$SERVICES/lib/human-protocol.sh" "$SERVICES/human-converger.sh" "$SERVICES/console-humans.sh" \
           "$root/runtime/bin/fleet"; do
    [ -f "$f" ] || { echo "lecteur absent : $f — la population du mur n'est plus de quatre" >&2; return 1; }
    case "$f" in "$root"/deploy/*) echo "MUR I18 (produit) lit deploy/ : $f — c'est l'affaire du jumeau" >&2; return 1 ;; esac
    pop=$((pop + 1))
    trouve="$(code "$f" | grep -nE "$I18_RE" | grep -iE 'uid' || true)"
    if [ -n "$trouve" ]; then
      echo "MUR I18 rompu — ${f#"$root"/} :" >&2
      printf '%s\n' "$trouve" >&2
      hits=$((hits + 1))
    fi
  done
  [ "$hits" -eq 0 ]
  # GARDE D'INSTRUMENT : quatre lecteurs, pas un de moins.
  [ "$pop" -eq 4 ]
  # Le mur mord : les trois formes qui vivaient cote produit, presentees au meme grep, sont vues…
  local forme
  for forme in '  [[ "$_uid_min" =~ ^[0-9]+$ ]] || _uid_min=1000' \
               'uid_min() { awk '"'"'/^UID_MIN/ {print $2}'"'"' "$f" 2>/dev/null | head -n1 || echo 1000; }' \
               '  min="$(uid_min)"; min="${min:-1000}"'; do
    [ -n "$(grep -E "$I18_RE" <<<"$forme" | grep -iE 'uid')" ] || { echo "le mur ne mord pas : $forme" >&2; return 1; }
  done
  # … et les deux hors-mur ne le sont pas : une conversion de millisecondes, un uid a cinq chiffres.
  refute grep -qiE 'uid' <<<"$(grep -E "$I18_RE" <<<'    local _grace_s=$(( ${LCARS_SHUTDOWN_GRACE_MS:-45000} / 1000 ))')"
  refute grep -qE "$I18_RE" <<<'  export LCARS_SYSADMIN_UID=10001'
}
