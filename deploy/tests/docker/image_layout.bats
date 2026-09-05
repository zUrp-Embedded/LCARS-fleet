#!/usr/bin/env bats
# SOURCE: deploy/tests/docker/image_layout.bats
# AUTHOR: bob
# STARDATE: 2026-09-04
# STATUS: bats tests for le Dockerfile — ce que l'image POSE sort de l'image avec son mode, pas repare par l'instance
#
# Relecture hostile 2026-09-04 (S5). Journal du banc bob_2 au boot : « POSÉ perms 0755 root:root
# /etc/lcars » — l'init de l'instance reparait le mode d'un repertoire que l'IMAGE venait de livrer.
# Cause : `COPY --chmod=0644 … /etc/lcars/lcars.bashrc` cree le parent manquant avec le `--chmod`
# du fichier. Un `/etc/lcars` non traversable rend `seat.uid` (GUARD B) et le bashrc invisibles a
# tout non-root ; l'init le reparait AVANT que quiconque n'entre, donc ca marchait — mais la doctrine
# du lot 5 (« l'image ne derive pas, sa conformite est le build ») etait fausse ici, et le stage
# `verify` ne le voyait pas — non parce que root traverse un repertoire sans bit x (un `stat`
# rend le mode declare, quel que soit le lecteur), mais parce qu'il ne DEMANDAIT pas
# `25-directories`. Lot 14 : il le demande, et la table dit `any` de ce que l'image pose.
#
# ⚠ CES TEMOINS NE BATISSENT AUCUNE IMAGE. Ils lisent le Dockerfile : le repertoire est pose par un
# `install -d` AVANT le premier `COPY` qui y ecrit, et son mode est celui que l'init de l'instance
# et la table de l'installeur declarent — trois ecritures, une valeur.

load ../refute

setup() {
  DF="$BATS_TEST_DIRNAME/../../docker/Dockerfile"
  INIT="$BATS_TEST_DIRNAME/../../../runtime/services/container/init.sh"
  MANIFEST="$BATS_TEST_DIRNAME/../../system.manifest"
  [ -f "$DF" ] && [ -f "$INIT" ] && [ -f "$MANIFEST" ]
  # Le stage runtime seul : c'est lui que `final` livre.
  RUNTIME="$(sed -n '/^FROM .* AS runtime$/,/^FROM runtime AS verify$/p' "$DF" | grep -vE '^\s*#')"
  [ -n "$RUNTIME" ]
}

@test "/etc/lcars est POSE par l'image (install -d 0755 root:root) AVANT le premier COPY qui y ecrit" {
  local l_dir l_copy
  l_dir="$(grep -nE '^RUN install -d -m 0755 -o root -g root /etc/lcars$' <<<"$RUNTIME" | head -1 | cut -d: -f1)"
  l_copy="$(grep -nE '^COPY .* /etc/lcars/' <<<"$RUNTIME" | head -1 | cut -d: -f1)"
  [ -n "$l_copy" ] || { echo "aucun COPY vers /etc/lcars/ dans le stage runtime — le temoin ne mesure plus rien" >&2; return 1; }
  [ -n "$l_dir" ] || { echo "/etc/lcars n'est pas pose par un install -d 0755 root:root : le COPY --chmod cree le parent avec le mode du FICHIER" >&2; return 1; }
  [ "$l_dir" -lt "$l_copy" ] || { echo "install -d /etc/lcars (l.$l_dir) vient APRES le COPY (l.$l_copy) — trop tard, le parent existe deja avec le mauvais mode" >&2; return 1; }
}

@test "le mode de /etc/lcars est le MEME dans l'image, dans l'init de l'instance et dans la table de l'installeur" {
  # Trois poseurs, une valeur. L'init reste poseur (une instance sur un vieux volume, un /etc
  # monte) ; il ne doit plus jamais avoir a REPARER ce que l'image livre.
  grep -qE '^RUN install -d -m 0755 -o root -g root /etc/lcars$' <<<"$RUNTIME"
  grep -qE '^\s*ensure_dir /etc/lcars\s+0755 root:root' "$INIT"
  grep -qE '^dir\s+/etc/lcars\s+0755\s+root:root' "$MANIFEST"
}

