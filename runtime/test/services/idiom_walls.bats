#!/usr/bin/env bats
# SOURCE: runtime/test/services/idiom_walls.bats
# AUTHOR: bob
# STARDATE: 2026-09-04
# STATUS: bats walls — les idiomes qui coutent cher, coté PRODUIT (le jumeau de deploy/tests/idiom_walls.bats)
#
# ⚖ user 2026-09-04 (Q4) : chaque logiciel joue son gate. Le mur I2 de l'installeur ne lit que
# deploy/ ; les gestes que le lot 6 a ramenes cote produit (forge.d, container, le convergeur, forge-gestures)
# parlent a la forge avec un jeton, et un `-H "Authorization: token …"` en argv est lisible par tout
# compte du conteneur dans /proc/<pid>/cmdline. Relecture hostile du 2026-09-04 : le convergeur le
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

# ─── MUR I4 : TOUTE LECTURE DE /dev/urandom EST BORNEE EN TETE DE PIPELINE ────────────────────
#
# `tr -dc … < /dev/urandom | head -c N` lit une source infinie et compte sur `head` pour fermer le
# tuyau : sous `pipefail`, le SIGPIPE du lecteur rend le pipeline non nul, et un `head -c` en aval
# peut fermer avant le dernier write. La forme sure borne la SOURCE (`head -c N /dev/urandom | …`) et
# coupe la longueur par un outil qui lit tout (`cut`). JUMEAU du MUR I4 de `deploy/tests/idiom_walls.bats` :
# celui-la lit deploy/, celui-ci le shell du produit — services/ et bin/.
@test "MUR I4 (produit) : toute lecture de /dev/urandom est BORNEE par un head -c en tete de pipeline" {
  local root f l hits=0 lectures=0
  root="$(cd "$SERVICES/../.." && pwd)"
  local -a bin_sh=()
  mapfile -t bin_sh < <(grep -lE '^#!.*(bash|[^a-z]sh)([[:space:]]|$)' "$root"/runtime/bin/* 2>/dev/null || true)
  [ "${#bin_sh[@]}" -ge 5 ] || { echo "runtime/bin : ${#bin_sh[@]} script(s) shell — le perimetre du mur n'est plus le bon" >&2; return 1; }
  for f in "${SOURCES[@]}" "${bin_sh[@]}"; do
    while IFS= read -r l; do
      lectures=$((lectures + 1))
      grep -qE 'head -c [0-9]+ /dev/urandom' <<<"$l" || { echo "MUR I4 rompu — ${f#"$root"/} : source non bornee : $l" >&2; hits=$((hits + 1)); }
      grep -qE '\|[[:space:]]*head -c' <<<"$l" && { echo "MUR I4 rompu — ${f#"$root"/} : head -c en aval : $l" >&2; hits=$((hits + 1)); }
    done < <(code "$f" | grep -E '(^|[[:space:]<])/dev/urandom' || true)   # une LECTURE, pas un commentaire qui la cite
  done
  [ "$hits" -eq 0 ]
  # GARDE D'INSTRUMENT : le mur voit au moins la lecture du minteur de jetons. A zero lecture, il
  # balaierait un corpus qu'il ne sait plus lire et serait vert par cecite.
  [ "$lectures" -ge 1 ] || { echo "instrument casse : aucune lecture de /dev/urandom vue dans le produit" >&2; return 1; }
  # Le mur mord : la lecture non bornee est vue comme telle, la coupe en aval aussi…
  grep -qE '(^|[[:space:]<])/dev/urandom' <<<'  pw="$(tr -dc A-Za-z0-9 < /dev/urandom | head -c 20)"'
  refute grep -qE 'head -c [0-9]+ /dev/urandom' <<<'  pw="$(tr -dc A-Za-z0-9 < /dev/urandom | head -c 20)"'
  grep -qE '\|[[:space:]]*head -c' <<<'  head -c 200 /dev/urandom | tr -dc A-Z | head -c 10'
  # … et la forme sure passe les deux.
  grep -qE 'head -c [0-9]+ /dev/urandom' <<<'  pw="$(head -c 18 /dev/urandom | base64 | cut -c1-20)"'
  refute grep -qE '\|[[:space:]]*head -c' <<<'  pw="$(head -c 18 /dev/urandom | base64 | cut -c1-20)"'
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
# init.sh` et `container/boot.sh` est l'uid du SIEGE dans le conteneur (pose par le compose), pas une borne
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

# ─── MUR I20 : LE RAIL S'APPELLE `container` — PLUS AUCUN box / boite / boîte COTE PRODUIT ──────
#
# Le couple dit OU LCARS vit : `--workstation` (dans ce système) / le conteneur. `docker` reste le
# mot du SUBSTRAT et de la dependance : le mur ne le regarde pas.
#
# JUMEAU de `deploy/tests/idiom_walls.bats` (MUR I20) : celui-la lit deploy/ et install.sh, celui-ci
# lit le PRODUIT — runtime/services, runtime/bin, runtime/lib, runtime/priv, runtime/config,
# runtime/etc, runtime/test/services — code ET prose (un README qui dit « box up » est un manuel
# faux, un prompt d'agent qui dit « la boite » aussi). Chaque cote grep SES fichiers ; aucun mur ne
# traverse la couture. Il s'ecarte lui-meme : ses formes de garde portent le mot.
#
# Ce qui GARDE le mot, a dessein, et que le mur ecarte par motif :
#   - « boite de reception » (l'inbox d'admiral, skill system-issues), « boite aux lettres »
#     (la branche d'outillage, ops-branch) et « ta boîte » (les tickets d'un agent, vitrine MCP) ;
#   - la boite FERMEE du siege reserve vulcan (« the box is closed », « closed box », « the box
#     opens », « opening the box », « la boîte s'ouvre », « on ouvrira sa boite ») ;
#   - `box-sizing` / `border-box` / `box-shadow` (le CSS du deck, dans console-deck.py) ;
#   - « mail-in-a-box » et « out of the box » (idiomes), et les cadres ASCII `_box_*` de l'installeur.
# `sandbox`, `bwrap`, `mailbox`, `checkbox`, `toolbox` ne sont pas le mot entier : le grep ne les voit pas.
I20_RE='(^|[^[:alpha:]])(box|bo[iîÎ]te)([^[:alpha:]]|$)'
I20_EXCL='box-(sizing|shadow)|border-box|mail-in-a-box|out of the box|bo[iîÎ]tes? de r[éeÉE]ception|bo[iîÎ]tes? aux lettres|_box_(emit|plain|pad)|_prov_box_pad|ta bo[iîÎ]te|box is closed|closed box|box opens|opening the box|bo[iîÎ]te s.ouvre|ouvrira sa bo[iîÎ]te'
I20_PERIMETRE=(runtime/services runtime/bin runtime/lib runtime/priv runtime/config runtime/etc runtime/test/services)

i20_hits() { # <chemin>… -> les lignes qui portent encore le mot, hors motifs ecartes (vide = propre)
  grep -rnIiE --exclude=idiom_walls.bats "$I20_RE" "$@" 2>/dev/null | grep -viE "$I20_EXCL" || true
}

@test "MUR I20 (produit) : plus aucun box / boite / boîte dans le code et la prose du produit — le rail s'appelle container" {
  local root d trouve
  local -a chemins=()
  root="$(cd "$SERVICES/../.." && pwd)"
  for d in "${I20_PERIMETRE[@]}"; do
    [ -d "$root/$d" ] || { echo "$d absent sous $root — le perimetre du mur n'est plus le bon" >&2; return 1; }
    case "$d" in deploy/*) echo "MUR I20 (produit) lit deploy/ : $d — c'est l'affaire du jumeau" >&2; return 1 ;; esac
    chemins+=("$root/$d")
  done
  trouve="$(i20_hits "${chemins[@]}")"
  [ -z "$trouve" ] || { echo "MUR I20 rompu — le mot du rail est container, pas box/boîte :" >&2; printf '%s\n' "$trouve" >&2; return 1; }
  # GARDE D'INSTRUMENT : le mur voit une occurrence plantee dans un decor — un chemin, de la prose
  # accentuee, une variable, un tag, une majuscule — quatre LIGNES, grep -n compte des lignes.
  local decor="$BATS_TEST_TMPDIR/i20"; mkdir -p "$decor"
  printf '#!/usr/bin/env bash\nexec /opt/lcars/services/box/boot.sh\n' > "$decor/a.sh"
  printf 'la boîte tourne, LA BOÎTE aussi\n' > "$decor/b.md"
  printf 'BOX_INIT="${LCARS_BOX_INIT:-}"\n' > "$decor/c.sh"
  printf 'LCARS_MODULE_TAG=box-init ; say "[box-boot]"\n' > "$decor/d"
  [ "$(i20_hits "$decor" | wc -l)" -eq 4 ] || { echo "instrument casse : le mur ne voit pas le decor" >&2; i20_hits "$decor" >&2; return 1; }
  # … et ne voit PAS ce qui garde le mot a dessein.
  printf 'sandbox bwrap mailbox checkbox toolbox SANDBOX\n* { box-sizing:border-box } box-shadow: 0\nla boîte de réception et la boite aux lettres, Boite de reception\nmail-in-a-box\nlivrer out of the box\n_box_emit "x"; _prov_box_pad\npas seulement ta boîte\n# vulcan: the box is closed, (closed box), the box opens. Opening the box\nLE JOUR OÙ LA BOÎTE S'"'"'OUVRE, quand on ouvrira sa boite\n' > "$decor/e.txt"
  trouve="$(i20_hits "$decor/e.txt")"
  [ -z "$trouve" ] || { echo "instrument casse : le mur mord sur une exclusion :" >&2; printf '%s\n' "$trouve" >&2; return 1; }
}
