#!/usr/bin/env bats
# SOURCE: fleet/deploy/tests/ops_branch.bats
# AUTHOR: DrDree
# STARDATE: 2026-08-20
# STATUS: bats tests for 52-ops-branch — la boite aux lettres, et la difference entre « pas encore » et « en panne »
#
# CE QUE CE MODULE POSE. Une branche ORPHELINE sur le depot ops : la boite aux lettres ou un pod
# depose sa demande d'outillage et ou un humain signe. Aucune API Gitea ne sait creer un commit sans
# parent — `POST /branches` exige `old_ref_name`, la ressource tofu n'a meme pas de champ de base —
# donc le geste passe par git, UNE fois, dans un depot jetable. Verifie sur banc neuf le 2026-08-20 :
# `parents: 0`.
#
# ⚠ CE QUE CES TEMOINS TIENNENT VRAIMENT, c'est la difference entre deux silences. Le module tourne
# en 52 ; le jeton systeme est minte par 50 — mais au PREMIER boot la forge n'est pas encore semee,
# donc 50 n'a rien pu frapper et le fichier n'existe pas. Rendre ECHEC faisait publier `rc=1` a une
# boite dont le seul tort etait d'etre neuve, et le vrai etat — « ca se posera a la convergence
# suivante » — n'etait dit nulle part. Un DRIFT dit exactement ca, et un jeton qui ne viendrait
# JAMAIS reste visible a chaque passage au lieu de disparaitre dans un echec de boot que personne
# ne relit.
#
# Le contrat des codes est celui de tous les modules : apply 0 = convergé · 1 = ECHEC · 2 = applique
# avec drift residuel. « Pas encore » vaut 2, jamais 1.

setup() {
  MODULE="$BATS_TEST_DIRNAME/../modules.d/52-ops-branch.sh"
  [ -f "$MODULE" ]
  export PROVISION_LIB="$BATS_TEST_DIRNAME/../lib/provision-lib.sh"
  BIN="$BATS_TEST_TMPDIR/bin"; mkdir -p "$BIN"; export PATH="$BIN:$PATH"
  export PROV_FORGE_URL="http://forge.test"
  export PROV_TOKENS_DIR="$BATS_TEST_TMPDIR/private"; mkdir -p "$PROV_TOKENS_DIR"
}