@test "aucun COPY --chmod du stage runtime ne cree /etc/lcars en passant — le seul createur est l'install -d" {
  # Garde de forme : un second fichier copie sous /etc/lcars demain doit tomber APRES l'install -d,
  # sinon c'est lui qui cree le parent.
  local l_dir l
  l_dir="$(grep -nE '^RUN install -d -m 0755 -o root -g root /etc/lcars$' <<<"$RUNTIME" | head -1 | cut -d: -f1)"
  [ -n "$l_dir" ]
  while read -r l; do
    [ -n "$l" ] || continue
    [ "$l" -gt "$l_dir" ] || { echo "COPY vers /etc/lcars/ a la ligne $l du stage, avant l'install -d ($l_dir)" >&2; return 1; }
  done < <(grep -nE '^COPY .* /etc/lcars/' <<<"$RUNTIME" | cut -d: -f1)
}

# ─── LOT 14 : LE MANIFESTE DIT VRAI SUR L'IMAGE ─────────────────────────────────────────────────
#
# ⚖ user 2026-09-04 (17-DEUX-OUVERTS, solution A). Sept lignes de `deploy/system.manifest` disaient
# `wsl+linux` — « n'existe pas sur docker » — de repertoires que le stage runtime POSE (`/etc/lcars`,
# `share/*`, `tofu/*`). `25-directories` lit desormais cette colonne pour savoir ou une entree de sa
# table se mesure : une colonne fausse ici est une mesure de moins au build, en silence.
#
# La liste est EXPLICITE, et c'est le point : ce sont les repertoires que l'image pose ET que la
# table connait. Un chemin qui entre dans la table demain et que l'image pose aussi s'ajoute ici.

image_declared_dirs() {
  printf '%s\n' /opt/lcars /etc/lcars /var/lib/lcars /var/tmp/lcars /var/tmp/lcars/toolchain-work \
    /opt/lcars/tofu /opt/lcars/tofu/providers \
    /opt/lcars/share /opt/lcars/share/avatars /opt/lcars/share/favicon /opt/lcars/share/doc
}

@test "ce que l'image POSE et que la table connait est declare pour docker — le manifeste dit vrai sur l'image" {
  local p col bad=0 n=0
  while read -r p; do
    # (a) le stage runtime le nomme hors commentaire : un chemin absent d'ici sort de cette liste,
    #     il ne se declare pas `any` sur la foi d'un temoin
    grep -qF -- "$p" <<<"$RUNTIME" \
      || { echo "$p : le stage runtime ne le nomme pas — l'image ne le pose pas, retire-le de cette liste" >&2; bad=1; continue; }
    # (b) la table le connait, et pour docker
    col="$(awk -v p="$p" '{c=$1;sub(/:.*/,"",c)} (c=="dir"||c=="prefix") && $2==p {print $5; exit}' "$MANIFEST")"
    [ -n "$col" ] || { echo "$p : inconnu de la table (dir|prefix)" >&2; bad=1; continue; }
    n=$((n + 1))
    [[ "$col" == any || "+$col+" == *"+docker+"* ]] \
      || { echo "$p : l'image le pose, la table dit « $col » — 25-directories ne le mesurera pas au build" >&2; bad=1; }
  done < <(image_declared_dirs)
  [ "$n" -ge 11 ] || { echo "seulement $n repertoires compares — l'instrument ne lit plus la liste" >&2; return 1; }
  [ "$bad" -eq 0 ]
}

# ─── LOT 15 : LES ANCRES ET LES LIENS AUSSI ─────────────────────────────────────────────────────
#
# `anchor /usr/local/bin/tofu` et `link /usr/local/bin/{fleet,lcars}` disaient `wsl+linux` alors que
# le stage runtime les pose (`install -m 0755`, `ln -sf`) et que `verify` les relit deja (46 par
# stat, 60 par `readlink` contre release.manifest). Meme regle que les repertoires : ce que l'image
# pose et que la table connait se declare pour docker. `node`/`npm`/`npx` n'y sont pas — l'image
# n'a pas de node.

image_declared_anchors_links() {
  printf '%s\n' /usr/local/bin/tofu /usr/local/bin/fleet /usr/local/bin/lcars \
    /usr/local/bin/lcars-toolchain-converge /usr/local/bin/lcars-authority-ask \
    /etc/lcars/lcars.bashrc /opt/lcars/.helpers-revision /opt/lcars/.source-revision
}

