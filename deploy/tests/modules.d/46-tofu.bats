#!/usr/bin/env bats
# SOURCE: deploy/tests/modules.d/46-tofu.bats
# AUTHOR: DrDree
# STARDATE: 2026-08-22
# STATUS: bats tests for 46-tofu — l'outil qui pose la structure de forge, SUR la machine
#
# ⚖ USER 2026-08-22 : « tu build une image complete de 1,2 Go juste pour executer 100 ko de recette
# tofu ? » puis « pourquoi tofu ne peut pas tourner directement ? »
#
# Mesure dans l'image : `tofu` 110 Mo + son miroir de providers 14 Mo — 124 Mo d'outil transportes
# dans une image de 1,18 Go que le rail poste ne DEMARRE jamais et ne batissait que pour ca.
#
# La cause etait historique : « tofu n'etait installe NULLE PART », dit le Dockerfile. Et le
# contournement etait devenu sa propre justification — le conteneur transitoire recevait ses
# fichiers par un volume et trois `docker cp`, pour contourner un probleme (« le daemon peut vivre
# ailleurs ») qui n'existe QUE parce qu'on tourne dans un conteneur.
#
# ⚠ AUCUN TEMOIN ICI NE VA SUR LE RESEAU NI NE LANCE tofu. Ce qui se mesure est la DERIVATION : les
# pins, l'arch, la version sondee, et le fait que le miroir se refasse sur un verdict et pas a
# chaque passage.

# ⚠ SC2016 : CE TEMOIN LIT DU CODE. Ses motifs `grep`/`sed` portent des `${VAR:-defaut}` qui
# doivent atteindre l'outil TELS QUELS — les developper chercherait la valeur dans CE shell au lieu
# du texte audite. Les quotes simples sont l'instrument, pas un oubli.
# shellcheck disable=SC2016

# ⚠ SIGNALEMENTS VERIFIES UN PAR UN, AUCUN N'EST UN DEFAUT :
#   SC2034 — variable posee pour un sous-processus ou lue par un helper, pas par ce fichier
# shellcheck disable=SC2034

load ../refute

setup() {
  local _v
  while read -r _v; do unset "$_v" 2>/dev/null || true; done \
    < <(compgen -v | grep -E '^(LCARS_|PROV_)' || true)

  MOD="$BATS_TEST_DIRNAME/../../modules.d/46-tofu.sh"
  DOCKERFILE="$BATS_TEST_DIRNAME/../../docker/Dockerfile"
  [ -f "$MOD" ] && [ -f "$DOCKERFILE" ]

  export PROVISION_LIB="$BATS_TEST_DIRNAME/../../lib/provision-lib.sh"
  export PROVISION_MODULE=46-tofu
  export PROV_SUBSTRATE=linux
  export PROV_HUMAN
  PROV_HUMAN="$(id -un)"
  export PROV_FLEET_GROUP
  PROV_FLEET_GROUP="$(id -gn)"
  export PROV_TOKENS_DIR="$BATS_TEST_TMPDIR/private"
  export XDG_RUNTIME_DIR="$BATS_TEST_TMPDIR/xdg"; mkdir -p "$XDG_RUNTIME_DIR"; chmod 0700 "$XDG_RUNTIME_DIR"

  # ⚠ LE BINAIRE SE NOMME, SINON LE TEMOIN MESURE LA MACHINE. `/usr/local/bin/tofu` existe sur
  # certains postes de dev — mesure du 2026-08-22 : un symlink pose en juillet sur celui-ci. Sans ce
  # nommage, « tofu absent » prend la branche « present, verifie la version » et repond sur l'hote.
  # Quatrieme occurrence de ce piege en deux jours, apres `/etc/lcars/host-consent` et `ttyd`.
  export LCARS_TOFU_BIN="$BATS_TEST_TMPDIR/bin/tofu"
  # Le CANAL est a nous : absent = « aucun », le module pose comme aujourd'hui (voir runtime_helpers.bats).
  export LCARS_CHANNEL_FILE="$BATS_TEST_TMPDIR/etc/lcars/channel"
  export LCARS_TOFU_DIR="$BATS_TEST_TMPDIR/opt/lcars/tofu"
  export LCARS_TOFU_OWNER
  LCARS_TOFU_OWNER="$(id -un):$(id -gn)"
}

