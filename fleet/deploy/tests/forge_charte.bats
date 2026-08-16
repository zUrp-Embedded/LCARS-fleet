#!/usr/bin/env bats
# SOURCE: fleet/deploy/tests/forge_charte.bats
# AUTHOR: drdree
# STARDATE: 2026-08-14
# STATUS: bats tests for deps/provision-forge-charte.sh — 6-115 + la fuite argv jumelle
#
# CE SCRIPT N'AVAIT AUCUN TEST, et il porte le jeton SITE-ADMIN de la forge — celui qui, avec un
# header `Sudo:`, agit au nom de n'importe quel compte.
#
# ⚠ LA FUITE ETAIT UNE PROPRIETE QUE L'APPELANT PAYAIT DEJA. `charte.tf` ecrit noir sur blanc :
# « le master-token passe par l'ENVIRONNEMENT, jamais par la ligne de commande : un argument est
# visible dans la table des processus ». Le script la defaisait a son premier curl. Le commentaire
# et le code se contredisaient de part et d'autre d'une frontiere de fichier — et aucun des deux
# n'etait relu avec l'autre.
#
# Dispositif identique a `role_tokens.bats` : un faux `curl` en tete de PATH qui journalise `"$@"`
# ET son stdin. Chaque assertion d'attaque va par paire avec un temoin (P-40) : « le secret n'est
# pas dans argv » est satisfait par un correctif qui supprimerait l'auth.

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../deps/provision-forge-charte.sh"
  [ -f "$SCRIPT" ]

  BIN="$BATS_TEST_TMPDIR/bin"
  AVATARS="$BATS_TEST_TMPDIR/avatars"
  mkdir -p "$BIN" "$AVATARS"
  # Les PNG sont DERIVES de la table du script, jamais listes ici : une entree ajoutee la-bas ferait
  # sinon echouer ces tests pour une raison qui n'est pas la leur (« asset introuvable »), et le
  # verdict de succes — ce qu'ils mesurent — ne serait jamais atteint.
  while IFS= read -r png; do
    : > "$AVATARS/$png"
  done < <(sed -n 's/^  "[^"]*:\([^"]*\.png\)".*/\1/p' "$SCRIPT")
  # Le badge du master (`--admiral`) n'est PAS dans la table : il s'y ajoute au parsing. Son PNG se
  # derive donc de la ligne qui l'ajoute, pour la meme raison que ci-dessus — l'ecrire en dur ici
  # ferait echouer ces tests sur « asset introuvable » le jour ou la charte change de fichier.
  while IFS= read -r png; do
    : > "$AVATARS/$png"
  done < <(sed -n 's/.*ENTRIES+=(.*:\([^"]*\.png\)".*/\1/p' "$SCRIPT")

  ARGV_LOG="$BATS_TEST_TMPDIR/argv.log"
  STDIN_LOG="$BATS_TEST_TMPDIR/stdin.log"
  : > "$ARGV_LOG"
  : > "$STDIN_LOG"

  cat > "$BIN/curl" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$ARGV_LOG"
if [[ " $* " == *" -K "* ]]; then cat >> "$STDIN_LOG"; fi
# 200 sur la sonde d'existence du compte, 204 sur le POST de l'avatar : les deux codes que le
# script accepte. Ce qui est mesure n'est pas le protocole, mais il faut le franchir pour atteindre
# le VERDICT, qui est le sujet de la moitie 6-115.
if [[ " $* " == *" -X POST "* ]]; then printf '204'; else printf '200'; fi
FAKE
  chmod +x "$BIN/curl"

  cat > "$BIN/jq" <<'FAKE'
#!/usr/bin/env bash
cat >/dev/null
printf ''
FAKE
  chmod +x "$BIN/jq"

  export ARGV_LOG STDIN_LOG
  export PATH="$BIN:$PATH"
}

run_avatars() {
  run env FORGE_ADMIN_TOKEN="JETON-ADMIN-SECRET" "$SCRIPT" \
    --forge http://forge.test --avatars-dir "$AVATARS" --org "" "$@"
}

@test "6-141bis: le jeton SITE-ADMIN n'apparait JAMAIS dans argv" {
  run_avatars
  run grep -c "JETON-ADMIN-SECRET" "$ARGV_LOG"
  [ "$output" = "0" ]
}

@test "6-141bis: TEMOIN — il est bien passe, par stdin (sinon on aurait supprime l'auth)" {
  run_avatars
  grep -q 'header = "Authorization: token JETON-ADMIN-SECRET"' "$STDIN_LOG"
}

