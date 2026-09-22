#!/usr/bin/env bats
# bats file_tags=structure
# SOURCE: deploy/tests/idiom_walls.bats
# AUTHOR: bob
# STARDATE: 2026-08-30
# STATUS: murs d'idiomes — la forme fragile ne revient pas une fois le code corrigé

load refute

setup() {
  DEPLOY="$BATS_TEST_DIRNAME/.."
  mapfile -t SOURCES < <(ls "$DEPLOY"/modules.d/*.sh "$DEPLOY"/lib/*.sh "$DEPLOY"/provision)
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

@test "MUR I2: aucun en-tête d'authentification à jeton ne s'écrit hors de forge_api — ni en argv, ni dans l'environnement d'un enfant" {
  # forge_api compose l'en-tête dans son propre shell et le passe à curl sur l'entrée : la chaîne
  # « Authorization: token » écrite ailleurs est un jeton en argv ou dans l'environnement d'un enfant.
  # Exception : bench-up.sh écrit l'en-tête de git dans un fichier de configuration 0600 que git inclut.
  local root f hits=0 pop=0 first
  root="$(cd "$DEPLOY/.." && pwd)"
  while IFS= read -r f; do
    IFS= read -r first < "$f" || true
    case "$f" in *.sh) ;; *) [[ "$first" =~ ^#!.*bash ]] || continue ;; esac
    pop=$((pop + 1))
    if [[ "${f#"$root"/}" == deploy/docker/bench/bench-up.sh ]]; then
      code "$f" | grep -q 'include.path=\$JETONS/git-forge' || { echo "MUR I2 : l'exception de bench-up.sh ne passe plus par son fichier de configuration" >&2; hits=$((hits + 1)); }
      continue
    fi
    if code "$f" | grep -q 'Authorization: token'; then
      echo "MUR I2 rompu — ${f#"$root"/} :" >&2; code "$f" | grep -n 'Authorization: token' >&2; hits=$((hits + 1))
    fi
  done < <({ find "$root/deploy" -type f -not -path '*/tests/*'; echo "$root/install.sh"; } | sort)
  [ "$hits" -eq 0 ]
  [ "$pop" -ge 25 ] || { echo "instrument casse : $pop script(s) lu(s)" >&2; return 1; }
  grep -q 'Authorization: token' <<<'  GIT_CONFIG_VALUE_0="Authorization: token ${TOK}" git push'
  refute grep -q 'Authorization: token' <<<'      --token-file) tok="$(read_token "$2")"; [[ -z "$tok" ]] || auth="token $tok"; shift 2 ;;'
}

# A-118, le jumeau du mur produit (`runtime/test/services/idiom_walls.bats`) : un mot de passe voyage
# comme un jeton. TROIS FORMES, UN SEUL VERDICT (`i2_user_hit`) :
#   - `-u`/`--user` dont la valeur porte `:$` — sur toute commande, ligne de continuation comprise ;
#   - sur une ligne `curl`, `-u`/`--user` suivi d'une variable, quelle que soit sa forme : quotee en
#     morceaux (`"$a":"$b"`), portee par une variable (`--user "$creds"`), ou options collees (`-su`) ;
#   - un identifiant dans l'URL, `://…:$…@`.
# La deuxieme forme exige `curl` sur la ligne : `sort -u "$f"`, `runuser -u "$login"`, `pkill -u` sont
# des `-u` suivis d'une variable qui ne portent aucun secret. La forme sure est la ligne
# `user = "<compte>:<secret>"` d'une config lue sur stdin (`curl -K -`).
I2U_COLON="(^|[[:space:]])(-u|--user)(=|[[:space:]]+)[\"']?[^\"'[:space:]]*:\\\$"
I2U_CURL_LINE='(^|[^[:alnum:]_-])curl([[:space:]]|$)'
I2U_CURL_VAR="(^|[[:space:]])(-[A-Za-z]*u|--user)(=|[[:space:]]+)[\"']?\\\$"
I2U_URL="://[^[:space:]\"'/@]*:\\\$[^[:space:]\"'/@]*@"
i2_user_hit() { # stdin : du code -> les lignes fautives, rc 0 s'il y en a
  local c hits
  c="$(cat)"
  hits="$(grep -E -- "$I2U_COLON|$I2U_URL" <<<"$c"; grep -E -- "$I2U_CURL_LINE" <<<"$c" | grep -E -- "$I2U_CURL_VAR")" || true
  [[ -n "$hits" ]] && printf '%s\n' "$hits"
}

@test "MUR I2: aucun identifiant compte:secret ne passe par argv (curl -u / --user, URL)" {
  local root f hits=0 pop=0 first
  root="$(cd "$DEPLOY/.." && pwd)"
  while IFS= read -r f; do
    IFS= read -r first < "$f" || true
    case "$f" in *.sh) ;; *) [[ "$first" =~ ^#!.*bash ]] || continue ;; esac
    pop=$((pop + 1))
    if code "$f" | i2_user_hit >/dev/null; then
      echo "MUR I2 rompu — ${f#"$root"/} : $(code "$f" | i2_user_hit | head -1)" >&2; hits=$((hits + 1))
    fi
  done < <({ find "$root/deploy" -type f -not -path '*/tests/*'; echo "$root/install.sh"; } | sort)
  [ "$hits" -eq 0 ]
  [ "$pop" -ge 25 ] || { echo "instrument casse : $pop script(s) lu(s)" >&2; return 1; }
  # le mur mord les formes interdites, dont les quatre de la relecture hostile du 2026-09-15 (m-8)…
  i2_user_hit <<<'    code="$(curl -sS -o /dev/null -X PUT -u "$acct:$seed" "$url")"'
  i2_user_hit <<<'  curl --user=admin:$PASS "$url"'
  i2_user_hit <<<'  curl -u "$acct":"$seed" "$url"'
  i2_user_hit <<<'  creds="$a:$b"; curl --user "$creds" "$u"'
  i2_user_hit <<<'  curl -su "$acct:$seed" "$u"'
  i2_user_hit <<<'  curl "https://$acct:$seed@forge/api"'
  # … et laisse passer la config sur stdin, ainsi qu'un `-u` qui n'est pas un identifiant
  refute i2_user_hit <<<'  printf '"'"'user = "%s:%s"\n'"'"' "$acct" "$seed" | curl -K - -X PUT "$url"'
  refute i2_user_hit <<<'  sort -u "$f"'
  refute i2_user_hit <<<'  runuser -u "$login" -- true'
  refute i2_user_hit <<<'  docker run --rm -u "$(id -u):$(id -g)" "$image"'
  refute i2_user_hit <<<'  curl -fsS "http://$host:$port/api/v1/version"'
}

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
  local f hits=0
  for f in "$DEPLOY"/modules.d/*.sh; do
    if code "$f" | grep -q 'dpkg --print-architecture'; then echo "MUR I5 rompu — $f : dpkg" >&2; hits=$((hits+1)); fi
    [[ "$f" == */00-preflight.sh ]] && continue
    if code "$f" | grep -q 'uname -m'; then echo "MUR I5 rompu — $f : uname -m" >&2; hits=$((hits+1)); fi
  done
  [ "$hits" -eq 0 ]
  code "$DEPLOY/lib/provision-lib.sh" | grep -q 'dpkg --print-architecture'
}