# $1 = code HTTP de la BRANCHE (200 presente · 404 absente) · $2 = code HTTP du DEPOT (defaut 200)
# ⚠ L'ORDRE DES MOTIFS EST LE TEMOIN. L'URL du depot est un PREFIXE de celle de la branche :
# `*/repos/*` matche les deux. La branche doit donc etre testee EN PREMIER, sinon la sonde de branche
# recoit le code du depot et les deux cas fusionnent — exactement l'ambiguite que le module corrige.
stub_curl() {
  cat > "$BIN/curl" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do
  case "\$a" in
    */api/v1/version) exit 0 ;;
    */branches/*) printf '$1'; exit 0 ;;
    */api/v1/repos/*) printf '${2:-200}'; exit 0 ;;
  esac
done
exit 0
EOF
  chmod +x "$BIN/curl"
}

@test "jeton PAS ENCORE la : drift (rc 2), jamais un echec — une boite neuve n'est pas en panne" {
  stub_curl 404
  export PROV_SYSTEM_TOKEN_FILE="$PROV_TOKENS_DIR/absent.gitea_token"
  run bash "$MODULE" apply
  [ "$status" -eq 2 ]
  [[ "$output" == *"DRIFT"* ]]
  [[ "$output" == *"pas encore"* ]]
  # Le message dit QUI le posera et QUAND ca se fermera — sans ca, « pas encore » est une excuse.
  [[ "$output" == *"50-forge"* ]]
  [[ "$output" == *"convergence suivante"* ]]
}

@test "DEPOT pas encore seme : drift (rc 2) — la cible nait a l'amorcage, pas ici" {
  # ⚠ LE SECOND « PAS ENCORE », QUE LE PREMIER CACHAIT. Sur banc neuf l'ordre reel est : boot 1 (pas
  # de jeton) · amorcage passe 1 (structure, pas de semis) · boot 2 (jeton frappe, DEPOT PAS ENCORE
  # LA) · amorcage passe 2 (semis). Au seul boot qui avait un jeton, la cible n'existait pas : git
  # poussait dans le vide et la forge repondait « Push to create is not enabled for organizations »
  # en 403 — un message qui envoie chercher un reglage de forge pour un depot qui n'est pas ne.
  stub_curl 404 404
  export PROV_SYSTEM_TOKEN_FILE="$PROV_TOKENS_DIR/x.gitea_token"
  printf 'TOK\n' > "$PROV_SYSTEM_TOKEN_FILE"
  run bash "$MODULE" apply
  [ "$status" -eq 2 ]
  [[ "$output" == *"DRIFT"* ]]
  # ⚠ ON EPINGLE LE FAIT, PAS LE LIBELLE. Ce temoin exigeait « pas encore seme » mot pour mot et est
  # tombe quand le message a cesse d'affirmer une propriete d'un AUTRE artefact (« l'amorcage de la
  # forge le cree » — personne ne le creait). Ce qui doit tenir : la derive NOMME le depot, et elle
  # dit que le passage suivant la ferme.
  [[ "$output" == *"$LCARS_OPS_REPO"* ]]
  [[ "$output" == *"convergence suivante"* ]]
}

@test "DEPOT dont l'existence est INCONNUE : echec — on ne pousse pas a l'aveugle" {
  # 404 dit « il n'est pas ne » ; 500 ou une reponse vide ne disent rien. Degrader le second en drift
  # rendrait muet un depot supprime ou une forge a moitie morte.
  stub_curl 404 500
  export PROV_SYSTEM_TOKEN_FILE="$PROV_TOKENS_DIR/x.gitea_token"
  printf 'TOK\n' > "$PROV_SYSTEM_TOKEN_FILE"
  run bash "$MODULE" apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"ne dit pas s'il existe"* ]]
}

@test "branche DEJA presente : rien n'est touche — elle porte des signatures humaines" {
  stub_curl 200
  export PROV_SYSTEM_TOKEN_FILE="$PROV_TOKENS_DIR/x.gitea_token"
  printf 'TOK\n' > "$PROV_SYSTEM_TOKEN_FILE"
  run bash "$MODULE" apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"déjà présente"* ]]
}

@test "forge injoignable : DRIFT (rc 2) — pas convergé, mais pas cassé non plus" {
  # ⚖ CE TEMOIN DISAIT « ECHEC FRANC », ET IL AVAIT TORT SUR DEUX PLANS — correction du 2026-08-21.
  #
  # 1. IL NE TENAIT PAS CE QU'IL DISAIT. Son assertion etait `[ "$status" -ne 0 ]`, et le contrat du
  #    rail distingue 1 (echec) de 2 (applique, drift residuel). « Non nul » couvre les deux : le
  #    temoin pose pour garder la ligne fail/drift ne la gardait pas. Passer le module de p_fail a
  #    p_drift ne l'a pas fait broncher.
  #
  # 2. LE MODULE SE CONTREDISAIT LUI-MEME. Sur la MEME mesure — `probe` rend 2, la forge ne repond
  #    pas — `check` disait drift et `apply` disait echec. Or le modele du rail est que le doctor
  #    n'est pas un autre code, c'est le meme check. Deux verdicts opposes sur une mesure unique
  #    n'est pas une nuance, c'est une contradiction.
  #
  # ET LE MOTIF D'ORIGINE — « une forge muette ne dit rien de la branche, la degrader en drift
  # rendrait vert un rail dont personne n'a mesure la moitie » — ne tient pas : drift N'EST PAS
  # vert. C'est rc 2, il s'imprime DRIFT, il remonte dans le bilan, et la porte le nomme desormais
  # (« APPLIQUE, avec DRIFT RESIDUEL »). Ce que l'ancien verdict produisait, en revanche, etait
  # concret : sur une machine dediee a froid la forge n'existe PAS encore — `48-forge-host` la
  # monte — et ses deux voisins immediats, `50-forge` et `55-deck-oidc`, derivent sur cette cause
  # exacte. Ce module seul rendait 1, donc l'apply entier rendait 1, donc l'installation etait
  # declaree EN ECHEC alors qu'il manquait un geste. Mesure du 2026-08-21 :
  #   DRIFT 48-forge-host · DRIFT 50-forge · **FAIL 52-ops-branch** · DRIFT 55-deck-oidc
  cat > "$BIN/curl" <<'EOF'
#!/usr/bin/env bash
exit 7
EOF
  chmod +x "$BIN/curl"
  export PROV_SYSTEM_TOKEN_FILE="$PROV_TOKENS_DIR/x.gitea_token"
  printf 'TOK\n' > "$PROV_SYSTEM_TOKEN_FILE"
  run bash "$MODULE" apply
  # LE CODE EXACT, PAS « NON NUL » : 2 = applique avec drift residuel, 1 = echec. C'est toute la
  # difference entre « il manque un geste » et « quelque chose est casse », et c'est elle que ce
  # temoin existe pour garder.
  [ "$status" -eq 2 ]
  [[ "$output" == *"injoignable"* ]]
  [[ "$output" == *"DRIFT"* ]]

  # ET `check` DIT LA MEME CHOSE SUR LA MEME MESURE — c'est la contradiction qui a ete fermee.
  #
  # ⚠ LES DEUX VERBES N'ENCODENT PAS LE DRIFT AVEC LE MEME CHIFFRE, et c'est une des raisons pour
  # lesquelles la contradiction est passee inapercue. Contrat, en tete de `deploy/provision` :
  #     check : 0 conforme · 1 DRIFT      · 2 erreur de sonde
  #     apply : 0 convergé · 1 echec      · 2 APPLIQUE, drift residuel
  # Le meme « 2 » veut donc dire « sonde cassee » d'un cote et « il manque un geste » de l'autre.
  # Lire ces codes de memoire est une faute qui se paie ; ce temoin les epingle tous les deux.
  run bash "$MODULE" check
  [ "$status" -eq 1 ]
  [[ "$output" == *"DRIFT"* ]]
}

@test "le nom de la branche est GELE dans le module — il ne se lit dans aucune variable" {
  # Son autorite est `Fleet.Toolchain.branch/0`, et le contrat `toolchain.branch_single_source` du
  # gate tient la recopie. Ce temoin-ci garde l'autre moitie : que ce fichier ne rouvre pas une
  # molette locale, ce qui redonnerait au nom deux sources dont une seule serait verifiee.
  grep -qE '^readonly OPS_BRANCH="tool_request"' "$MODULE"
  ! grep -q 'LCARS_SYSADMIN_BRANCH' "$MODULE"
}

@test "le depot ops est CREE par l'amorcage — il etait lu par trois domaines et cree par aucun" {
  # ⚠ TROU MESURE LE 2026-08-22. `Fleet.Toolchain.ops_repo/0`, `IncidentRegistry.Escalation` et
  # `pod_tools/delegation.ex` visent tous `fleet/lcars` ; le seul `create_repo` du runtime sert aux
  # depots de PROJET, et la recette tofu ne cree AUCUN depot. Resultat : derive a chaque passage sur
  # les deux substrats, et un 404 sur ce depot lu comme une panne de l'IncidentRegistry.
  local g="$BATS_TEST_DIRNAME/../docker/forge-gestures.sh"
  code() { grep -vE '^\s*#' "$g"; }
  code | grep -q 'ensure_ops_repo()'
  # il est APPELE dans la passe d'apply, pas seulement defini
  code | sed -n '/^cmd_apply()/,/^}/p' | grep -q 'ensure_ops_repo'
  # `auto_init` : un depot vide n'a pas de branche, et 52-ops-branch pousse SUR une branche
  code | grep -q '\\"auto_init\\":true'
}

@test "la creation RELIT au lieu de croire le code du POST" {
  # Meme regle que la protection de branche : une v1 concluait « deja present » sur un 409/422 alors
  # que Gitea rend d'autres codes selon la version.
  local g="$BATS_TEST_DIRNAME/../docker/forge-gestures.sh"
  local body; body="$(grep -vE '^\s*#' "$g" | sed -n '/^ensure_ops_repo()/,/^}/p')"
  [ "$(grep -c 'api/v1/repos/\$repo' <<<"$body")" -ge 2 ]
  grep -q 'NON cree (HTTP \$code)' <<<"$body"
}

@test "le message de derive n'affirme plus une propriete d'un AUTRE artefact" {
  # « l'amorcage de la forge le cree » etait une affirmation sur un voisin, et elle etait fausse. Un
  # commentaire perime est un mensonge ; un MESSAGE perime en est un que l'operateur lit.
  local m="$BATS_TEST_DIRNAME/../modules.d/52-ops-branch.sh"
  grep -q 'forge-gestures apply' "$m"
  grep -q 'il ne suppose plus qui le fait' "$m"
}