mod() { run bash "$MOD" "$1"; }

@test "LCARS header: SOURCE/AUTHOR/STARDATE/STATUS + les trois en-tetes de module" {
  run head -9 "$MOD"
  [[ "$output" == *"SOURCE:"* ]]
  [[ "$output" == *"AUTHOR:"* ]]
  [[ "$output" == *"STARDATE:"* ]]
  [[ "$output" == *"STATUS:"* ]]
  [[ "$output" == *"APPLY-ON: wsl linux"* ]]
  [[ "$output" == *"CHECK-ON: any"* ]]
  [[ "$output" == *"NEEDS: root"* ]]
}

@test "l'ORDRE porte le sens : ce module vient AVANT 48-forge-host, qui en depend" {
  # `48-forge-host` pose la structure de la forge et a besoin de tofu POUR CA. Le mettre avec les
  # autres auxiliaires (62) l'aurait rendu indisponible au moment exact ou la forge en a besoin —
  # meme lecon que `22-fleet-human`, renomme de 65 a 22 pour cette raison.
  local d="$BATS_TEST_DIRNAME/../../modules.d"
  [ -f "$d/46-tofu.sh" ]
  [ -f "$d/48-forge-host.sh" ]
  # ⚠ CETTE LIGNE COMPARAIT DEUX LITTERAUX. `[[ "46-tofu" < "48-forge-host" ]]` prouve que « 46 »
  # trie avant « 48 » — de l'arithmetique, pas une propriete de ce depot. Elle serait restee
  # verte apres un renommage de l'un ou l'autre, c'est-a-dire au moment precis ou l'ordre casse.
  # Ce qui est vrai : les deux modules EXISTENT, et le glob du runner met le premier avant.
  local _mods _ia _ib
  _mods="$(cd "$BATS_TEST_DIRNAME/../../modules.d" && printf '%s\n' *.sh)"
  _ia="$(grep -nx '46-tofu.sh' <<<"$_mods" | cut -d: -f1)"
  _ib="$(grep -nx '48-forge-host.sh' <<<"$_mods" | cut -d: -f1)"
  [ -n "$_ia" ] && [ -n "$_ib" ] && [ "$_ia" -lt "$_ib" ]
}

@test "l'absence de tofu se DIT avec sa consequence" {
  mod check
  [ "$status" -eq 1 ]
  [[ "$output" == *"absent"* ]]
  [[ "$output" == *"territoire de tofu"* ]]
}

@test "un tofu d'une AUTRE version est un DRIFT, pas un « present »" {
  # Le pin ne vaut que si on verifie ce qu'on a. Un tofu du systeme, pose par quelqu'un d'autre,
  # jouerait la recette avec d'autres providers — et la structure de forge est son territoire.
  mkdir -p "$(dirname "$LCARS_TOFU_BIN")"
  printf '#!/usr/bin/env bash\necho "OpenTofu v1.6.0"\n' > "$LCARS_TOFU_BIN"
  chmod 0755 "$LCARS_TOFU_BIN"

  mod check
  [ "$status" -eq 1 ]
  [[ "$output" == *"1.6.0"* ]]
  [[ "$output" == *"version épinglée"* ]]
  [[ "$output" == *"d'autres providers"* ]]
}

@test "la version EPINGLEE est reconnue — pas de drift sur le cas nominal" {
  mkdir -p "$(dirname "$LCARS_TOFU_BIN")"
  printf '#!/usr/bin/env bash\necho "OpenTofu v1.12.3"\n' > "$LCARS_TOFU_BIN"
  chmod 0755 "$LCARS_TOFU_BIN"

  mod check
  [[ "$output" == *"tofu 1.12.3 posé"* ]]
  [[ "$output" != *"version épinglée"* ]]
}

@test "le miroir absent est un DRIFT nomme — sinon tofu irait sur le RESEAU sans le dire" {
  mod check
  [[ "$output" == *"miroir de providers absent"* ]]
  [[ "$output" == *"réseau"* ]]
}