@test "MUR I7: une valeur d un fichier d environnement se lit par env_field, jamais par un sed nu" {
  local f hits=0
  for f in "$DEPLOY"/modules.d/*.sh; do
    if code "$f" | grep -qE "sed -n ['\"]s/\^[A-Z_]+=//p['\"]"; then echo "MUR I7 rompu — $f" >&2; hits=$((hits+1)); fi
  done
  [ "$hits" -eq 0 ]
  echo '  x="$(sed -n '"'"'s/^LCARS_X=//p'"'"' "$f" | tail -n1)"' | grep -qE "sed -n ['\"]s/\^[A-Z_]+=//p['\"]"
}

@test "MUR I8: un fichier de jeton se lit par read_token ou forge_api — jamais par une redirection nue" {
  local hits=0 f
  for f in "$BATS_TEST_DIRNAME"/../modules.d/*.sh; do
    if code "$f" | grep -qE '<[[:space:]]*"?\$[A-Za-z_]*TOKEN_FILE' || code "$f" | grep -qF "tr -d '[:space:]' <"; then echo "MUR I8 rompu — $f" >&2; hits=$((hits+1)); fi
  done
  [ "$hits" -eq 0 ]
}

# un témoin pose le décor de la lib (LCARS_DECOR_ROOT, directement ou par decor_pose) : sans lui,
# la lib lit les fichiers de la machine qui joue la porte
pose_le_decor() { grep -qE '^[[:space:]]*(export LCARS_DECOR_ROOT=|decor_pose([[:space:]]|$))' "$1"; }

@test "MUR I19: un temoin qui nomme un lecteur du siege ou des bornes d'uid pose le decor — il ne lit jamais le siege ni le login.defs de la machine" {
  local f bad=0 vus=0
  for f in "$BATS_TEST_DIRNAME"/*.bats "$BATS_TEST_DIRNAME"/*/*.bats; do
    [[ "$f" == */idiom_walls.bats ]] && continue
    [[ -n "$(grep -vE '^[[:space:]]*#' "$f" | grep -E 'prov_seat_uid|fleet_humans|prov_uid_bounds')" ]] || continue
    vus=$((vus + 1))
    pose_le_decor "$f" || { echo "${f##*/} nomme un lecteur du siege ou des bornes sans poser le decor"; bad=1; }
  done
  [ "$vus" -gt 0 ] || { echo "aucun temoin dans le perimetre — l'instrument ne lit plus le corpus"; return 1; }
  [ "$bad" -eq 0 ]
}