@test "6-141bis: un jeton qui porte des guillemets traverse INTACT" {
  # La config de curl est un format cite : une valeur non echappee couperait le jeton en deux et
  # l'auth partirait tronquee — un echec qui ressemble a un jeton revoque.
  run env FORGE_ADMIN_TOKEN='a"b\c' "$SCRIPT" \
    --forge http://forge.test --avatars-dir "$AVATARS" --org ""
  grep -q 'header = "Authorization: token a\\"b\\\\c"' "$STDIN_LOG"
  run grep -c 'a"b' "$ARGV_LOG"
  [ "$output" = "0" ]
}

@test "6-115: le verdict ne dit plus « tous les avatars », il dit SUR QUOI il porte" {
  # « tous les avatars posés/valides » est vrai de LA CHARTE et faux de la population : `chief` a un
  # compte et un jeton, aucune entree de charte, donc aucun avatar — sous un verdict qui disait le
  # contraire. La table n'est PAS un roster (son propre commentaire l'interdit) : ce qui se corrige
  # est la PORTEE de la phrase.
  run_avatars
  [[ "$output" != *"tous les avatars"* ]]
  [[ "$output" == *"entrée(s) de charte"* ]]
  [[ "$output" == *"tenue à la main"* ]]
}

@test "TEMOIN 6-115: le verdict compte REELLEMENT les entrees, il ne recite pas un chiffre" {
  # Sans ce temoin, un verdict qui afficherait « 0 entrée(s) » passerait le test ci-dessus.
  run_avatars
  [[ "$output" =~ ([0-9]+)\ entrée\(s\)\ de\ charte ]]
  [ "${BASH_REMATCH[1]}" -ge 8 ]
}

# ─── LE BADGE DU MASTER (2026-08-15) ─────────────────────────────────────────────────────────────
# Le compte forge `starfleet` est supprime (instance/accounts.tf) : le canon declarait « no forge
# account » pendant que le provisionnement en creait un, en site-admin. Son BADGE passe au master.
#
# Il est PARAMETRE et pas ecrit en dur : le login du master est `admiral` au banc et celui de
# l'installeur en prod. Une entree fixe ne poserait rien ailleurs qu'au banc, EN SILENCE — un compte
# de la table absent de la forge est tolere depuis la mesure du catalogue `web`. Le defaut sans
# option est donc « rien », ce qui preserve aussi la regle ecrite dans la table : « l'humain n'est
# pas liste, il pose son propre avatar ».

@test "badge: --admiral pose le badge de starfleet sur le login nomme" {
  # Gitea n'a pas d'endpoint par-compte : c'est POST /user/avatar + un en-tete `Sudo: <compte>`,
  # l'admin agissant AU NOM du compte. Le login vit donc dans l'en-tete, jamais dans l'URL — une
  # assertion sur `users/<login>/avatar` mesurerait une route qui n'existe pas.
  run_avatars --admiral chef-de-banc
  [ "$status" -eq 0 ]
  grep -q "Sudo: chef-de-banc" "$ARGV_LOG"
}

@test "badge: SANS --admiral, aucun avatar n'est pose sur un compte humain" {
  # Le temoin qui rend le precedent falsifiable : sans lui, un script qui poserait le badge sur un
  # login code en dur passerait le test ci-dessus des que ce login serait `chef-de-banc`.
  run_avatars
  [ "$status" -eq 0 ]
  run grep -c "chef-de-banc" "$ARGV_LOG"
  [ "$output" = "0" ]
}

@test "badge: SANS --admiral, le badge suit la resolution par id=1 — MEME resolution que le siege" {
  # ⚠ LA REGRESSION QUE CE TEMOIN GARDE, ET ELLE A EU LIEU (2026-08-16, attrapee par la sonde du
  # banc). Le nom du siege se repliait sur `id=1`, le BADGE entrait dans la table au PARSING : le
  # jour ou l'appelant a cesse de nommer le master — parce que ce login se DERIVE — le siege a garde
  # son nom et l'avatar du master a disparu, en silence. Deux resolutions pour un fait, et c'est
  # celle qu'on ne teste pas qui casse.
  cat > "$BIN/jq" <<'FAKE'
#!/usr/bin/env bash
cat >/dev/null
# La seule question posee a jq avant la table : « qui porte l'id 1 ? »
case "$*" in *'.id == 1'*) printf 'le-master\n' ;; *) printf '' ;; esac
FAKE
  chmod +x "$BIN/jq"
  : > "$AVATARS/admiral.png"

  run_avatars
  [ "$status" -eq 0 ]
  grep -q "Sudo: le-master" "$ARGV_LOG"
}