@test "une arch non epinglee est un REFUS, jamais un repli" {
  # `uname -m` repondrait `x86_64` la ou les releases disent `amd64`, et repondrait pour la machine
  # de build en cross-compilation. On lit `dpkg --print-architecture`, et une arch inconnue ECHOUE
  # en se nommant plutot que de deviner une URL.
  # ⚠ ON GREPPE LE CODE, PAS LA PROSE. Le module CITE `uname -m` dans son commentaire pour dire
  # pourquoi il ne l'emploie pas ; un grep nu sur le fichier attrape cette phrase et fait echouer le
  # temoin sur ce qu'il voulait justement saluer.
  code() { grep -vE '^\s*#' "$MOD"; }
  grep -q 'arch non épinglée pour tofu' "$MOD"
  grep -q 'attendu amd64 ou arm64' "$MOD"
  code | grep -q 'arch_tag'
  code | refute_out 'uname -m'
  code | refute_out 'dpkg --print-architecture'
}

@test "le miroir se refait sur le VERDICT d'un init hors-ligne, pas a chaque passage" {
  # `providers mirror` va sur le reseau, `init` hors-ligne non. L'init est donc le discriminant, et
  # la seule chose qui PROUVE que le miroir couvre la recette telle qu'elle est aujourd'hui.
  # ⚠ SUR LE CODE, PAS SUR LA PROSE : le commentaire qui explique la regle cite `providers mirror`
  # AVANT que le code ne l'appelle, et un grep nu concluait donc l'inverse de ce qui est ecrit.
  local body="$BATS_TEST_TMPDIR/body.sh"
  grep -vE '^\s*#' "$MOD" > "$body"
  grep -q 'init -input=false -no-color' "$body"
  grep -q 'providers mirror -platform=' "$body"
  # et l'init est joue AVANT le miroir — sinon on irait sur le reseau a chaque passage
  local first_init first_mirror
  first_init="$(grep -n 'init -input=false' "$body" | head -1 | cut -d: -f1)"
  first_mirror="$(grep -n 'providers mirror' "$body" | head -1 | cut -d: -f1)"
  [ "$first_init" -lt "$first_mirror" ]
}

@test "la liste des modules de recette se DERIVE de l'arbre, pas d'un tableau en dur" {
  # C'est la recette que la machine jouera qui decide quels providers il lui faut. Un tableau en dur
  # ici serait un second exemplaire de ce que le Dockerfile enumere.
  grep -q 'product_tree)/services/forge-recipe' "$MOD"
}

@test "la SONDE hors-ligne ne passe pas par run_quiet — son echec est ATTENDU" {
  # `run_quiet` a pour contrat que l'echec COMPTE : il appelle `p_fail` et incremente PROV_FAILED.
  # L'init hors-ligne du premier passage DOIT echouer — c'est tout ce qu'il mesure. Mesure a froid
  # du 2026-08-22 : deux FAIL et un verdict rouge sur un module dont le miroir venait d'etre pose.
  #
  # La regle : on ne sonde pas avec un outil qui juge.
  local body="$BATS_TEST_TMPDIR/body2.sh"
  grep -vE '^\s*#' "$MOD" > "$body"
  # la sonde (premier init, celui qui decide) est nue et muette
  grep -E 'init -input=false' "$body" | head -1 | grep -qv 'run_quiet'
  grep -E 'init -input=false' "$body" | head -1 | grep -q '>/dev/null 2>&1'
  # le miroir, lui, DOIT reussir : il reste sous un outil qui juge
  grep -q 'run_quiet env -C "\$m" "\$TOFU_BIN" providers mirror' "$body"
}

@test "l'init ne touche PAS l'arbre de l'operateur — ce module tourne en root" {
  # `tofu init` ECRIT (`.terraform/` a cote de la recette) et ce module est `NEEDS: root`. Mesure au
  # nettoyage de .63 le 2026-08-22 : l'operateur ne pouvait plus effacer son propre checkout,
  # `Permission denied` sur chaque provider. `60-deploy` porte deja la regle pour l'autre outil
  # (« un build root polluerait le _build du checkout ») ; elle vaut pour tout ce qui ecrit.
  local body="$BATS_TEST_TMPDIR/body3.sh"
  grep -vE '^\s*#' "$MOD" > "$body"
  # on travaille sur une COPIE jetable
  grep -q 'mktemp -d' "$body"
  grep -q 'cp -a "\$src/\." "\$work/"' "$body"
  grep -q 'rm -rf "\$work/.terraform" "\$work/instance/.terraform"' "$body"
  # et AUCUN init/mirror ne vise un chemin derive de repo_root
  grep -E 'init -input=false|providers mirror' "$body" | refute_out 'repo_root'
  # la copie est effacee sur CHAQUE sortie : les quatre echecs et les deux succes
  local n_exit n_rm
  n_exit="$(grep -c 'verdict_apply' "$body")"
  n_rm="$(grep -c 'rm -rf "\$work"' "$body")"
  [ "$n_rm" -ge 6 ]
}

