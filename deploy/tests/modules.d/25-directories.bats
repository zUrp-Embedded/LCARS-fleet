#!/usr/bin/env bats
# bats file_tags=integration
# SOURCE: deploy/tests/modules.d/25-directories.bats
# AUTHOR: DrDree
# STARDATE: 2026-08-20
# STATUS: bats tests for 25-directories.sh — la racine des sockets de console, et sa survie au reboot

load ../refute
load ../support/decor

setup() {
  local _v
  while read -r _v; do unset "$_v" 2>/dev/null || true; done \
    < <(compgen -v | grep -E '^(LCARS_|PROV_)' || true)
  SRC="$BATS_TEST_DIRNAME/../../modules.d/25-directories.sh"
  [ -f "$SRC" ]

  export PROVISION_LIB="$BATS_TEST_DIRNAME/../../lib/provision-lib.sh"
  export PROVISION_MODULE=25-directories
  export PROV_HUMAN=temoin
  export PROV_SUBSTRATE=linux
  LCARS_BUILTIN_HUMAN="$(id -un)"; export LCARS_BUILTIN_HUMAN

  # le décor possède son dossier runtime : `prov_lock_path` le veut, et un compte de service n'en a pas
  export XDG_RUNTIME_DIR="$BATS_TEST_TMPDIR/xdg"
  mkdir -p "$XDG_RUNTIME_DIR"
  chmod 0700 "$XDG_RUNTIME_DIR"

  decor_pose
  D="$LCARS_DECOR_ROOT"
  CONF="$D/etc/tmpfiles.d/lcars-console.conf"
  mkdir -p "$(dirname "$CONF")"

  # Le corps du module SANS son dispatch final : on appelle ses fonctions, on ne le lance pas.
  MOD="$BATS_TEST_TMPDIR/mod.sh"
  sed '/^case "${1:?usage/,$d' "$SRC" > "$MOD"
}

mod() { run bash -c "set -euo pipefail; source '$MOD' >/dev/null 2>&1; $1"; }

@test "LCARS header: SOURCE/AUTHOR/STARDATE/STATUS present" {
  run head -6 "$BATS_TEST_DIRNAME/../../modules.d/25-directories.sh"
  [[ "$output" == *"SOURCE:"* ]]
  [[ "$output" == *"AUTHOR:"* ]]
  [[ "$output" == *"STARDATE:"* ]]
  [[ "$output" == *"STATUS:"* ]]
}

@test "substrat natif: la table porte la racine des sockets de console ET le dossier de l'humain" {
  PROV_SUBSTRATE=linux mod 'prov_runtime_dirs'
  [ "$status" -eq 0 ]
  [[ "$output" == *"$D/run/lcars/console 0711 root:root"* ]]
  [[ "$output" == *"$D/run/lcars/console/$LCARS_BUILTIN_HUMAN 2710 $LCARS_BUILTIN_HUMAN:lcars-console"* ]]
  # Le parent aussi : sans lui, `install -d` du dossier de console echoue sur un /run nu.
  [[ "$output" == *"$D/run/lcars 0755 root:root"* ]]
}

@test "le dossier de console est celui de l'humain qui LANCE, pas de --human" {
  PROV_SUBSTRATE=linux mod 'prov_runtime_dirs'
  [ "$status" -eq 0 ]
  [[ "$output" != *"/run/lcars/console/temoin"* ]]
}

@test "humain de fleet PAS ENCORE la : repli sur --human, jamais aucune racine du tout" {
  PROV_SUBSTRATE=linux LCARS_BUILTIN_HUMAN="n-existe-pas-$$" mod 'prov_runtime_dirs'
  [ "$status" -eq 0 ]
  [[ "$output" == *"$D/run/lcars/console/temoin 2710 temoin:lcars-console"* ]]
}

@test "le nom vient de l'AUTORITE, pas d'un litteral ni d'un drapeau" {
  local code; code="$(sed 's/#.*//' "$SRC")"
  grep -q 'forge-gestures.sh" builtin-human' <<<"$code"
  run grep -cE 'PROV_FLEET_HUMAN|"lcars"|:-lcars\}' <<<"$code"
  [ "$output" = "0" ]
}

@test "le dossier de l'humain ne NOMME jamais un groupe homonyme — le groupe primaire est celui de la fleet" {
  PROV_SUBSTRATE=linux mod 'prov_runtime_dirs'
  [ "$status" -eq 0 ]
  [[ "$output" != *"temoin:temoin"* ]]
}

