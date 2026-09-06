#!/usr/bin/env bats
# SOURCE: deploy/tests/idiom_walls.bats
# AUTHOR: bob
# STARDATE: 2026-08-30
# STATUS: murs d'idiomes — la forme fragile ne revient pas une fois le code corrige
#
# Chaque mur remplace un commentaire qui defendait le code contre une simplification : le
# commentaire disait « ne fais pas ca », le mur le mesure. Il grep le CODE seul, jamais la prose.

load refute

setup() {
  DEPLOY="$BATS_TEST_DIRNAME/.."
  mapfile -t SOURCES < <(ls "$DEPLOY"/modules.d/*.sh "$DEPLOY"/lib/*.sh "$DEPLOY"/provision)
  # Temoin de non-cecite : un mur qui grep une liste VIDE est vert, et le dit comme un succes. Le
  # plancher tient sous la population reelle, assez pres pour crier si le `ls` se met a ne plus
  # rien trouver. Il se regle donc a la baisse quand un fichier quitte legitimement le corpus —
  # ce qui est un geste VISIBLE, et c'est tout ce qu'on lui demande.
  [ "${#SOURCES[@]}" -ge 25 ]
}

code() { grep -vE '^[[:space:]]*#' "$1"; }   # une ligne qui COMMENCE par # est de la prose

@test "MUR I1: write_atomic n'est jamais nourri par une substitution de processus" {
  # `write_atomic … < <(fn)` : si `fn` echoue, `cat` lit un flux vide, le fichier est ecrit vide et
  # le rc est 0. La forme sure capture d'abord : `body="$(fn)" || refus ; write_atomic … <<<"$body"`.
  local f hits=0
  for f in "${SOURCES[@]}"; do
    if code "$f" | grep -qE 'write_atomic[^|]*< <\('; then
      echo "MUR I1 rompu — $f : write_atomic nourri par < <( )" >&2; hits=$((hits+1))
    fi
  done
  [ "$hits" -eq 0 ]
  # le mur mord : la forme interdite, presentee au meme grep, est vue
  echo '  write_atomic "$f" 0644 root < <(body)' | grep -qE 'write_atomic[^|]*< <\('
}

@test "MUR I1bis: write_atomic n'est jamais la cible d'un pipe" {
  # `fn | write_atomic` : le dernier element d'un pipeline tourne dans un sous-shell, les compteurs
  # p_fail/p_chg de write_atomic y meurent. Redirection ou here-string, jamais un pipe.
  local f hits=0
  for f in "${SOURCES[@]}"; do
    if code "$f" | grep -qE '(^|[^|])\|[[:space:]]*write_atomic'; then
      echo "MUR I1bis rompu — $f : write_atomic en aval d'un pipe" >&2; hits=$((hits+1))
    fi
  done
  [ "$hits" -eq 0 ]
  echo '  body_fn | write_atomic "$f" 0644' | grep -qE '(^|[^|])\|[[:space:]]*write_atomic'
  # et un `||` (repli) n'est pas un pipe : le mur ne le prend pas pour tel
  refute grep -qE '(^|[^|])\|[[:space:]]*write_atomic' <<<'  x || write_atomic "$f" 0644'
}

@test "MUR I2: aucun jeton de forge ne passe par argv — forge_curl le porte sur stdin" {
  # `-H "Authorization: token $tok"` met le jeton dans la ligne de commande, lisible dans /proc de
  # tout l'hote pendant l'appel (cicatrice 6-141). La lib porte `forge_curl`, qui le passe par
  # `-K -`. Un module qui a besoin d'un en-tete d'autorisation l'appelle, il ne refait pas curl.
  local f hits=0
  for f in "${SOURCES[@]}"; do
    if code "$f" | grep -qE -- '-H ["'"'"']?Authorization: token'; then
      echo "MUR I2 rompu — $f : jeton en argv" >&2; hits=$((hits+1))
    fi
  done
  [ "$hits" -eq 0 ]
  echo '  curl -s -H "Authorization: token $tok" "$url"' | grep -qE -- '-H ["'"'"']?Authorization: token'
  # la forme sure — un en-tete ecrit dans une config lue sur stdin — n'est pas prise pour la fragile
  refute grep -qE -- '-H ["'"'"']?Authorization: token' <<<'  printf '"'"'header = "Authorization: token %s"\n'"'"' "$tok" | curl -K - "$url"'
}

# Derniere instruction d une fonction : `[[ … ]] && cmd` sans `||`. Sous set -e, le rc du test
# devient celui de la fonction, et un appelant qui capture par affectation — `x="$(f)"` — meurt sans
# verdict. Un PREDICAT (nom en `_ok`) est exempte : son rc EST son contrat, ses appelants sont des if.
I3_AWK='
  FNR==1 { fn="" }
  /^[a-z_][a-z0-9_]*\(\)[ \t]*\{/ { fn=$1; sub(/\(\).*/, "", fn); last=""; next }
  fn!="" && /^\}/ {
    if (last ~ /^[ \t]*\[\[.*\]\][ \t]*&&[ \t]/ && last !~ /\|\|/ && fn !~ /_ok$/) print FILENAME ": " fn
    fn=""; next
  }
  fn!="" && !/^[ \t]*(#|$)/ { last=$0 }
'

@test "MUR I3: aucune fonction ne finit sur [[ … ]] && cmd — son rc tuerait l appelant qui l affecte" {
  local hits
  hits="$(awk "$I3_AWK" "${SOURCES[@]}")"
  [ -z "$hits" ] || { echo "MUR I3 rompu —" >&2; echo "$hits" >&2; false; }
  # le mur mord : une fonction fautive est vue, un predicat _ok ne l est pas
  printf 'get_x() {\n  [[ -n "$x" ]] && echo "$x"\n}\nx_ok() {\n  [[ -x "$b" ]] && "$b" --version\n}\n' > "$BATS_TEST_TMPDIR/probe.sh"
  [ "$(awk "$I3_AWK" "$BATS_TEST_TMPDIR/probe.sh")" = "$BATS_TEST_TMPDIR/probe.sh: get_x" ]
}

@test "MUR I4: toute lecture de /dev/urandom est BORNEE par un head -c en tete de pipeline" {
  # `tr -dc … < /dev/urandom | head -c N` : tr lit un flux infini, head ferme le tuyau, tr meurt de
  # SIGPIPE — et sous pipefail c est le rc du pipeline. `head -c N /dev/urandom | …` en tete est la
  # seule forme qui termine par elle-meme. Et un `| head -c` EN AVAL d un flux fini peut encore
  # fermer le tuyau avant le dernier write de l amont — latent, il depend du buffer. La longueur se
  # borne par `cut -c1-N`, qui lit tout et ne ferme rien.
  local f l hits=0
  for f in "${SOURCES[@]}"; do
    while IFS= read -r l; do
      grep -qE 'head -c [0-9]+ /dev/urandom' <<<"$l" || { echo "MUR I4 rompu — $f : source non bornee : $l" >&2; hits=$((hits+1)); }
      grep -qE '\|[[:space:]]*head -c' <<<"$l" && { echo "MUR I4 rompu — $f : head -c en aval : $l" >&2; hits=$((hits+1)); }
    done < <(code "$f" | grep -E '(^|[[:space:]<])/dev/urandom' || true)   # une LECTURE, pas un message qui le cite
  done
  [ "$hits" -eq 0 ]
  refute grep -qE 'head -c [0-9]+ /dev/urandom' <<<'  tr -dc A-Z < /dev/urandom | head -c 10'
  grep -qE '\|[[:space:]]*head -c' <<<'  head -c 200 /dev/urandom | tr -dc A-Z | head -c 10'
}

@test "MUR I5: l architecture se demande a arch_tag — dpkg et uname -m ne se lisent dans aucun module" {
  # Trois modules mappaient dpkg vers le vocabulaire d une release, chacun a sa facon. Une seule
  # table, dans la lib. `00-preflight` garde son `uname -m` : il verifie le NOYAU (x86_64, aarch64),
  # pas le nom d un tarball — l exemption est nommee, pas devinee.
  local f hits=0
  for f in "$DEPLOY"/modules.d/*.sh; do
    if code "$f" | grep -q 'dpkg --print-architecture'; then echo "MUR I5 rompu — $f : dpkg" >&2; hits=$((hits+1)); fi
    [[ "$f" == */00-preflight.sh ]] && continue
    if code "$f" | grep -q 'uname -m'; then echo "MUR I5 rompu — $f : uname -m" >&2; hits=$((hits+1)); fi
  done
  [ "$hits" -eq 0 ]
  code "$DEPLOY/lib/provision-lib.sh" | grep -q 'dpkg --print-architecture'
}