I21_MODS='[0-9]{2}-[a-z0-9-]+\.sh'
@test "MUR I21: un temoin qui EXECUTE un module pose le decor — il ne lit ni n'ecrit jamais les fichiers de la machine" {
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
    pose_le_decor "$f" \
      || { echo "${f#"$DEPLOY"/} execute un module sans poser le decor"; bad=1; }
  done < <(find "$DEPLOY/tests" -name '*.bats' | sort)
  [ "$bad" -eq 0 ]
  # GARDE D INSTRUMENT : les témoins de modules.d/ au moins
  [ "$vus" -ge 15 ] || { echo "instrument casse : $vus temoin(s) vu(s), 15 au moins attendus" >&2; return 1; }
  # le mur mord : un temoin qui execute 60 par sa copie, ou par une variable du fichier, est VU
  local ech="$BATS_TEST_TMPDIR/ech.bats" seen
  printf '%s\n' 'MOD="$X/modules.d/62-runtime-helpers.sh"' 'run bash "$MOD" check' > "$ech"
  seen="$(grep -vE '^[[:space:]]*#' "$ech")"
  v="$(grep -E "(^|[[:space:]{;])(export )?[A-Za-z_]+=[^;]*$I21_MODS" <<<"$seen" | sed -E "s/.*(^|[[:space:]{;])(export )?([A-Za-z_]+)=[^;]*$I21_MODS.*/\3/")"
  [ "$v" = MOD ]
  grep -qE "bash \"?\\\$$v\"?( |\$)" <<<"$seen"
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
  # `PROV_DOCKER_BIN` vaut la chaîne vide tant que `docker_endpoint` n'a pas tourné : un module qui la
  # lit sans sonder passe `DOCKER_BIN=""`, et son délégué retombe sur un `docker` nu, introuvable dans
  # une VM WSL où rien n'installe de CLI
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
  # `bench/` ne contient que ses propres scripts : les compose et les gestes partagés vivent dans
  # `docker/`. Un `"$HERE/<x>"` écrit depuis `bench/` désigne un fichier absent, et rien ne le dit
  # avant l'exécution. La portée est le fichier désigné, quelle que soit son extension.
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
  # `bench-up.sh` lance ses sous-scripts PAR LEUR CHEMIN (`"$DOCKER_DIR/forge-runner.sh" …`), pas
  # par `bash <chemin>` : un mode 100644 dans l'index rend 126 sur TOUT clone frais, et le message
  # (« Permission non accordee ») nomme le sous-script sans dire que le fautif est son mode.
  # Le bit se perd en REECRIVANT un fichier — un geste qu'aucune relecture de diff ne montre, et que
  # le disque de celui qui l'a fait ne trahit pas : `git ls-files -s` est le seul temoin.
  local root bad=0 mode path
  root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1 || skip "hors arbre git"
  while read -r mode _ _ path; do
    [[ "$mode" == 100755 ]] || { echo "${path##*/} : mode $mode dans l index — attendu 100755"; bad=1; }
  done < <(git -C "$root" ls-files -s 'deploy/docker/bench/*.sh')
  [ "$bad" -eq 0 ]
}

@test "MUR I13: tout module Elixir nomme par un script de deploiement EXISTE — un renommage cote lib ne se voit pas ici" {
  # un script appelle la release par « <Module>.<fonction>(<arg>) » : le nom du module est une chaîne
  # que ni le compilateur ni boundary ne voient, et un module renommé ne se montre qu'au runtime
  local lib f ref mod bad=0
  lib="$(cd "$BATS_TEST_DIRNAME/../../runtime/lib" && pwd)"
  # le corpus : tout script livré qui peut nommer un module Elixir — l'installeur, la CLI, les services du produit
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

# MUR I14 — refute_out lit stdin : appelé sans tube ni redirection, son grep attend une entrée que le
# harnais n'alimente pas, et le cas pend au lieu de rougir. Ce fichier parle de l'helper sans
# l'appeler : il est hors du balayage.
@test "MUR I14: toute negation par motif est ALIMENTEE — sinon son grep attend stdin et le test PEND" {
  local helper='refute_out' nus total
  # le tube est la forme nominale : il est exclu du motif, qui exige un début d'instruction
  nus="$(grep -rn --exclude=idiom_walls.bats -E "(^|;|&) *${helper} " \
           "$BATS_TEST_DIRNAME"/*.bats "$BATS_TEST_DIRNAME"/../../runtime/test/*/*.bats 2>/dev/null \
         | grep -vE '<<<|< *"' || true)"
  [ -z "$nus" ] || {
    echo "appel sans tube ni redirection — son grep attendra stdin, et le test PENDRA :" >&2
    printf '%s\n' "$nus" >&2
    return 1
  }
  # GARDE D INSTRUMENT : le compte porte sur tous les appels, tube compris — la population surveillée
  total="$(grep -rho --exclude=idiom_walls.bats -E "${helper} " \
             "$BATS_TEST_DIRNAME"/*.bats "$BATS_TEST_DIRNAME"/../../runtime/test/*/*.bats 2>/dev/null | wc -l)"
  [ "${total:-0}" -ge 5 ] \
    || { echo "instrument casse : $total appel(s) trouve(s), 5 au moins attendus" >&2; return 1; }
}

# MUR I15 — la copie posée sous /opt/lcars sert à rejouer le provisionnement, pas à rebâtir : elle ne
# porte ni mix.exs, ni deps/, ni node_modules. Le mur vise les verbes qui lisent un arbre de build.
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
  local batisseurs=0
  for f in "$DEPLOY"/modules.d/*.sh; do
    grep -vE '^\s*#' "$f" | grep -qE 'npm (ci|run build)|mix (deps\.get|compile)|mix\.exs' && batisseurs=$((batisseurs + 1))
  done
  [ "$batisseurs" -ge 2 ] \
    || { echo "instrument casse : $batisseurs module(s) batisseur(s) trouve(s), 2 au moins attendus" >&2; return 1; }
}

# MUR I16 — `grep -q` sort au premier match et ferme le tuyau : un producteur qui écrit encore prend
# SIGPIPE, et sous pipefail le pipeline rend 141, « rien trouvé » alors que tout y était. La forme
# sûre capture puis teste (`[[ -n "$(…)" ]]`, `case`, `grep -c`). Le périmètre : tout script de
# deploy/ (hors tests) qui pose pipefail, et deploy/lib/*.sh, sourcée par des appelants sous pipefail.
I16_RE='(^|[^|])\|[[:space:]]*grep[[:space:]]+-[A-Za-z]*q'

@test "MUR I16: aucun pipeline ne finit sur grep -q dans un script sous pipefail — capturer, puis tester" {
  # `$DEPLOY` porte `/tests/` : les chemins se normalisent avant l'exclusion des témoins
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

i22_hits() { # i22_hits <fichier> — les lignes « assertion && assertion » : errexit ignore l'échec de la première (mesuré)
  awk '
    function ok_seg(s) { return s ~ /^(\[ |\[\[ |grep |refute |refute_out |test )/ }
    /^[[:space:]]*#/ || !/ && / || / \|\| / || /\\$/ { next }
    { body = $0; sub(/^[[:space:]]*/, "", body); sub(/^[^ )]*\)[[:space:]]+/, "", body); n = split(body, seg, / && /); if (n < 2) next
      good = 1; for (i = 1; i <= n; i++) { s = seg[i]; sub(/^[[:space:]]+/, "", s); if (!ok_seg(s)) good = 0 }
      if (good) print FILENAME ":" FNR ": " $0 }
  ' "$1"
}