# ─── LOT 15 : LES MODES DE tofu/* SONT MESURES PAR LEUR POSEUR ──────────────────────────────────
#
# La table declare `tofu`, `tofu/providers` (0755 root:root) et l'ancre `/usr/local/bin/tofu`, et
# AUCUN module ne les mesurait : ce module testait `-d` et `-x`. Les ajouter a la table de
# `25-directories` en aurait fait un second poseur (mur POSEUR) — le mode se relit par qui le pose.

stub_tofu() { # une doublure a la version epinglee : aucun reseau, et `init` repond oui
  mkdir -p "$(dirname "$LCARS_TOFU_BIN")"
  printf '#!/usr/bin/env bash\ncase "${1:-}" in version) echo "OpenTofu v1.12.3" ;; *) exit 0 ;; esac\n' > "$LCARS_TOFU_BIN"
  chmod 0755 "$LCARS_TOFU_BIN"
}

@test "MODE : tofu/ et tofu/providers se relisent contre la table — 0700 est un DRIFT NOMME, 0755 est OK" {
  local me; me="$(id -un):$(id -gn)"
  stub_tofu
  mkdir -p "$LCARS_TOFU_DIR/providers"; printf 'x\n' > "$LCARS_TOFU_DIR/tofurc"
  chmod 0755 "$LCARS_TOFU_DIR"; chmod 0700 "$LCARS_TOFU_DIR/providers"
  mod check
  [ "$status" -eq 1 ]
  [[ "$output" == *"$LCARS_TOFU_DIR/providers : 700 $me ≠ 755 $me"* ]] || { echo "$output"; return 1; }
  [[ "$output" == *"system.manifest"* ]]
  [[ "$output" == *"$LCARS_TOFU_DIR 755 $me (table)"* ]]
  chmod 0755 "$LCARS_TOFU_DIR/providers"
  mod check
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"$LCARS_TOFU_DIR/providers 755 $me (table)"* ]]
}

@test "MODE : l'ancre /usr/local/bin/tofu se relit aussi — un binaire 0700 est un drift, meme a la bonne version" {
  local me; me="$(id -un):$(id -gn)"
  stub_tofu; chmod 0700 "$LCARS_TOFU_BIN"
  mod check
  [[ "$output" == *"tofu 1.12.3 posé"* ]]
  [[ "$output" == *"$LCARS_TOFU_BIN : 700 $me ≠ 755 $me"* ]] || { echo "$output"; return 1; }
}

@test "MODE : l'apply CONVERGE le miroir et l'ancre par ensure_mode — sans reseau, avec une doublure a la version epinglee" {
  # Le miroir se refait sur le verdict d'un `init` hors-ligne (la doublure dit oui) : rien ne part
  # sur le reseau, et le module ne pose que ce qui manque — ici le MODE de ce qui est deja la.
  stub_tofu; chmod 0700 "$LCARS_TOFU_BIN"
  mkdir -p "$LCARS_TOFU_DIR/providers"; chmod 0700 "$LCARS_TOFU_DIR" "$LCARS_TOFU_DIR/providers"
  mod apply
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(stat -c '%a' "$LCARS_TOFU_BIN")" = "755" ]
  [ "$(stat -c '%a' "$LCARS_TOFU_DIR")" = "755" ]
  [ "$(stat -c '%a' "$LCARS_TOFU_DIR/providers")" = "755" ]
  [[ "$output" == *"miroir de providers complet"* ]]
  mod check
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

# ─── LE CANAL : SOUS `deb`, TOFU EST AU PAQUET lcars-tofu (lot 2, 2026-09-05) ───────────────────