@test "les ANCRES et les LIENS que l'image pose et que la table connait sont declares pour docker — 46 et 60 les relisent au build" {
  local p col bad=0 n=0
  while read -r p; do
    # (a) le stage runtime le nomme hors commentaire : sinon il sort de cette liste
    grep -qF -- "$p" <<<"$RUNTIME" \
      || { echo "$p : le stage runtime ne le nomme pas — l'image ne le pose pas, retire-le de cette liste" >&2; bad=1; continue; }
    # (b) la table le connait, en ancre ou en lien, et pour docker
    col="$(awk -v p="$p" '{c=$1;sub(/:.*/,"",c)} (c=="anchor"||c=="link") && $2==p {print $5; exit}' "$MANIFEST")"
    [ -n "$col" ] || { echo "$p : inconnu de la table (anchor|link)" >&2; bad=1; continue; }
    n=$((n + 1))
    [[ "$col" == any || "+$col+" == *"+docker+"* ]] \
      || { echo "$p : l'image le pose, la table dit « $col » — le manifeste ment sur l'image" >&2; bad=1; }
  done < <(image_declared_anchors_links)
  [ "$n" -ge 8 ] || { echo "seulement $n ancres/liens compares — l'instrument ne lit plus la liste" >&2; return 1; }
  [ "$bad" -eq 0 ]
  # et le complement : ce que la table declare `wsl+linux` sous /usr/local/bin, l'image ne le pose PAS
  local reste
  while read -r reste; do
    [ -n "$reste" ] || continue
    refute grep -qE -- "(ln -sf|install -m [0-7]+)[^\\]* $reste( |\\\\|$)" <<<"$RUNTIME"
  done < <(awk '{c=$1;sub(/:.*/,"",c)} (c=="anchor"||c=="link") && $2 ~ /^\/usr\/local\/bin\// && $5!="any" {print $2}' "$MANIFEST")
}

@test "chaque install -d du stage runtime pose le MODE et le PROPRIETAIRE que la table declare" {
  # La generalisation du temoin `/etc/lcars` ci-dessus : un `install -d -m M -o U -g G <chemins>` du
  # stage runtime, sur un chemin que la table declare, porte le mode et le proprietaire de la table.
  # Deux ecritures, une valeur — et c'est ce que `25-directories` mesurera au build par `stat`.
  local spec mode u g p row n=0 bad=0
  while read -r spec; do
    [ -n "$spec" ] || continue
    read -r _ _ _ mode _ u _ g _ <<<"$spec"
    for p in $(sed -E 's/^install -d -m [0-7]{4} -o [a-z-]+ -g [a-z-]+//' <<<"$spec"); do
      row="$(awk -v p="$p" '{c=$1;sub(/:.*/,"",c)} (c=="dir"||c=="prefix") && $2==p {print $3, $4; exit}' "$MANIFEST")"
      [ -n "$row" ] || continue   # couvert par un ancetre : la table ne le nomme pas, rien a comparer
      n=$((n + 1))
      [ "$row" = "$mode $u:$g" ] \
        || { echo "$p : l'image pose « $mode $u:$g », la table declare « $row »" >&2; bad=1; }
    done
  done < <(grep -oE 'install -d -m [0-7]{4} -o [a-z-]+ -g [a-z-]+( /[^ \\"]+)+' <<<"$RUNTIME")
  # ⚠ GARDE DE POPULATION : cinq repertoires sont poses ainsi et declares (lot 13b + lot 14).
  [ "$n" -ge 5 ] || { echo "seulement $n install -d compares a la table — l'extraction ne lit plus le stage" >&2; return 1; }
  [ "$bad" -eq 0 ]
}

# ─── LOT 15 : CE QUE 62 RELIT AU BUILD SORT DE L'IMAGE COMME L'APPLY LE POSE ────────────────────
#
# `62 check` relit les arbres qu'il embarque (`EMBEDDED`, `EMBEDDED_ROOT`) — root:root, ni setgid ni
# ecriture groupe/autres — et ses donnees (`DATA`, 0644). Un COPY PRESERVE les modes du contexte de
# build : un clone a umask 002 est en 2775/664, et verify rougirait sur un contexte ordinaire — ou,
# pire, ne rougirait que sur celui de quelqu'un d'autre. Deux ecritures, une valeur.

embedded_trees() { # les deux listes de 62, telles qu'il les porte
  grep -oE '^EMBEDDED(_ROOT)?=\([^)]*\)' "$BATS_TEST_DIRNAME/../../modules.d/62-runtime-helpers.sh" \
    | sed -E 's/^[A-Z_]+=\(//; s/\)$//' | tr ' ' '\n' | grep -v '^$'
}