@test "MUR I22: une assertion par ligne dans un temoin — « a && b » ne fait echouer le cas que si b echoue" {
  local f hits=0 vus=0
  while IFS= read -r f; do
    vus=$((vus + 1))
    if [[ -n "$(i22_hits "$f")" ]]; then
      echo "MUR I22 rompu — ${f#"$DEPLOY"/} :" >&2; i22_hits "$f" >&2; hits=$((hits + 1))
    fi
  done < <(find "$DEPLOY/tests" -name '*.bats' | sort)
  [ "$hits" -eq 0 ]
  [ "$vus" -ge 50 ] || { echo "instrument casse : $vus temoin(s) vu(s), 50 au moins attendus" >&2; return 1; }
  local decor="$BATS_TEST_TMPDIR/i22.bats"
  printf '  [ "$status" -eq 0 ] && [[ "$output" == *x* ]]\n' > "$decor"
  [ -n "$(i22_hits "$decor")" ]
  printf '  grep -q a "$f" && grep -q b "$f"\n' > "$decor"
  [ -n "$(i22_hits "$decor")" ]
  printf '      n)    [[ "$output" == *x* ]] && [[ "$output" != *y* ]] ;;\n' > "$decor"
  [ -n "$(i22_hits "$decor")" ]
  printf '      ""|o) [ -n "$x" ] && [ -n "$y" ] ;;\n' > "$decor"
  [ -n "$(i22_hits "$decor")" ]
  printf '  [[ "$a" == x && "$b" == y ]]\n  [ -n "$x" ] && echo oui\n  [ -n "$x" ] && [ -n "$y" ] || { echo non; return 1; }\n  # [ a ] && [ b ]\n' > "$decor"
  [ -z "$(i22_hits "$decor")" ]
}

# MUR I17 — `pgrep -f "$x"` voit tout argv qui contient `x`, dont le `bash -c` ou le témoin qui a
# lancé la mesure. La forme sûre passe par `prov_pgrep_pattern` (lib) : `[x]yz` matche `xyz` et jamais
# la chaîne `[x]yz` qui le porte. Périmètre : tout script de deploy/ hors tests.
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