@test "MUR I6: comm ne se lit dans aucun module — set_diff trie lui-meme" {
  # `comm` exige des entrees triees et, sur GNU, ne le verifie pas : deux listes dans le mauvais
  # ordre rendent un resultat faux sans un mot. Sur uutils il le verifie — l instrument de la machine
  # de dev ne dit pas ce que fait la cible. Une seule table de difference, dans la lib.
  local f hits=0
  for f in "$DEPLOY"/modules.d/*.sh; do
    if code "$f" | grep -qE '\bcomm -'; then echo "MUR I6 rompu — $f" >&2; hits=$((hits+1)); fi
  done
  [ "$hits" -eq 0 ]
  code "$DEPLOY/lib/provision-lib.sh" | grep -qE '^set_diff\(\)'
}

@test "MUR I7: une valeur d un fichier d environnement se lit par env_field, jamais par un sed nu" {
  # `x="$(sed -n 's/^CLE=//p' "$f" | tail -n1)"` : sur un fichier absent sed rend 2, pipefail le
  # propage, l affectation echoue et set -e tue la fonction AVANT le if qui savait dire l absence.
  # Trois sites portaient la forme ; un seul avait son `|| true`.
  local f hits=0
  for f in "$DEPLOY"/modules.d/*.sh; do
    if code "$f" | grep -qE "sed -n ['\"]s/\^[A-Z_]+=//p['\"]"; then echo "MUR I7 rompu — $f" >&2; hits=$((hits+1)); fi
  done
  [ "$hits" -eq 0 ]
  echo '  x="$(sed -n '"'"'s/^LCARS_X=//p'"'"' "$f" | tail -n1)"' | grep -qE "sed -n ['\"]s/\^[A-Z_]+=//p['\"]"
}

@test "MUR I8: un fichier de jeton se lit par read_token ou forge_curl — jamais par une redirection nue" {
  # `tr < "$X_TOKEN_FILE" 2>/dev/null` : la redirection d'entree est appliquee AVANT le detournement
  # de stderr, et quand le fichier manque c'est le shell qui crie « No such file » sur le vrai
  # stderr. `{ …; } 2>/dev/null` le tait, mais cette forme ne tient que par un commentaire.
  local hits=0 f
  for f in "$BATS_TEST_DIRNAME"/../modules.d/*.sh; do
    if code "$f" | grep -qE '<[[:space:]]*"?\$[A-Za-z_]*TOKEN_FILE' || code "$f" | grep -qF "tr -d '[:space:]' <"; then echo "MUR I8 rompu — $f" >&2; hits=$((hits+1)); fi
  done
  [ "$hits" -eq 0 ]
}

@test "MUR I9: un temoin dont le code nomme une fonction du siege pose LCARS_SEAT_UID_FILE — il ne lit jamais celui de la machine" {
  # `prov_seat_uid` lit `/etc/lcars/seat.uid` AVANT `LCARS_SYSADMIN_UID`, et ce fichier existe sur
  # toute machine provisionnee. Un temoin sans decor y lit le siege reel — celui qui joue le gate —
  # et tout ce qu'il attend d'un humain « qui passe GUARD B » rougit au second run (banc .63,
  # 2026-08-30 : vert a l'install, rouge au re-run). Le scrub du shell_gate ne peut rien : c'est un
  # DEFAUT de chemin, pas une variable. Perimetre : le CODE des temoins (une ligne `#` ne lit rien).
  local f bad=0
  for f in "$BATS_TEST_DIRNAME"/*.bats; do
    [[ "$f" == */idiom_walls.bats ]] && continue
    grep -vE '^[[:space:]]*#' "$f" | grep -qE 'is_fleet_human|prov_seat_uid|fleet_humans|uid_floor' || continue
    grep -qE '^[[:space:]]*export LCARS_SEAT_UID_FILE=' "$f" || { echo "${f##*/} nomme une fonction du siege sans poser LCARS_SEAT_UID_FILE"; bad=1; }
  done
  [ "$bad" -eq 0 ]
}