@test "les arbres que 62 relit sont NORMALISES par l'image (chmod -R g-s,go-w) APRES la derniere ecriture dedans" {
  local verify; verify="$(sed -n '/^FROM runtime AS verify$/,/^FROM /p' "$DF" | grep -vE '^\s*#')"
  local t stage txt l_norm after n=0
  while read -r t; do
    [ -n "$t" ] || continue
    for stage in runtime verify; do
      if [ "$stage" = runtime ]; then txt="$RUNTIME"; else txt="$verify"; fi
      # ce stage pose-t-il cet arbre ? (un COPY qui y vise)
      grep -qE "^(COPY|ADD) .* /opt/lcars/$t(/|$)" <<<"$txt" || continue
      n=$((n + 1))
      l_norm="$(grep -nE "chmod -R g-s,go-w( /opt/lcars/[a-z]+)* /opt/lcars/$t( |$)" <<<"$txt" | tail -1 | cut -d: -f1)"
      [ -n "$l_norm" ] || { echo "$stage : /opt/lcars/$t est pose mais pas normalise (chmod -R g-s,go-w)" >&2; return 1; }
      # ce qui ECRIT dedans vient AVANT : un COPY qui y vise, ou tofu (init/mirror) qui y pose .terraform
      after="$(tail -n "+$((l_norm + 1))" <<<"$txt")"
      refute grep -qE "^(COPY|ADD) .* /opt/lcars/$t(/|$)" <<<"$after"
      refute grep -qE 'tofu (init|providers mirror)' <<<"$after"
    done
  done < <(embedded_trees)
  # ⚠ GARDE DE POPULATION : etc, services, assets, catalogues (runtime) et deploy (verify).
  [ "$n" -ge 5 ] || { echo "seulement $n arbre(s) vus dans les stages — l'extraction ne lit plus 62 ou le Dockerfile" >&2; return 1; }
}

@test "les DONNEES de 62 sortent de l'image a leur mode — COPY --chmod ou chmod explicite, jamais le mode du contexte" {
  local mod="$BATS_TEST_DIRNAME/../../modules.d/62-runtime-helpers.sh" spec _src dst mode n=0
  while read -r spec; do
    [ -n "$spec" ] || continue
    read -r _src dst mode <<<"$spec"
    # la destination telle que l'image la pose : le defaut du module, sans decor
    dst="${dst//\$HELPERS_DIR//opt/lcars}"; dst="${dst//\$LCARS_BASHRC//etc/lcars/lcars.bashrc}"
    n=$((n + 1))
    grep -qE "^COPY --chmod=$mode .* $dst\$" <<<"$RUNTIME" \
      || grep -qE "chmod $mode( [^ \\\\]+)* $dst( |\\\\|$)" <<<"$RUNTIME" \
      || { echo "$dst : l'image ne fixe pas son mode ($mode) — un COPY nu garde le mode du contexte (664 sous umask 002)" >&2; return 1; }
  done < <(sed -n '/^DATA=(/,/^)/p' "$mod" | sed '1d;$d;s/#.*//' | tr -d '"' | awk 'NF')
  [ "$n" -ge 2 ] || { echo "seulement $n donnee(s) lue(s) dans DATA — l'extraction ne lit plus 62" >&2; return 1; }
}

@test "/etc/lcars/lcars.bashrc : un chmod 0644 suit le COPY — --chmod ne normalise pas un source en 664 (mesure vanille_1)" {
  local l_copy l_chmod
  l_copy="$(grep -nE '^COPY --chmod=0644 runtime/services/lcars.bashrc /etc/lcars/lcars.bashrc$' <<<"$RUNTIME" | head -1 | cut -d: -f1)"
  l_chmod="$(grep -nE '^RUN chmod 0644 /etc/lcars/lcars.bashrc$' <<<"$RUNTIME" | head -1 | cut -d: -f1)"
  [ -n "$l_copy" ] && [ -n "$l_chmod" ] || { echo "COPY (l.${l_copy:-?}) ou chmod (l.${l_chmod:-?}) absent" >&2; return 1; }
  [ "$l_copy" -lt "$l_chmod" ] || { echo "le chmod (l.$l_chmod) precede le COPY (l.$l_copy) — il serait ecrase" >&2; return 1; }
}