@test "la racine du magasin dans la table est la constante PROV_STORE_ROOT, sous le décor" {
  mod 'prov_dirs'
  [ "$status" -eq 0 ]
  grep -qx "$D/var/lib/lcars 0755 root:root" <<<"$output"
}

@test "MANIFESTE vs TABLE : mode et proprietaire s'accordent sur chaque repertoire runtime" {
  local manifest="$BATS_TEST_DIRNAME/../../system.manifest"
  [ -f "$manifest" ]
  PROV_SUBSTRATE=linux mod 'prov_runtime_dirs'
  [ "$status" -eq 0 ]
  [ -n "$output" ]

  local path mode owner m_mode m_owner row key want_owner bad=0 n=0
  while read -r path mode owner; do
    [[ -n "$path" ]] || continue
    # le manifeste déclare le chemin de la machine ; le dossier de l'humain y porte un joker
    key="${path#"$D"}"; want_owner="$owner"
    if [[ "$key" == /run/lcars/console/* ]]; then
      key="/run/lcars/console/<human>"
      want_owner="<human>:${owner#*:}"
    fi
    row="$(awk -v p="$key" '{c=$1;sub(/:.*/,"",c)} c=="runtime" && $2==p {print; exit}' "$manifest")"
    [[ -n "$row" ]] || { echo "DANS LA TABLE, PAS AU MANIFESTE : $key"; bad=1; continue; }
    m_mode="$(awk '{print $3}' <<<"$row")"
    m_owner="$(awk '{print $4}' <<<"$row")"
    n=$((n + 1))
    [[ "${m_mode#0}" == "${mode#0}" ]] \
      || { echo "MODE : $key — manifeste $m_mode, table $mode"; bad=1; }
    [[ "$m_owner" == "$want_owner" ]] \
      || { echo "OWNER : $key — manifeste $m_owner, table $want_owner"; bad=1; }
  done <<<"$output"

  # zéro ligne comparée et zéro désaccord rendent le même vert : la table doit avoir été lue
  [ "$n" -ge 5 ] || { echo "seulement $n lignes comparees — le decor ne rend pas la table"; return 1; }
  [ "$bad" -eq 0 ]
}

@test "la declaration tmpfiles est DERIVEE de la table — une seule source, pas deux" {
  PROV_SUBSTRATE=linux mod 'prov_tmpfiles_body'
  [ "$status" -eq 0 ]
  [[ "$output" == *"d /run/lcars/console 0711 root root -"* ]]
  [[ "$output" == *"d /run/lcars/console/$LCARS_BUILTIN_HUMAN 2710 $LCARS_BUILTIN_HUMAN lcars-console -"* ]]
  # Autant de lignes `d ` que d'entrees dans la table : une entree ajoutee a la table arrive ici
  # sans geste, et une entree qui n'y est pas ne peut pas y apparaitre.
  PROV_SUBSTRATE=linux mod 'prov_tmpfiles_body | grep -c "^d "'
  [ "$output" = "$(PROV_SUBSTRATE=linux bash -c "source '$MOD' >/dev/null 2>&1; prov_runtime_dirs | wc -l" | tr -d ' ')" ]
}

@test "le corps tmpfiles nomme les chemins de la machine, jamais ceux du décor — systemd le lit au boot" {
  PROV_SUBSTRATE=linux mod 'prov_tmpfiles_body'
  [ "$status" -eq 0 ]
  refute_out "$D" <<<"$output"
  grep -qx 'd /run/lcars 0755 root root -' <<<"$output"
}

di12_etat() { # <pourquoi> — imprime ce que le témoin VOYAIT, et REND 1 : il remplace l'assertion
  {
    echo "── DI-12 : état au moment du rouge — $* ──────────────────────"
    echo "  statut      : ${status-<aucun run>}"
    echo "  sortie      :"; printf '%s\n' "${output-<aucun run>}" | sed 's/^/    | /'
    echo "  conf        : $CONF"
    echo "  existe      : $([[ -f "$CONF" ]] && echo oui || echo NON)"
    [[ -f "$CONF" ]] && { echo "  contenu     :"; sed 's/^/    | /' "$CONF"; }
    echo "  humain      : $(PROV_SUBSTRATE=linux bash -c "source '$MOD' >/dev/null 2>&1; prov_console_human" 2>&1)"
    echo "  table       :"; PROV_SUBSTRATE=linux bash -c "source '$MOD' >/dev/null 2>&1; prov_runtime_dirs" 2>&1 | sed 's/^/    | /'
    # un `.prov.XXXXXX` visible ici désigne le temporaire en vol ; son absence renvoie à l'autre piste
    echo "  voisins     :"; ls -la "$(dirname "$CONF")" 2>&1 | sed 's/^/    | /'
    echo "  charge      : $(uptime | sed 's/.*load average: //')"
    echo "──────────────────────────────────────────────────────────────"
  } >&2
  return 1
}

