#!/usr/bin/env bats
# SOURCE: fleet/deploy/tests/media_tree.bats
# AUTHOR: DrDree
# STARDATE: 2026-08-22
# STATUS: bats tests for 44-media — les medias partages, jumeau FICHIER du trou ISO des paquets
#
# `assets/` est la source ; le Dockerfile la pose en `/usr/share/lcars/{avatars,favicon}`. Aucun
# module de provision ne le faisait. Le trou etait COSMETIQUE tant que la recette de charte tournait
# DANS l'image ; en sortant tofu du conteneur, il est devenu un echec dur :
#
#   provision-forge-charte: dossier avatars introuvable: /usr/share/lcars/avatars
#
# ⚠ LE CHEMIN REEL SE NOMME, SINON LE TEMOIN MESURE LA MACHINE. `/usr/share/lcars` peut exister sur
# un poste de dev. Cinquieme occurrence de ce piege apres `/etc/lcars/host-consent`, `ttyd`, `tofu`
# et le reseau de `deck_origins`.

# ⚠ SC2016 : CE TEMOIN LIT DU CODE. Ses motifs `grep`/`sed` portent des `${VAR:-defaut}` qui
# doivent atteindre l'outil TELS QUELS — les developper chercherait la valeur dans CE shell au lieu
# du texte audite. Les quotes simples sont l'instrument, pas un oubli.
# shellcheck disable=SC2016