@test "MUR I19: un temoin qui pose une population (PASSWD_FILE) ou nomme un lecteur des bornes pose aussi PASSWD_DEFS — il ne lit jamais le login.defs de la machine" {
  # `prov_uid_bounds` lit `/etc/login.defs` ; `is_fleet_human` et `fleet_humans` en dependent, et
  # `64-services` les joue a chaque check (`probe_fleet_humans`). Un decor qui pose un /etc/passwd
  # sans poser ses bornes decrit une machine a moitie : sur un poste dont UID_MIN vaut 5000, ou dont
  # login.defs est illisible, ses humains de decor changent de nature — vert ici, rouge ailleurs,
  # pour un code identique. Vu : 64-services.bats (lot 15). Perimetre : le CODE des temoins, a tous
  # les etages (I9 ne lit que le premier) ; 22-fleet-human.bats est le modele.
  local f bad=0 vus=0
  for f in "$BATS_TEST_DIRNAME"/*.bats "$BATS_TEST_DIRNAME"/*/*.bats; do
    [[ "$f" == */idiom_walls.bats ]] && continue
    # capture puis test (DI-12) : aucun `grep -q` ne ferme un tuyau. `LCARS_PASSWD_FILE` (le seam
    # de 21-service-accounts) n'est pas une population d'humains : il ne compte pas.
    [[ -n "$(grep -vE '^[[:space:]]*#' "$f" | grep -E '(^|[^A-Z_])PASSWD_FILE=|is_fleet_human|fleet_humans|prov_uid_bounds')" ]] || continue
    vus=$((vus + 1))
    grep -qE '^[[:space:]]*export PASSWD_DEFS=' "$f" \
      || { echo "${f##*/} pose une population ou nomme un lecteur des bornes sans poser PASSWD_DEFS"; bad=1; }
  done
  [ "$vus" -ge 3 ] || { echo "seulement $vus temoin(s) dans le perimetre — l'instrument ne lit plus le corpus"; return 1; }
  [ "$bad" -eq 0 ]
}