@test "apply pose la declaration, et check la voit" {
  PROV_SUBSTRATE=linux mod 'apply_tmpfiles'
  [ "$status" -eq 0 ] || di12_etat "apply_tmpfiles a rendu $status"
  [ -f "$CONF" ] || di12_etat "apply_tmpfiles n'a pas laisse le fichier"
  [[ "$(stat -c %a "$CONF")" == "644" ]] || di12_etat "mode $(stat -c %a "$CONF"), attendu 644"

  PROV_SUBSTRATE=linux mod 'check_tmpfiles'
  [ "$status" -eq 0 ] || di12_etat "check_tmpfiles a rendu $status"
  [[ "$output" == *"OK"* ]] || di12_etat "check_tmpfiles ne dit pas OK sur sa propre pose"
}

@test "declaration ABSENTE = drift, et le drift dit la CONSEQUENCE (la fleet ne demarrera pas)" {
  PROV_SUBSTRATE=linux mod 'check_tmpfiles'
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRIFT"*"$CONF absent"* ]]
  [[ "$output" == *"reboot"* ]]
}

@test "declaration PERIMEE = drift — un contenu qui ne suit plus la table ment au boot" {
  printf 'd /run/quelque-part-dautre 0755 root root -\n' > "$CONF"
  PROV_SUBSTRATE=linux mod 'check_tmpfiles'
  [ "$status" -eq 0 ] || di12_etat "check_tmpfiles a rendu $status sur une declaration perimee"
  [[ "$output" == *"ne correspond plus"* ]] || di12_etat "le drift n'est pas nomme « ne correspond plus »"
}

@test "apply puis check sur le décor : tout est conforme — le propriétaire attendu se lit par prov_owner" {
  printf '#!/usr/bin/env bash\nexit 0\n' > "$DECOR_BIN/systemd-tmpfiles"; chmod 0755 "$DECOR_BIN/systemd-tmpfiles"
  run bash "$SRC" apply
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  run bash "$SRC" check
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"OK    25-directories: $D/opt/lcars/var/tokens (710 $(id -un):$(id -gn))"* ]]
  refute_out 'DRIFT' <<<"$output"
}

@test "une entree en echec n'arrete pas la table : les suivantes sont posees quand meme" {
  # `/proc/...` ne peut pas etre cree, a coup sur et sans droits speciaux : la premiere entree
  # echoue pour de vrai, pas par un stub.
  local bonne="$BATS_TEST_TMPDIR/apres"
  run bash -c "set -uo pipefail
    source '$MOD' >/dev/null 2>&1
    prov_dirs() { printf '%s\n' '/proc/impossible-a-creer 0700 root:root' '$bonne 0755 $(id -un):$(id -gn)'; }
    apply_tmpfiles() { :; }
    apply"

  # l'entrée d'après est posée : la boucle ne meurt pas sur la première
  [ -d "$bonne" ] || { echo "la table s'est arretee a la premiere entree en echec" >&2; return 1; }
  # et le module rend quand même un échec
  [ "$status" -ne 0 ] || { echo "un module en echec a rendu 0 — le verdict a ete avale" >&2; return 1; }
}

@test "une table SANS echec rend toujours 0 — le correctif n'a pas rendu l'echec permanent" {
  # sans ce pendant, un module qui échouerait toujours passerait le cas du dessus
  local a="$BATS_TEST_TMPDIR/ok-a" b="$BATS_TEST_TMPDIR/ok-b"
  run bash -c "set -uo pipefail
    source '$MOD' >/dev/null 2>&1
    prov_dirs() { printf '%s\n' '$a 0755 $(id -un):$(id -gn)' '$b 0755 $(id -un):$(id -gn)'; }
    apply_tmpfiles() { :; }
    apply"
  [ "$status" -eq 0 ]
  [ -d "$a" ]
  [ -d "$b" ]
}

