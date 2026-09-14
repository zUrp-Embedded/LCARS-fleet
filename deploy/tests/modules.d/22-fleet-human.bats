#!/usr/bin/env bats
# bats file_tags=integration
# SOURCE: deploy/tests/modules.d/22-fleet-human.bats
# AUTHOR: DrDree
# STARDATE: 2026-08-21
# STATUS: bats tests for 22-fleet-human — la SONDE de l'humain de fleet du poste

load ../refute
load ../support/decor

setup() {
  # le décor possède l'environnement : ces témoins jugent ce que le module fait d'un environnement
  # donné (bornes d'uid, siège, groupe), jamais la machine qui les joue
  local _v
  while read -r _v; do unset "$_v" 2>/dev/null || true; done \
    < <(compgen -v | grep -E '^(LCARS_|PROV_|FORGE_)' || true)

  SRC="$BATS_TEST_DIRNAME/../../modules.d/22-fleet-human.sh"
  [ -f "$SRC" ]
  export PROVISION_LIB="$BATS_TEST_DIRNAME/../../lib/provision-lib.sh"
  export PROVISION_MODULE=22-fleet-human PROV_SUBSTRATE=wsl
  PROV_HUMAN="$(id -un)"; export PROV_HUMAN

  decor_pose
  printf 'UID_MIN 1000\nUID_MAX 60000\n' > "$LCARS_DECOR_ROOT/etc/login.defs"
  printf '1000\n' > "$LCARS_DECOR_ROOT/etc/lcars/seat.uid"
  passwd_with

  # les groupes des humains du décor : « login groupe… » ; tout autre appel va au vrai id
  export ID_GROUPS="$BATS_TEST_TMPDIR/id-groups"; : > "$ID_GROUPS"
  export USERMOD_LOG="$BATS_TEST_TMPDIR/usermod.log"
  cat > "$DECOR_BIN/id" <<'EOS'
#!/usr/bin/env bash
if [[ "${1:-}" == -nG ]]; then
  l="$(grep "^$2 " "$ID_GROUPS")" || exit 1
  echo "${l#* }"; exit 0
fi
if [[ "${1:-}" == -u && "${2:-}" == -- ]]; then
  u="$(awk -F: -v n="$3" '$1==n {print $3; exit}' "$LCARS_DECOR_ROOT/etc/passwd")"
  [[ -n "$u" ]] && { echo "$u"; exit 0; }
fi
if [[ $# -eq 1 && "$1" != -* ]]; then
  awk -F: -v n="$1" '$1==n {found=1} END {exit !found}' "$LCARS_DECOR_ROOT/etc/passwd" && exit 0
fi
exec /usr/bin/id "$@"
EOS
  # usermod note son appel ; il refuse, sauf sous STUB_USERMOD_OK où il ajoute le groupe à la ligne de l'humain
  cat > "$DECOR_BIN/usermod" <<'EOS'
#!/usr/bin/env bash
echo "usermod $*" >> "$USERMOD_LOG"
[[ -n "${STUB_USERMOD_OK:-}" ]] || { echo "usermod: /etc/group verrouillé" >&2; exit 10; }
sed -i "s/^${*: -1} .*/& $2/" "$ID_GROUPS"
EOS
  chmod 0755 "$DECOR_BIN"/*
}

passwd_with() { # passwd_with <ligne>...  → pose le passwd du décor
  local f="$LCARS_DECOR_ROOT/etc/passwd"
  printf 'root:x:0:0:root:/root:/bin/bash\n' > "$f"
  printf 'nobody:x:65534:65534:nobody:/nonexistent:/usr/sbin/nologin\n' >> "$f"
  printf 'siege:x:1000:1000::/home/siege:/bin/bash\n' >> "$f"
  local l; for l in "$@"; do printf '%s\n' "$l" >> "$f"; done
}

mod() { run bash -c "set -euo pipefail; source <(sed '\$d' '$SRC') >/dev/null 2>&1; $1"; }
nu() { run bash "$SRC" "$1"; }

@test "ce module ne CREE pas de compte unix — un seul createur, et ce n'est pas lui" {
  local mouchard="$BATS_TEST_TMPDIR/appele" u
  for u in useradd adduser; do
    printf '%s\n' '#!/usr/bin/env bash' "printf '%s %s\n' \"\$0\" \"\$*\" >> '$mouchard'" 'exit 0' > "$DECOR_BIN/$u"
    chmod 0755 "$DECOR_BIN/$u"
  done
  passwd_with 'zoe:x:1001:1001::/home/zoe:/bin/bash'
  nu apply
  [ ! -e "$mouchard" ] || { echo "createur APPELE : $(cat "$mouchard")"; return 1; }
}

@test "TEMOIN DU TEMOIN : le mouchard attrape bien un createur, quel que soit le detour" {
  # sans ce pendant, un mouchard qui n'attrape rien passe pour une absence de création
  local bin="$BATS_TEST_TMPDIR/probe"; mkdir -p "$bin"
  local mouchard="$BATS_TEST_TMPDIR/probe.log"
  printf '%s\n' '#!/usr/bin/env bash' \
    "printf 'vu %s\n' \"\$*\" >> '$mouchard'" 'exit 0' > "$bin/useradd"
  chmod 0755 "$bin/useradd"

  PATH="$bin:$PATH" bash -c 'r=$(useradd -m a); env useradd -m b'
  [ -f "$mouchard" ]
  [ "$(grep -c '^vu ' "$mouchard")" -eq 2 ]
}

@test "le verdict PROPOSE un geste — et ce n'est plus un useradd : le convergeur est le seul createur" {
  mod 'observe'
  refute grep -q 'useradd' <<<"$output"
  [[ "$output" == *"s'inscrit sur la forge"* ]]
  [[ "$output" == *"lcars-converger"* ]]
}


# bats test_tags=structure
@test "le nom d'un compte n'est JAMAIS ecrit ici — ce module ne connait personne par son nom" {
  local code; code="$(grep -vE '^\s*#' "$SRC")"
  refute grep -qE '(^|[^.[:alnum:]_/])lcars([^[:alnum:]_.-]|$)' <<<"$code"
  # une seconde origine du nom (l'ancien --fleet-human) redonnerait deux sources à un fait qui n'en a qu'une
  refute grep -q 'PROV_FLEET_HUMAN' <<<"$code"
  refute grep -q 'builtin-human' <<<"$code"
}



@test "AUCUN humain : l'état nominal d'une machine neuve est conforme, dit en une ligne qui nomme qui s'en occupera" {
  nu check
  [ "$status" -eq 0 ]
  [ "$(grep -c . <<<"$output")" -eq 1 ]
  [[ "$output" == "OK    22-fleet-human: aucun humain de fleet — "*"convergeur"* ]]
}

@test "AUCUN humain : l'APPLY non plus ne derive pas — les deux verbes s'accordent enfin" {
  nu apply
  [ "$status" -eq 0 ]
  [[ "$output" != *"DRIFT"* ]]
}

@test "TEMOIN: un humain dans les bornes qui porte le groupe est conforme" {
  passwd_with 'zoe:x:1234:1234::/home/zoe:/bin/bash'
  printf 'zoe zoe fleet\n' > "$ID_GROUPS"
  nu check
  [ "$status" -eq 0 ]
  [[ "$output" == *"« zoe » (uid 1234) ∈ fleet — il peut lancer la fleet"* ]]
}


@test "l'adhesion au GROUPE est mesuree ici, et le drift nomme la racine des jetons du decor" {
  passwd_with 'zoe:x:1234:1234::/home/zoe:/bin/bash'
  printf 'zoe zoe\n' > "$ID_GROUPS"
  nu check
  [ "$status" -eq 1 ]
  [[ "$output" == *"DRIFT 22-fleet-human: « zoe » hors du groupe fleet — il ne lira ni $LCARS_DECOR_ROOT/opt/lcars/var/tokens"* ]]
}

@test "TEMOIN DU TEMOIN : la population, elle, ne regarde AUCUN groupe" {
  passwd_with 'zoe:x:1001:1004::/home/zoe:/bin/bash'
  mod 'fleet_humans'
  [ "$status" -eq 0 ]
  [ "$output" = "zoe" ]
}

@test "nobody n'est JAMAIS un humain de fleet — enumerer exige la borne HAUTE" {
  # Il est sur toute machine, uid 65534 : superieur a UID_MIN et different du siege. La regle basse
  # seule le compte — enumerer exige donc les DEUX bornes que `login.defs` declare.
  mod 'fleet_humans'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "bornes illisibles : le check dérive sur une seule ligne qui porte le remède, sans « aucun humain »" {
  passwd_with 'zoe:x:1001:1001::/home/zoe:/bin/bash'
  rm "$LCARS_DECOR_ROOT/etc/login.defs"
  nu check
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | grep -qxE "DRIFT 22-fleet-human: la frontiere systeme/humain n'est pas etablie \(UID_MIN illisible dans .*\) — .*repare $LCARS_DECOR_ROOT/etc/login.defs — cette machine ne peut reconnaître aucun humain de fleet"
  [ "$(grep -c "n'est pas etablie" <<<"$output")" -eq 1 ]
  refute grep -q 'WARN' <<<"$output"
  refute grep -q 'zoe' <<<"$output"
}

@test "bornes illisibles : l'apply dérive de même, et ne touche à aucun groupe" {
  passwd_with 'zoe:x:1001:1001::/home/zoe:/bin/bash'
  rm "$LCARS_DECOR_ROOT/etc/login.defs"
  nu apply
  [ "$status" -eq 2 ]
  printf '%s\n' "$output" | grep -qE "^DRIFT 22-fleet-human: la frontiere systeme/humain n'est pas etablie"
  [ ! -e "$USERMOD_LOG" ]
}

@test "un humain hors du groupe : l'apply l'y ajoute, et check le voit" {
  passwd_with 'horsgroupe:x:1001:1001::/home/horsgroupe:/bin/bash'
  printf 'horsgroupe horsgroupe\n' > "$ID_GROUPS"
  STUB_USERMOD_OK=1 nu apply
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -qx 'usermod -aG fleet horsgroupe' "$USERMOD_LOG"
  nu check
  [ "$status" -eq 0 ]
}

@test "un usermod en échec est un échec nommé avec sa cause, pas un drift muet" {
  passwd_with 'horsgroupe:x:1001:1001::/home/horsgroupe:/bin/bash'
  printf 'horsgroupe horsgroupe\n' > "$ID_GROUPS"
  nu apply
  [ "$status" -eq 1 ]
  grep -qx 'usermod -aG fleet horsgroupe' "$USERMOD_LOG"
  [[ "$output" == *"FAIL  22-fleet-human: commande en échec (rc=10) : usermod -aG fleet horsgroupe"* ]]
  [[ "$output" == *"/etc/group verrouillé"* ]]
}

# bats test_tags=structure
@test "un apply ne DELEGUE JAMAIS a check — le verdict n'est pas partageable" {
  # le verdict porte le dialecte du verbe : la règle se garde pour tous les modules
  local m bad=0
  for m in "$BATS_TEST_DIRNAME"/../../modules.d/*.sh; do
    if awk '/^apply\(\) \{/,/^\}/' "$m" | grep -vE '^\s*#' | grep -qE '(^|[^_[:alnum:]])check;'; then
      echo "apply() delegue a check() : $(basename "$m")"; bad=1
    fi
  done
  [ "$bad" -eq 0 ]
}