# ─── MUR I21 : UN TEMOIN QUI EXECUTE UN LECTEUR DU CANAL POSE LCARS_CHANNEL_FILE ─────────────
#
# `prov_channel` lit `/etc/lcars/channel` en tete du dispatch de 44, 46, 60 et 62 (lot 2 du chantier
# release), et ce fichier existe sur toute machine posee. Un temoin sans decor y lit le canal REEL :
# sur un poste installe par paquet, `apply` ne poserait plus rien, et rien ne dirait pourquoi — le
# meme defaut que le siege (MUR I9), sur un autre fichier. Perimetre : le CODE des temoins qui
# EXECUTENT un de ces quatre modules — `bash …/<module>.sh` en clair, ou `bash "$VAR"` quand `VAR=`
# lui a ete assigne au niveau du fichier (un `local` ne compte pas : `doctor_honnete` assigne `mod`
# a 62 pour le LIRE et joue `bash "$mod"` sur un autre module deux tests plus loin).
I21_MODS='(44-media|46-tofu|60-deploy|62-runtime-helpers)\.sh'
@test "MUR I21: un temoin qui EXECUTE un module lecteur du canal (44, 46, 60, 62) pose LCARS_CHANNEL_FILE — il ne lit jamais le canal de la machine" {
  local f bad=0 vus=0 c execute v
  while IFS= read -r f; do
    [[ "$f" == */idiom_walls.bats ]] && continue
    c="$(grep -vE '^[[:space:]]*#' "$f")"
    grep -qE "$I21_MODS" <<<"$c" || continue
    execute=0
    grep -qE "bash \"?\\\$?[^\" ]*$I21_MODS\"?( |\$)" <<<"$c" && execute=1
    for v in $(grep -E "(^|[[:space:]{;])(export )?[A-Za-z_]+=[^;]*$I21_MODS" <<<"$c" | grep -vE '(^|[[:space:]{;])local [A-Za-z_]+=' \
                 | sed -E "s/.*(^|[[:space:]{;])(export )?([A-Za-z_]+)=[^;]*$I21_MODS.*/\3/" | sort -u); do
      grep -qE "bash \"?\\\$$v\"?( |\$)" <<<"$c" && execute=1
    done
    [ "$execute" -eq 1 ] || continue
    vus=$((vus + 1))
    grep -qE '^[[:space:]]*export LCARS_CHANNEL_FILE=' <<<"$c" \
      || { echo "${f#"$DEPLOY"/} execute un lecteur du canal sans poser LCARS_CHANNEL_FILE"; bad=1; }
  done < <(find "$DEPLOY/tests" -name '*.bats' | sort)
  [ "$bad" -eq 0 ]
  # GARDE D INSTRUMENT : les quatre temoins de module et deploy_manifest au moins
  [ "$vus" -ge 5 ] || { echo "instrument casse : $vus temoin(s) vu(s), 5 au moins attendus" >&2; return 1; }
  # le mur mord : un temoin qui execute 60 par sa copie, ou par une variable du fichier, est VU
  local ech="$BATS_TEST_TMPDIR/ech.bats" seen
  printf '%s\n' 'MOD="$X/modules.d/62-runtime-helpers.sh"' 'run bash "$MOD" check' > "$ech"
  seen="$(grep -vE '^[[:space:]]*#' "$ech")"
  v="$(grep -E "(^|[[:space:]{;])(export )?[A-Za-z_]+=[^;]*$I21_MODS" <<<"$seen" | sed -E "s/.*(^|[[:space:]{;])(export )?([A-Za-z_]+)=[^;]*$I21_MODS.*/\3/")"
  [ "$v" = MOD ] && grep -qE "bash \"?\\\$$v\"?( |\$)" <<<"$seen"
  grep -qE "bash \"?\\\$?[^\" ]*$I21_MODS\"?( |\$)" <<<'run bash "$BATS_TEST_TMPDIR/60-deploy.sh" check'
  # et ne mord pas sur un LECTEUR : `local mod=` puis un grep
  grep -E "(^|[[:space:]{;])(export )?[A-Za-z_]+=[^;]*$I21_MODS" <<<'  local mod="$DEPLOY/modules.d/62-runtime-helpers.sh"' \
    | refute_out '(^|[[:space:]{;])local [A-Za-z_]+=' || true
  grep -qE '(^|[[:space:]{;])local [A-Za-z_]+=' <<<'  local mod="$DEPLOY/modules.d/62-runtime-helpers.sh"'
  # et une assignation sur la ligne d'un `setup() {` est vue — c'est la forme de 60-deploy.bats
  v="$(grep -E "(^|[[:space:]{;])(export )?[A-Za-z_]+=[^;]*$I21_MODS" <<<'setup() { MOD="$X/modules.d/60-deploy.sh"; [ -f "$MOD" ]; }' \
       | sed -E "s/.*(^|[[:space:]{;])(export )?([A-Za-z_]+)=[^;]*$I21_MODS.*/\3/")"
  [ "$v" = MOD ]
}

@test "MUR I10: qui LIT PROV_DOCKER_BIN joue la sonde — sinon il passe une CLI VIDE a son delegue" {
  # `PROV_DOCKER_BIN` vaut la CHAINE VIDE tant que `docker_endpoint` n'a pas tourne
  # (`docker-endpoint.sh` la declare ainsi). Un module qui la lit sans sonder passe `DOCKER_BIN=""`,
  # son delegue retombe sur `${DOCKER_BIN:-docker}` — un `docker` nu, introuvable dans une VM WSL ou
  # rien n'installe de CLI. Banc WSL, 2026-08-30 : `49-forge-runner` refusait trois images
  # PRESENTES sur le daemon, et son propre commentaire promettait « la CLI RESOLUE ». Sur un Linux
  # natif le PATH porte `docker` (pose par le rail) : le defaut y est invisible.
  local f bad=0
  for f in "$BATS_TEST_DIRNAME"/../modules.d/*.sh "$BATS_TEST_DIRNAME"/../container "$BATS_TEST_DIRNAME"/../accept; do
    [[ -f "$f" ]] || continue
    code "$f" | grep -q 'PROV_DOCKER_BIN' || continue
    code "$f" | grep -qE 'docker_endpoint' \
      || { echo "${f##*/} lit PROV_DOCKER_BIN sans jouer docker_endpoint"; bad=1; }
  done
  [ "$bad" -eq 0 ]
}

@test "MUR I11: un fichier designe par \$HERE ou \$DOCKER_DIR EXISTE — bench/ ne porte que des scripts de banc" {
  # `bench/` ne contient QUE ses propres scripts : les compose ET les gestes partages vivent dans
  # `docker/`. Un `"$HERE/<x>"` ecrit depuis `bench/` designe donc un fichier absent, et rien ne le
  # dit avant l'execution — apres avoir construit l'image entiere.
  # ⚠ LA PORTEE EST LE FICHIER, PAS L'EXTENSION : ce mur n'a d'abord regarde que les `.yml`, et il a
  # laisse passer `"$HERE/forge-runner.sh"` a la ligne 507 de `bench-up.sh` — le TROISIEME site du
  # meme defaut, apres trois lignes de `bench-down.sh` et une de `bench-up.sh`. Une garde taillee
  # sur les cas deja trouves ne trouve rien de neuf.
  local f here dockerdir ref path bad=0
  for f in "$BATS_TEST_DIRNAME"/../docker/*.sh "$BATS_TEST_DIRNAME"/../docker/bench/*.sh; do
    [[ -f "$f" ]] || continue
    here="$(cd "$(dirname "$f")" && pwd)"
    dockerdir="$(cd "$here/.." && pwd)"
    while read -r ref; do
      path="${ref/\$HERE/$here}"
      path="${path/\$DOCKER_DIR/$dockerdir}"
      # un chemin construit depuis une AUTRE variable (repertoire genere) sort de la portee du mur
      [[ "$path" == *'$'* ]] && continue
      [[ -f "$path" ]] || { echo "${f##*/} : $ref -> $path INTROUVABLE"; bad=1; }
    done < <(code "$f" | grep -oE '\$(HERE|DOCKER_DIR)/[A-Za-z0-9._-]+\.[a-z]+' | sort -u)
  done
  [ "$bad" -eq 0 ]
}

@test "MUR I12: un script de bench/ est EXECUTABLE DANS L INDEX — son appelant ne le prefixe pas de bash" {
  # `bench-up.sh` lance ses sous-scripts PAR LEUR CHEMIN (`"$HERE/bench-forge-bootstrap.sh" …`), pas
  # par `bash <chemin>` : un mode 100644 dans l'index rend 126 sur TOUT clone frais, et le message
  # (« Permission non accordee ») nomme le sous-script sans dire que le fautif est son mode.
  # Le bit se perd en REECRIVANT un fichier — un geste qu'aucune relecture de diff ne montre, et que
  # le disque de celui qui l'a fait ne trahit pas : `git ls-files -s` est le seul temoin. Mesure du
  # 2026-08-30 : perdu sur `bench-forge-bootstrap.sh` par un commit qui ne touchait qu'a sa prose.
  local root bad=0 mode path
  root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1 || skip "hors arbre git"
  while read -r mode _ _ path; do
    [[ "$mode" == 100755 ]] || { echo "${path##*/} : mode $mode dans l index — attendu 100755"; bad=1; }
  done < <(git -C "$root" ls-files -s 'deploy/docker/bench/*.sh')
  [ "$bad" -eq 0 ]
}

@test "MUR I13: tout module Elixir nomme par un script de deploiement EXISTE — un renommage cote lib ne se voit pas ici" {
  # `entrypoint.sh` appelle la release par `eval "<Module>.<fonction>(<arg>)"` : le nom du module est
  # une CHAINE, que ni le compilateur ni boundary ne voient. Un module extrait ou renomme laisse
  # l'appelant intact, et le defaut ne parait qu'au runtime, DANS l'image, sous un `2>/dev/null` qui
  # le reduit a « l'image ne rend pas le roster ». Mesure du 2026-08-30 : `CatalogueRoles` etait
  # devenu `Fleet.Roster` et le rail conteneur mourait a l'amorcage de la forge, sans nommer la cause.
  local lib f ref mod bad=0
  lib="$(cd "$BATS_TEST_DIRNAME/../../runtime/lib" && pwd)"
  # LE CORPUS : tout script livre qui peut nommer un module Elixir — l'installeur, les portes outil
  # de la CLI (`lcars tool …`, lot 6), les services du produit. `runtime/etc/*.sh` n'existe plus (Q3)
  # et ce mur balayait un corpus vide (relecture hostile 2026-09-04).
  local refs=0
  for f in "$BATS_TEST_DIRNAME"/../docker/*.sh "$BATS_TEST_DIRNAME"/../lib/*.sh "$BATS_TEST_DIRNAME"/../modules.d/*.sh \
           "$BATS_TEST_DIRNAME"/../../runtime/bin/lcars "$BATS_TEST_DIRNAME"/../../runtime/services/*.sh \
           "$BATS_TEST_DIRNAME"/../../runtime/services/*/*.sh; do
    [[ -f "$f" ]] || continue
    refs=$((refs + $(grep -vE '^\s*#' "$f" | grep -cE 'Fleet\.[A-Z][A-Za-z.]*\.[a-z_]+' || true)))
    while read -r ref; do
      mod="${ref%.*}"                       # le dernier segment est la fonction (snake_case)
      [[ "$mod" == *.* ]] || continue       # `Fleet.chose` : pas un appel de module qualifie
      grep -rqE "^defmodule[[:space:]]+${mod}[[:space:]]+do" "$lib" \
        || { echo "${f##*/} nomme « $mod » — aucun defmodule dans lib/"; bad=1; }
    done < <(code "$f" | grep -oE 'Fleet(\.[A-Z][A-Za-z0-9]*)+\.[a-z_][a-z0-9_]*' | sort -u)
  done
  [ "$bad" -eq 0 ]
  [ "$refs" -ge 3 ] || { echo "MUR I13 — $refs reference(s) Elixir lue(s) dans le corpus : l instrument est casse"; return 1; }
}

# ─── MUR I14 : UNE ASSERTION QUI LIT STDIN DOIT ETRE ALIMENTEE ──────────────────────────────────
#
# ⚠ CE MUR NAIT D UN BLOCAGE DE HUIT HEURES, PAS D UNE INTUITION. L helper de negation par motif lit
# STDIN — son en-tete l ecrit noir sur blanc, sous la forme `cmd | <helper> 'motif'`. Un appel sans
# tube ni redirection laisse son `grep` attendre l entree standard, et le test ne rate pas : il PEND.
#
# Et il pend SELECTIVEMENT, ce qui est le pire. Joue seul depuis un terminal, stdin est ferme et
# `grep` rend tout de suite : le fichier passe, le temoin a l air bon. Joue par `shell_gate`, stdin
# est un tube ouvert que personne n alimente — et le harnais dort. Mesure du 2026-09-02 : le
# `mix gate` de `pack.sh` et un `provision apply` de banc sont restes suspendus toute la nuit sur
# un seul appel de ce genre.
#
# UN TEST QUI PEND EST PIRE QU UN TEST FAUX. Le faux rougit ; celui-la immobilise le harnais qui le
# joue, et ce qu on lit ensuite n est pas « echec » mais l absence de toute nouvelle.
#
# ⚠ CE FICHIER EST HORS DU SCAN, ET C EST STRUCTUREL : il PARLE de l helper sans jamais l appeler.
# Un mur qui s audite lui-meme rougit sur sa propre prose — piege deja referme trois fois dans cette
# passe. Le motif exige en plus un DEBUT D INSTRUCTION, pour ne pas confondre une mention et un appel.
@test "MUR I14: toute negation par motif est ALIMENTEE — sinon son grep attend stdin et le test PEND" {
  local helper='refute_out' nus total
  # ⚠ LE TUBE EST EXCLU DU MOTIF, PAS FILTRE APRES : `| refute_out` EST la forme nominale. Une
  # premiere version mettait `|` dans la classe des debuts d instruction et denoncait les quatre
  # appels corrects du corpus — un mur qui accuse l idiome qu il defend.
  nus="$(grep -rn --exclude=idiom_walls.bats -E "(^|;|&) *${helper} " \
           "$BATS_TEST_DIRNAME"/*.bats "$BATS_TEST_DIRNAME"/../../runtime/test/*/*.bats 2>/dev/null \
         | grep -vE '<<<|< *"' || true)"
  [ -z "$nus" ] || {
    echo "appel sans tube ni redirection — son grep attendra stdin, et le test PENDRA :" >&2
    printf '%s\n' "$nus" >&2
    return 1
  }
  # GARDE D INSTRUMENT : sans elle, ce mur devient vert le jour ou l extraction ne trouve plus rien
  # — exactement la faute qu il existe pour attraper ailleurs.
  # Le compte porte sur TOUS les appels, tube compris : c est la population que le mur surveille.
  total="$(grep -rho --exclude=idiom_walls.bats -E "${helper} " \
             "$BATS_TEST_DIRNAME"/*.bats "$BATS_TEST_DIRNAME"/../../runtime/test/*/*.bats 2>/dev/null | wc -l)"
  [ "${total:-0}" -ge 5 ] \
    || { echo "instrument casse : $total appel(s) trouve(s), 5 au moins attendus" >&2; return 1; }
}

# ─── MUR I15 : QUI BATIT DEPUIS UN ARBRE DE SOURCE DOIT SAVOIR OU IL EST ────────────────────────
#
# ⚠ TROIS MODULES ONT BATI DANS LA COPIE POSEE, ET LES TROIS ONT ECHOUE — mesure du 2026-09-02 sur
# les bancs 2006 ET 2007, apply rejoue depuis `/opt/lcars/deploy/provision` :
#     FAIL 44-media:      npm run build (/opt/lcars/assets/github.io)
#     FAIL 48-forge-host: mix deps.get (/opt/lcars/services)
#     FAIL 60-deploy:     source runtime introuvable: /opt/lcars/services
#
# `62-runtime-helpers` embarque `{deploy,etc,services,bin}` a plat et `{assets,catalogues}` pour que
# le rail se REJOUE, pas pour qu il se RECONSTRUISE : il n y a la ni `mix.exs`, ni `deps/`, ni
# `node_modules`. Un module qui l ignore n echoue pas seulement — `npm ci` a INSTALLE 176 Mo sous
# /opt/lcars avant de rater son build.
#
# ⚠ LE MUR CIBLE LES VERBES QUI LISENT UN ARBRE DE SOURCE, pas ceux qui posent un binaire. `16-node`
# telecharge un precompile : il ne lit aucune source, et rien ne lui interdit de le faire depuis la
# copie. Le discriminant est « ce geste a-t-il besoin d un arbre de build ? », pas « ce module
# prononce-t-il le mot npm ».
@test "MUR I15: un module qui BATIT depuis une source consulte prov_dans_la_copie" {
  local f nom corps manquants=""
  for f in "$DEPLOY"/modules.d/*.sh; do
    corps="$(grep -vE '^\s*#' "$f")"
    grep -qE 'npm (ci|run build)|mix (deps\.get|compile)|mix\.exs' <<<"$corps" || continue
    nom="$(basename "$f")"
    grep -q 'prov_dans_la_copie' <<<"$corps" || manquants="$manquants $nom"
  done
  [ -z "$manquants" ] \
    || { echo "batit depuis une source SANS savoir s il est dans la copie posee :$manquants" >&2; return 1; }
  # GARDE D INSTRUMENT : si plus aucun module ne batit, ce mur devient vert en n ayant rien regarde.
  local batisseurs
  batisseurs="$(grep -lE 'npm (ci|run build)|mix (deps\.get|compile)|mix\.exs' "$DEPLOY"/modules.d/*.sh | wc -l)"
  [ "$batisseurs" -ge 3 ] \
    || { echo "instrument casse : $batisseurs module(s) batisseur(s) trouve(s), 3 au moins attendus" >&2; return 1; }
}

# ─── MUR I16 : `… | grep -q` SOUS `pipefail` EST UNE RACE, PAS UN TEST (DI-12, DI-13) ──────────
#
# `grep -q` sort au PREMIER match et ferme le tuyau. Si le producteur ecrit encore, il prend
# SIGPIPE et, sous `set -o pipefail`, le pipeline rend 141 : « rien trouve » alors que tout y
# etait. Ca rougit une fois sur dix sous charge, sur des temoins differents a chaque fois, et
# JAMAIS seul — la signature d'un « temoin instable » qu'on finit par ignorer. DI-12 etait
# `prov_runtime_dirs | grep -q .` dans 25-directories ; DI-13 en comptait onze autres, tous de la
# forme `id -nG | tr | grep -qx` — producteurs d'une ligne, jamais vus rouges, meme race.
#
# La forme sure CAPTURE puis TESTE (`[[ -n "$(…)" ]]`, `[[ " $(…) " == *" x "* ]]`, `case`,
# `grep -c`) : aucun lecteur ne ferme rien avant la fin. `prov_in_group` (lib) porte le cas
# du groupe ; `runtime_dirs_declared` (25) celui de la table.
#
# LE PERIMETRE : tout script de `deploy/` (hors tests) qui pose `pipefail`, PLUS `deploy/lib/*.sh`
# — une lib n'a pas de `set` a elle, elle s'execute dans le shell de qui la source, et tous ses
# appelants (provision, container, les modules) sont sous `pipefail`.
I16_RE='(^|[^|])\|[[:space:]]*grep[[:space:]]+-[A-Za-z]*q'

@test "MUR I16: aucun pipeline ne finit sur grep -q dans un script sous pipefail — capturer, puis tester" {
  # `$DEPLOY` vaut `<tests>/..` : un `find` dessus rend des chemins qui portent tous `/tests/`, et
  # l exclusion viderait le corpus. On normalise d abord — mesure : pop=0 a la premiere version.
  local root f hits=0 pop=0 first
  root="$(cd "$DEPLOY" && pwd)"
  while IFS= read -r f; do
    IFS= read -r first < "$f" || true
    case "$f" in
      *.sh) ;;
      *) [[ "$first" =~ ^#!.*bash ]] || continue ;;
    esac
    if [[ "$f" != "$root"/lib/* ]]; then
      code "$f" | grep -qE 'set -[a-zA-Z]*o pipefail|set -o pipefail' || continue
    fi
    pop=$((pop + 1))
    if code "$f" | grep -qE "$I16_RE"; then
      echo "MUR I16 rompu — ${f#"$root"/} :" >&2
      code "$f" | grep -nE "$I16_RE" >&2
      hits=$((hits + 1))
    fi
  done < <(find "$root" -type f -not -path '*/tests/*' | sort)
  [ "$hits" -eq 0 ]
  # GARDE D INSTRUMENT : un `find` qui ne trouve plus rien rendrait ce mur vert a vide.
  [ "$pop" -ge 25 ] || { echo "instrument casse : $pop script(s) sous pipefail trouve(s), 25 au moins attendus" >&2; return 1; }
  # le mur mord : la forme interdite, presentee au meme grep, est vue — dans ses trois graphies
  grep -qE "$I16_RE" <<<'  if id -nG "$u" | tr " " "\n" | grep -qx "$g"; then'
  grep -qE "$I16_RE" <<<'  head -20 "$1" 2>/dev/null | grep -qEi "SOURCE:"'
  grep -qE "$I16_RE" <<<'  printf "%s\n" "${pkgs[@]}"|grep -q x'
  # et les formes sures ne sont pas prises pour la fragile : un `||` n est pas un tuyau, une
  # capture n en est pas un, un `grep -c` non plus
  refute grep -qE "$I16_RE" <<<'  ensure_x || grep -q y "$f"'
  refute grep -qE "$I16_RE" <<<'  [[ -n "$(head -20 "$1" | grep -Ei "SOURCE:")" ]]'
  refute grep -qE "$I16_RE" <<<'  n="$(printf "%s\n" "${a[@]}" | grep -c x)"'
}

# ─── MUR I17 : `pgrep -f` / `pkill -f` NE MATCHENT PAS LEUR PORTEUR (playbook : trois fois mordu) ──
# `pgrep -f "$x"` voit tout argv qui contient `x` — dont le `bash -c`, le `ssh … '…'` ou le temoin
# qui a lance la mesure. La forme sure passe par `prov_pgrep_pattern` (lib) : `[x]yz` matche `xyz`
# et jamais la chaine `[x]yz` qui le porte. Perimetre : tout script de `deploy/` hors tests.
I17_RE='p(grep|kill)[[:space:]]+(-[A-Za-z]+[[:space:]]+)*-[A-Za-z]*f[[:space:]]+"?[^"[:space:]]*"?'

@test "MUR I17: tout pgrep -f / pkill -f de deploy/ passe son motif par prov_pgrep_pattern" {
  local root f hits=0 pop=0 first
  root="$(cd "$DEPLOY" && pwd)"
  while IFS= read -r f; do
    IFS= read -r first < "$f" || true
    case "$f" in *.sh) ;; *) [[ "$first" =~ ^#!.*bash ]] || continue ;; esac
    while IFS= read -r line; do
      pop=$((pop + 1))
      [[ "$line" == *'prov_pgrep_pattern'* ]] && continue
      echo "MUR I17 rompu — ${f#"$root"/} : $line" >&2; hits=$((hits + 1))
    done < <(code "$f" | grep -E "$I17_RE" | grep -vE '^[[:space:]]*prov_pgrep_pattern\(\)')
  done < <(find "$root" -type f -not -path '*/tests/*' | sort)
  [ "$hits" -eq 0 ]
  # GARDE D INSTRUMENT : les trois sites connus (60, 64 x2) doivent etre vus, sinon le grep est aveugle
  [ "$pop" -ge 3 ] || { echo "instrument casse : $pop site(s) pgrep/pkill -f vu(s), 3 au moins attendus" >&2; return 1; }
  # le mur mord et ne mord que la forme nue
  grep -qE "$I17_RE" <<<'  if pgrep -f "$PREFIX_REL" >/dev/null; then'
  grep -qE "$I17_RE" <<<'  pkill -TERM -f "$sup"'
  refute grep -qE "$I17_RE" <<<'  pgrep -x supervise.sh'
}

# ─── MUR I18 : AUCUN LITTERAL 1000 / 60000 COMME REPLI DE BORNE D'UID (la lib de l'installeur) ──
#
# ⚖ user 2026-09-05 (lot 14, solution A + C + E) : la frontiere systeme/humain est celle que
# `login.defs` declare, et elle est FAIL-CLOSED — bornes illisibles, personne n'est un humain, et le
# remede (le fichier) est dit une fois. La lib (`is_fleet_human`, `fleet_humans`) devinait
# `1000`/`60000` par `_uid_bound … <defaut>` ; ce mur est le temoin du temoin : le repli n'est
# plus ECRIT.
#
# JUMEAU de `runtime/test/services/idiom_walls.bats` (MUR I18, lot 15) : le mur du produit lit les
# quatre lecteurs du produit, celui-ci lit la lib de l'installeur — meme motif, chacun SES fichiers,
# aucun mur ne traverse la couture. L'EGALITE des deux corps (la lib et le protocole du produit)
# est tenue ailleurs, par un temoin qui lit les deux par nature (`lib/provision-lib.bats`).
#
# La forme mordue : une ligne de CODE qui porte le nombre 1000 ou 60000 ET parle d'uid.
I18_RE='(^|[^0-9])(1000|60000)([^0-9]|$)'

@test "MUR I18 (lib de l'installeur) : aucun litteral 1000/60000 comme repli de borne d'uid dans lib/provision-lib.sh" {
  local f="$DEPLOY/lib/provision-lib.sh" pop=0 trouve
  # LA POPULATION EST NOMMEE, PAS DECOUVERTE : le seul lecteur de la borne cote installeur.
  [ -f "$f" ] || { echo "lecteur absent : $f — la population du mur n'est plus de un" >&2; return 1; }
  pop=$((pop + 1))
  trouve="$(code "$f" | grep -nE "$I18_RE" | grep -iE 'uid' || true)"
  [ -z "$trouve" ] || { echo "MUR I18 rompu — lib/provision-lib.sh :" >&2; printf '%s\n' "$trouve" >&2; return 1; }
  # GARDE D INSTRUMENT : un lecteur, et il lit bien la borne — sinon le mur garde un fichier qui ne
  # la lit plus, et il est vert a vide.
  [ "$pop" -eq 1 ]
  [ -n "$(code "$f" | grep -E 'UID_MIN')" ] || { echo "instrument casse : la lib ne lit plus UID_MIN" >&2; return 1; }
  # Le mur mord : la forme qui vivait dans la lib, presentee au meme grep, est vue…
  local forme='  awk -F: -v m="$(_uid_bound UID_MIN 1000)" -v M="$(_uid_bound UID_MAX 60000)" \\'
  [ -n "$(grep -E "$I18_RE" <<<"$forme" | grep -iE 'uid')" ] || { echo "le mur ne mord pas : $forme" >&2; return 1; }
  # … et un uid a cinq chiffres, ou un nombre qui ne parle pas d'uid, ne le sont pas.
  refute grep -qE "$I18_RE" <<<'  export LCARS_SYSADMIN_UID=10001'
  refute grep -qiE 'uid' <<<"$(grep -E "$I18_RE" <<<'  local timeout_ms=60000')"
}

# ─── MUR I20 : LE RAIL S'APPELLE `container` — PLUS AUCUN box / boite / boîte DANS deploy/ ──────
#
# ⚖ user 2026-09-05 (chantier release, lot 1) : « workstation est bien nommé pour désigner une
# install directe sur un système, mais le rail box/boîte n'est pas explicite pour une install
# docker » → `container`, « un seul mot partout ». Le couple dit OU LCARS vit : `--workstation`
# (dans ce système) / `--container` (dans un conteneur). `docker` reste le mot du SUBSTRAT et de
# la dependance : le mur ne le regarde pas.
#
# Ce mur lit TOUT deploy/ — le code ET la prose, parce qu'un README qui dit « box up » est un
# manuel faux — plus install.sh, et jamais runtime/ : c'est l'affaire du jumeau
# (`runtime/test/services/idiom_walls.bats`, MUR I20). Il s'ecarte lui-meme : ses formes de garde
# portent le mot.
#
# Ce qui GARDE le mot, a dessein, et que le mur ecarte par motif :
#   - « boite de reception » (l'inbox d'admiral) et « boite aux lettres » (la branche d'outillage) ;
#   - `box-sizing` / `border-box` / `box-shadow` (du CSS) ;
#   - « mail-in-a-box » (l'ecole de `run_quiet`) et « out of the box » (une citation user, l'idiome) ;
#   - `_box_emit` / `_box_plain` / `_box_pad` / `_prov_box_pad` : le CADRE ASCII des bannieres.
# `sandbox`, `bwrap`, `mailbox`, `checkbox`, `toolbox` ne sont pas le mot entier : le grep ne les voit pas.
I20_RE='(^|[^[:alpha:]])(box|bo[iîÎ]te)([^[:alpha:]]|$)'
I20_EXCL='box-(sizing|shadow)|border-box|mail-in-a-box|out of the box|bo[iîÎ]tes? de r[éeÉE]ception|bo[iîÎ]tes? aux lettres|_box_(emit|plain|pad)|_prov_box_pad'

i20_hits() { # <chemin>… -> les lignes qui portent encore le mot, hors motifs ecartes (vide = propre)
  grep -rnIiE --exclude=idiom_walls.bats "$I20_RE" "$@" 2>/dev/null | grep -viE "$I20_EXCL" || true
}

@test "MUR I20 (installeur) : plus aucun box / boite / boîte dans deploy/ ni install.sh — le rail s'appelle container" {
  local root trouve
  root="$(cd "$DEPLOY/.." && pwd)"
  [ -f "$root/install.sh" ] || { echo "install.sh absent sous $root — le perimetre du mur n'est plus le bon" >&2; return 1; }
  trouve="$(i20_hits "$DEPLOY" "$root/install.sh")"
  [ -z "$trouve" ] || { echo "MUR I20 rompu — le mot du rail est container, pas box/boîte :" >&2; printf '%s\n' "$trouve" >&2; return 1; }
  # GARDE D'INSTRUMENT : le mur voit une occurrence plantee dans un decor — un chemin, de la prose
  # accentuee, une variable, un drapeau, une majuscule — quatre LIGNES, grep -n compte des lignes.
  local decor="$BATS_TEST_TMPDIR/i20"; mkdir -p "$decor"
  printf '#!/usr/bin/env bash\nexec deploy/box up\n' > "$decor/a.sh"
  printf 'la boîte tourne, LA BOÎTE aussi\n' > "$decor/b.md"
  printf 'X="${LCARS_BOX_CONF_DIR:-}"\n' > "$decor/c.sh"
  printf 'RAIL=box ; bash install.sh --box\n' > "$decor/d"
  [ "$(i20_hits "$decor" | wc -l)" -eq 4 ] || { echo "instrument casse : le mur ne voit pas le decor" >&2; i20_hits "$decor" >&2; return 1; }
  # … et ne voit PAS ce qui garde le mot a dessein.
  printf 'sandbox bwrap mailbox checkbox toolbox SANDBOX\nbox-sizing:border-box; box-shadow: 0\nla boîte de réception et la boite aux lettres, Boite de reception\nmail-in-a-box\nlivrer out of the box\n_box_emit "x"; _box_plain; _box_pad; _prov_box_pad\n' > "$decor/e.txt"
  trouve="$(i20_hits "$decor/e.txt")"
  [ -z "$trouve" ] || { echo "instrument casse : le mur mord sur une exclusion :" >&2; printf '%s\n' "$trouve" >&2; return 1; }
}