@test "le compteur de changement VOIT l'ecriture du tmpfiles — write_atomic ne tourne plus dans un pipe" {
  PROV_SUBSTRATE=linux mod 'PROV_CHANGED=0; apply_tmpfiles; echo "changed=$PROV_CHANGED"'
  [ "$status" -eq 0 ] || di12_etat "apply_tmpfiles a rendu $status"
  [[ "$output" == *"changed=1"* ]] || di12_etat "le compteur ne rapporte pas l'ecriture"
}


# des entrées réelles du manifeste, sous le décor : any, wsl+linux, et une sur le volume /opt/lcars/var
docker_decor() {
  ME="$(id -un):$(id -gn)"
  D_ANY="$D/opt/lcars/share"
  D_POSTE="$D/opt/lcars/var/tofu"
  D_VOL="$D/opt/lcars/var/tokens"
  D_INCONNU="$D/opt/lcars/inconnu-du-manifeste"
  mkdir -p "$D_ANY" "$D_POSTE" "$D_VOL" "$D_INCONNU"
  chmod 0755 "$D_ANY" "$D_POSTE" "$D_INCONNU"; chmod 0710 "$D_VOL"
  TABLE="printf '%s\n' '$D_ANY 0755 root:root' '$D_POSTE 0755 root:root' '$D_VOL 0710 root:root' '$D_INCONNU 0755 root:root'"
}

# check_on <substrat> : joue `check` sur la table de decor, sous ce substrat
check_on() {
  run env PROV_SUBSTRATE="$1" bash -c "set -euo pipefail; source '$MOD' >/dev/null 2>&1; prov_dirs() { $TABLE; }; check"
}

@test "docker : la table runtime est VIDE — /run est un fait de boot, et il n'y a pas de tmpfiles a declarer" {
  PROV_SUBSTRATE=docker mod 'prov_runtime_dirs'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  PROV_SUBSTRATE=docker mod 'prov_dirs'
  [ "$status" -eq 0 ]
  refute_out '/run/' <<<"$output"
  # et `runtime_dirs_declared` le dit a `check_tmpfiles` : « ce substrat ne le porte pas »
  PROV_SUBSTRATE=docker mod 'runtime_dirs_declared'
  [ "$status" -ne 0 ]
  # la même table, sur le poste, n'est pas vide : un `return 0` inconditionnel passerait les lignes du dessus
  PROV_SUBSTRATE=linux mod 'prov_runtime_dirs | grep -c "/run/"'
  [ "$output" -ge 5 ]
}

@test "docker : sans declaration tmpfiles, check_tmpfiles ne dit RIEN ; avec une, c'est un drift nomme" {
  PROV_SUBSTRATE=docker mod 'check_tmpfiles'
  [ "$status" -eq 0 ]
  refute_out -i 'drift' <<<"$output"
  printf 'd /run/lcars/console 0711 root root -\n' > "$CONF"
  PROV_SUBSTRATE=docker mod 'check_tmpfiles; echo "drift=$PROV_DRIFT"'
  [[ "$output" == *"ne le porte pas"* ]]
  [[ "$output" == *"drift=1"* ]]
}

@test "docker : une entree any avec un mauvais mode est un DRIFT NOMME — l'instrument est stat, pas -r" {
  docker_decor
  chmod 0700 "$D_ANY"
  check_on docker
  [ "$status" -eq 1 ]
  [[ "$output" == *"$D_ANY : 700 $ME ≠ 755 $ME"* ]]
  # repare, le verdict revient a 0 : le drift etait celui-la et pas un autre
  chmod 0755 "$D_ANY"
  check_on docker
  [ "$status" -eq 0 ]
}

@test "docker : une entree wsl+linux n est PAS mesuree — meme absente, meme fausse — et le module le DIT" {
  docker_decor
  chmod 0700 "$D_POSTE"
  check_on docker
  [ "$status" -eq 0 ]
  refute_out -- "$D_POSTE : " <<<"$output"
  rm -rf "$D_POSTE"
  check_on docker
  [ "$status" -eq 0 ]
  refute_out -- "$D_POSTE absent" <<<"$output"
  [[ "$output" == *"hors substrat docker"*"$D_POSTE"* ]]
}