@test "badge: le compte starfleet n'est plus servi — son avatar ne part que vers le master" {
  # La regression que ce temoin garde : re-ajouter `starfleet:admiral.png` a la table ferait
  # reapparaitre un POST vers un compte que la forge ne porte plus, et le verdict compterait une
  # entree de charte de plus pour rien.
  run_avatars --admiral admiral
  run grep -c "Sudo: starfleet" "$ARGV_LOG"
  [ "$output" = "0" ]
  # ...et le badge est bien parti vers le master, sinon ce test passerait sur un script muet.
  grep -q "Sudo: admiral" "$ARGV_LOG"
}

# ─── LE NOM DU SIEGE MASTER (2026-08-15) ─────────────────────────────────────────────────────────
# Le master porte le nom de son SIEGE en `full_name`, pas celui d'une personne : ce compte n'est pas
# une identite de travail (personne ne travaille sous root), et la boite le barre a tous les etages
# — Guard B, `console-humans`, la porte admin du deck. Resolution : `--admiral` d'abord, sinon l'id 1
# (le premier compte cree par Gitea, site-admin par construction).

@test "siege: --admiral l'emporte, et le PATCH porte les champs que Gitea EXIGE" {
  run_avatars --admiral chef-de-banc
  [ "$status" -eq 0 ]
  grep -q "admin/users/chef-de-banc" "$ARGV_LOG"
  # `login_name` et `source_id` sont obligatoires dans le corps meme sans les changer : sans eux
  # Gitea rend 422. Le temoin les epingle, sinon la regression revient en silence.
  grep -q -- '-X PATCH' "$ARGV_LOG"
  grep -q '"login_name":"chef-de-banc"' "$ARGV_LOG"
  grep -q '"source_id":0' "$ARGV_LOG"
  grep -q '"full_name":"admiral"' "$ARGV_LOG"
}

@test "siege: SANS --admiral, la resolution passe par l'id 1 et n'invente rien" {
  # Le stub `jq` rend '' : aucun master resolu, donc AUCUN patch. C'est le contre-temoin du
  # precedent — un script qui ecrirait sur un login code en dur passerait le test ci-dessus.
  run_avatars
  [ "$status" -eq 0 ]
  run grep -c -- '-X PATCH' "$ARGV_LOG"
  [ "$output" = "0" ]
}

@test "siege: un master introuvable est DIT, jamais silencieux" {
  run_avatars
  [ "$status" -eq 0 ]
  [[ "$output" == *"IGNORE nom du siege"* ]]
}

@test "siege: --check ne touche a rien — il sonde, il n'ecrit pas" {
  run_avatars --admiral chef-de-banc --check
  run grep -c -- '-X PATCH' "$ARGV_LOG"
  [ "$output" = "0" ]
}

# ─── LA SONDE DU NOM DE SIEGE (2026-08-15) ───────────────────────────────────────────────────────
# Le generique POSE (charte.tf, avec le master-token), le banc VERIFIE. Cette repartition n'est pas
# un choix de style : `charte.tf` passe une variable `sensitive` au provisioner, donc OpenTofu
# SUPPRIME toutes ses lignes de sortie (« output suppressed due to sensitive value in config »,
# mesure du 2026-08-15). Le verdict de pose n'est lisible par aucun appelant — la sonde est le seul
# moyen de savoir ce qui est REELLEMENT sur la forge.

@test "sonde: --check verifie le nom du siege sans aucune autorite" {
  run_avatars --admiral chef-de-banc --check
  # Le champ est PUBLIC (`/users/<login>`), donc la sonde n'a pas besoin du master-token : elle
  # interroge le compte, jamais l'endpoint d'admin.
  grep -q "users/chef-de-banc" "$ARGV_LOG"
  run grep -c "admin/users" "$ARGV_LOG"
  [ "$output" = "0" ]
}

@test "sonde: sans --admiral, --check ne DEVINE pas le master — il le dit" {
  # La resolution par id=1 passe par `/admin/users`, qui exige l'autorite : une sonde qui la
  # tenterait rendrait un verdict sur un compte qu'elle a choisi elle-meme.
  run_avatars --check
  [[ "$output" == *"IGNORE nom du siege"* ]]
  run grep -c "admin/users" "$ARGV_LOG"
  [ "$output" = "0" ]
}