setup() {
  local _v
  while read -r _v; do unset "$_v" 2>/dev/null || true; done \
    < <(compgen -v | grep -E '^(LCARS_|PROV_)' || true)

  MOD="$BATS_TEST_DIRNAME/../modules.d/44-media.sh"
  DOCKERFILE="$BATS_TEST_DIRNAME/../docker/Dockerfile"
  ASSETS="$BATS_TEST_DIRNAME/../../../assets"
  [ -f "$MOD" ] && [ -f "$DOCKERFILE" ] && [ -d "$ASSETS" ]

  export PROVISION_LIB="$BATS_TEST_DIRNAME/../lib/provision-lib.sh"
  export PROVISION_MODULE=44-media
  export PROV_SUBSTRATE=linux
  export PROV_HUMAN
  PROV_HUMAN="$(id -un)"
  export PROV_FLEET_GROUP
  PROV_FLEET_GROUP="$(id -gn)"
  export PROV_TOKENS_DIR="$BATS_TEST_TMPDIR/private"
  export XDG_RUNTIME_DIR="$BATS_TEST_TMPDIR/xdg"; mkdir -p "$XDG_RUNTIME_DIR"; chmod 0700 "$XDG_RUNTIME_DIR"

  export LCARS_MEDIA_ROOT="$BATS_TEST_TMPDIR/share/lcars"
  export LCARS_MEDIA_OWNER
  LCARS_MEDIA_OWNER="$(id -un):$(id -gn)"

  # ⚠ AUCUN TEMOIN NE BATIT LE SITE, ET CE N'EST PAS UNE COMMODITE. Sans ces deux coutures la suite
  # jouait un `npm ci` REEL dans le checkout de celui qui la lance : des minutes, du reseau, et un
  # resultat qui depend de sa machine. Ce qui se mesure ici est la DERIVATION — la base passee, la
  # pose atomique, le refus quand npm manque — jamais la sortie d'astro.
  export LCARS_SITE_SRC="$BATS_TEST_TMPDIR/site"
  mkdir -p "$LCARS_SITE_SRC"
  export LCARS_NPM_BIN="$BATS_TEST_TMPDIR/bin/npm"
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  # Le faux npm ECRIT ce qu'un vrai build ecrit, et TRACE la base qu'on lui a passee : c'est le seul
  # fait que ce module doit garantir cote build.
  cat > "$LCARS_NPM_BIN" <<'SH'
#!/usr/bin/env bash
echo "npm $*" >> "${NPM_TRACE:?}"
if [[ "${1:-}" == "run" && "${2:-}" == "build" ]]; then
  echo "base=${LCARS_SITE_BASE:-<vide>}" >> "$NPM_TRACE"
  mkdir -p dist && printf '<html>doc</html>' > dist/index.html
fi
SH
  chmod +x "$LCARS_NPM_BIN"
  export NPM_TRACE="$BATS_TEST_TMPDIR/npm.trace"
  : > "$NPM_TRACE"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
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

@test "l'ORDRE porte le sens : ce module vient AVANT 48-forge-host, qui joue la recette" {
  local d="$BATS_TEST_DIRNAME/../modules.d"
  [ -f "$d/44-media.sh" ]
  [ -f "$d/48-forge-host.sh" ]
  # ⚠ CETTE LIGNE COMPARAIT DEUX LITTERAUX. `[[ "44-media" < "48-forge-host" ]]` prouve que « 44 »
  # trie avant « 48 » — de l'arithmetique, pas une propriete de ce depot. Elle serait restee
  # verte apres un renommage de l'un ou l'autre, c'est-a-dire au moment precis ou l'ordre casse.
  # Ce qui est vrai : les deux modules EXISTENT, et le glob du runner met le premier avant.
  local _mods _ia _ib
  _mods="$(cd "$BATS_TEST_DIRNAME/../modules.d" && printf '%s\n' *.sh)"
  _ia="$(grep -nx '44-media.sh' <<<"$_mods" | cut -d: -f1)"
  _ib="$(grep -nx '48-forge-host.sh' <<<"$_mods" | cut -d: -f1)"
  [ -n "$_ia" ] && [ -n "$_ib" ] && [ "$_ia" -lt "$_ib" ]
}

@test "les arbres poses sont EXACTEMENT ceux que le Dockerfile pose — deux rails, un contenu" {
  # C'est la definition du trou : ce que l'image livre et que le rail natif ne livrait pas.
  local t
  for t in avatars favicon; do
    grep -qE "^COPY assets/$t +/opt/lcars/share/$t" "$DOCKERFILE"
    grep -vE '^\s*#' "$MOD" | grep -q "MEDIA_TREES=(.*$t"
  done
}

@test "la doc EST batie et posee — elle n'est pas accessoire" {
  # ⚖ USER 2026-08-22 : « j'ai pas envie de taper un site remote pour afficher la doc locale ».
  #
  # ⚠ CE TEMOIN EPINGLAIT LA DECISION INVERSE (« doc n'est PAS pose, et son absence est MOTIVEE »).
  # C'etait une omission deguisee en decision : la doc est la doc UTILISATEUR du produit, batie du
  # MEME arbre — le site lit `fleet/priv/catalogue` et `pod_tools.ex`. Le laisser dehors rendait un
  # `404 not found` nu sur l'onglet Doc du deck.
  mod apply
  [ -s "$LCARS_MEDIA_ROOT/doc/index.html" ]
}

@test "la BASE du deck voyage jusqu'au build — sinon chaque URL d'asset est fausse" {
  # `astro.config.mjs` fait `base = LCARS_SITE_BASE || '/'`. GitHub Pages batit pour la racine, le
  # deck sert sous `/doc/` : recopier l'artefact Pages ici donnerait un site aux assets casses. Le
  # Dockerfile pose la meme variable pour la meme raison.
  mod apply
  grep -q '^base=/doc/$' "$NPM_TRACE"
  grep -q "^LCARS_SITE_BASE=/doc/" "$BATS_TEST_DIRNAME/../docker/Dockerfile" \
    || grep -q "ENV LCARS_SITE_BASE=/doc/" "$BATS_TEST_DIRNAME/../docker/Dockerfile"
}

@test "npm absent : ECHEC NOMME qui pointe le module qui le pose" {
  export LCARS_NPM_BIN="$BATS_TEST_TMPDIR/bin/npm-absent"
  mod apply
  [ "$status" -ne 0 ]
  [[ "$output" == *"npm absent"* ]]
  [[ "$output" == *"16-node"* ]]
}

@test "la doc se pose ATOMIQUEMENT — un demi-repertoire se sert en 404 silencieux" {
  code() { grep -vE '^\s*#' "$MOD"; }
  code | grep -q 'partial="\$(doc_dir).partial"'
  code | grep -q 'mv "\$partial" "\$(doc_dir)"'
}

@test "le check sonde index.html, pas le repertoire" {
  # Un build interrompu laisse un `doc/` qui existe et que la route sert en 404. La question posee
  # est « le deck a-t-il une page d'accueil a rendre ».
  grep -vE '^\s*#' "$MOD" | grep -q 'doc_dir)/index.html'
  mod check
  [[ "$output" == *"doc absente"* ]] || [[ "$output" == *"doc"* ]]
}

@test "le seam est celui du PRODUIT, pas un second defaut" {
  # `runtime.exs` et `deck.ex` lisent `/usr/share/lcars`. Un module qui inventerait son propre chemin
  # servirait des avatars que personne ne regarde.
  local rt="$BATS_TEST_DIRNAME/../../config/runtime.exs" deck="$BATS_TEST_DIRNAME/../../lib/fleet/observation/deck.ex"
  # ⚠ LES TROIS DEFAUTS S'ACCORDENT, ET C'EST CE TEMOIN QUI L'EXIGE — il a rougi au demenagement
  # sous la racine unique, ce qui est exactement son metier : un seul des trois oublie, et le deck
  # sert des avatars que personne ne regarde.
  grep -q 'LCARS_MEDIA_ROOT", "/opt/lcars/share"' "$rt"
  grep -q ':media_root, "/opt/lcars/share"' "$deck"
  grep -vE '^\s*#' "$MOD" | grep -q 'LCARS_MEDIA_ROOT:-\$PROV_ROOT/share'
}

@test "absent : DRIFT qui nomme les DEUX consequences" {
  mod check
  [ "$status" -eq 1 ]
  [[ "$output" == *"avatars absent"* ]]
  [[ "$output" == *"charte"* ]]
  [[ "$output" == *"génériques"* ]]
}

@test "apply pose les deux arbres, et le CONTENU (jamais avatars/avatars)" {
  mod apply
  [ -f "$LCARS_MEDIA_ROOT/avatars/admiral.png" ]
  [ ! -d "$LCARS_MEDIA_ROOT/avatars/avatars" ]
  [ -d "$LCARS_MEDIA_ROOT/favicon" ]
}

@test "IDEMPOTENT : un second apply ne niche pas les arbres" {
  mod apply
  mod apply
  [ "$status" -eq 0 ]
  [ ! -d "$LCARS_MEDIA_ROOT/avatars/avatars" ]
  [ -f "$LCARS_MEDIA_ROOT/avatars/admiral.png" ]
  # Le mode DÉPLOYÉ est 0755 net — pas 2755 (setgid hérité d'un checkout fleet via `cp -a`, qui
  # faisait échouer `ensure_dir` au 2e apply), pas 0775 (group-write de la source). Le module POSSÈDE
  # le mode de son arbre : ce témoin verrouille la convergence, que la source soit setgid ou non.
  [ "$(stat -c '%a' "$LCARS_MEDIA_ROOT/avatars")" = "755" ]
}

@test "un repertoire VIDE est un DRIFT — l'existence n'est pas la question posee" {
  # Un dossier vide passe un `-d` et fait echouer la recette exactement pareil. C'est la meme classe
  # que « la version se sonde, pas la presence » dans 46-tofu.
  mkdir -p "$LCARS_MEDIA_ROOT/avatars" "$LCARS_MEDIA_ROOT/favicon"
  mod check
  [ "$status" -eq 1 ]
  [[ "$output" == *"incomplet"* ]]
}

@test "apres apply, le check est VERT — les deux verbes lisent la meme regle" {
  mod apply
  mod check
  [ "$status" -eq 0 ]
  [[ "$output" == *"avatars posé"* ]]
}

@test "une source disparue est un ECHEC NOMME, jamais un arbre vide pose en silence" {
  # ⚠ LA SOURCE A UNE COUTURE, ET SANS ELLE CE CHEMIN EST INJOUABLE. `repo_root` vient de la lib, qui
  # la redefinit au source : la surcharger depuis le decor ne tient pas. Un chemin qu'aucun temoin ne
  # peut atteindre est un chemin non ecrit.
  export LCARS_MEDIA_SRC_ROOT="$BATS_TEST_TMPDIR/vide"
  mkdir -p "$LCARS_MEDIA_SRC_ROOT"
  mod apply
  [ "$status" -ne 0 ]
  [[ "$output" == *"source absente"* ]]
  [ ! -d "$LCARS_MEDIA_ROOT/avatars" ]
}