@test "docker : une entree sur un VOLUME du conteneur n'a pas de verite au build — non mesuree, et DITE" {
  docker_decor
  rm -rf "$D_VOL"
  check_on docker
  [ "$status" -eq 0 ]
  refute_out -- "$D_VOL absent" <<<"$output"
  [[ "$output" == *"volume du conteneur"*"$D_VOL"* ]]
}

@test "docker : une entree que le manifeste NE CONNAIT PAS se mesure quand meme — un absent nomme au build vaut mieux qu'un silence" {
  docker_decor
  rm -rf "$D_INCONNU"
  check_on docker
  [ "$status" -eq 1 ]
  [[ "$output" == *"$D_INCONNU absent"* ]]
}

@test "poste : le meme decor, tout se mesure — l'entree wsl+linux ET celle du volume, et rien n'est dit hors mesure" {
  # Le filtre docker ne fuit pas sur le poste : `wsl+linux` y est chez lui, et un volume n'y existe pas.
  docker_decor
  chmod 0700 "$D_POSTE"; rm -rf "$D_VOL"
  check_on linux
  [ "$status" -eq 1 ]
  [[ "$output" == *"$D_POSTE : 700 $ME ≠ 755 $ME"* ]]
  [[ "$output" == *"$D_VOL absent"* ]]
  refute_out 'hors substrat|volume du conteneur' <<<"$output"
}

@test "le substrat d'une entree vient du MANIFESTE, et de lui seul — la table du module n'en porte aucune colonne" {
  local code; code="$(sed 's/#.*//' "$SRC")"
  grep -q 'prov_manifest_substrate' <<<"$code"
  grep -q '^prov_manifest_substrate()' "$PROVISION_LIB"
  # aucune colonne substrat dans la table : chaque entree de prov_dirs a exactement trois champs
  local liste n_lignes n_trois
  liste="$(sed -n '/^prov_dirs()/,/^}$/p' "$SRC" | grep -E '^\s+"[^"]+" *\\?$' | sed -E 's/\$\(prov_decor ([^)]*)\)/\1/g' | tr -d '"\\')"
  n_lignes="$(grep -c . <<<"$liste")"
  n_trois="$(awk 'NF==3' <<<"$liste" | grep -c .)"
  [ "$n_lignes" -ge 10 ]
  [ "$n_lignes" -eq "$n_trois" ]
  refute grep -qE 'wsl\+linux|wsl linux' <<<"$code"
}

@test "MANIFESTE vs TABLE : les repertoires DURABLES aussi — chaque entree de prov_dirs est declaree, meme mode, meme proprietaire" {
  local manifest="$BATS_TEST_DIRNAME/../../system.manifest"
  PROV_SUBSTRATE=linux mod 'prov_dirs'
  [ "$status" -eq 0 ]
  local path mode owner row key bad=0 n=0 attendu=0
  while read -r path mode owner; do
    key="${path#"$D"}"
    [[ -n "$key" && "$key" != /run/* ]] || continue
    attendu=$((attendu + 1))
    row="$(awk -v p="$key" '{c=$1;sub(/:.*/,"",c)} (c=="dir"||c=="prefix"||c=="preserve") && $2==p {print $3, $4; exit}' "$manifest")"
    [[ -n "$row" ]] || { echo "DANS LA TABLE, PAS AU MANIFESTE : $key"; bad=1; continue; }
    n=$((n + 1))
    [ "$row" = "$mode $owner" ] || { echo "$key — manifeste « $row », table « $mode $owner »"; bad=1; }
  done <<<"$output"
  [ "$attendu" -gt 0 ] || { echo "la table ne rend AUCUNE entree durable — le decor ne rend pas la table"; return 1; }
  [ "$n" -eq "$attendu" ] || { echo "$n lignes comparees sur $attendu entrees durables — il en manque $((attendu - n)) au manifeste"; return 1; }
  [ "$bad" -eq 0 ]
}

@test "les volumes que le module ecarte au build sont ceux que le Dockerfile declare VOLUME — deux ecritures, une valeur" {
  local df="$BATS_TEST_DIRNAME/../../docker/Dockerfile"
  local declares; declares="$(grep -E '^VOLUME ' "$df" | tr -d '[]",' | sed 's/^VOLUME //' | tr ' ' '\n' | sort)"
  [ -n "$declares" ]
  mod 'prov_container_volumes | sort'
  [ "$status" -eq 0 ]
  [ "$(sed "s|^$D||" <<<"$output")" = "$declares" ]
}
