#!/usr/bin/env bats
# SOURCE: runtime/test/services/provision-role-tokens.bats
# AUTHOR: DrDree
# STARDATE: 2026-07-05
# STATUS: bats tests for runtime/services/provision-role-tokens.sh (A4) — usage, check, idempotent provisioning, failures
#
# The forge is stubbed by a curl SHIM (prepended to PATH): the validity probe (`-w %{http_code}`) reads
# $MOCK/probe_code; the mint POST returns $MOCK/post_response and is COUNTED in $MOCK/calls.log — so
# idempotence is asserted on "zero POST on the second run", not on a printed line. jq is the real one.

load ../support/refute

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../../services/provision-role-tokens.sh"
  TMP="$(mktemp -d)"
  MOCK="$TMP/mock"; mkdir -p "$MOCK"
  TOKDIR="$TMP/tokens"; mkdir -p "$TOKDIR"

  # curl shim: dispatched by call SHAPE (probe -w / DELETE / POST), not by URL — the URL assembly is
  # tested elsewhere; here we test the script's LOGIC. Every call is logged.
  mkdir -p "$TMP/bin"
  cat > "$TMP/bin/curl" <<SHIM
#!/usr/bin/env bash
echo "\$*" >> "$MOCK/calls.log"
# ⚠ STDIN EST JOURNALISE AUSSI, ET C'EST CE QUI REND LES TEMOINS 6-141 POSSIBLES. Le shim de ce
# fichier ne lisait qu'argv : il pouvait donc prouver « le secret n'est pas dans la ligne de
# commande » et pas « il EST dans stdin » — c'est-a-dire ne pas distinguer un secret DEPLACE d'un
# secret PERDU. Les deux moities vont par paire (P-40).
cfg=""
if [[ " \$* " == *" -K "* ]]; then cfg="\$(cat)"; printf '%s\n' "\$cfg" >> "$MOCK/stdin.log"; fi
case " \$* " in
  # Le PATCH de la voie « forcer puis oublier » : la vraie forge rend 200 avec un jeton master
  # valide (mesure du 2026-08-19 sur instance vierge).
  *" -w "*) if [[ "\$cfg" == *'request = "PATCH"'* ]]; then printf '200'
            else cat "$MOCK/probe_code" 2>/dev/null || printf '401'; fi ;;
  *" DELETE "*) exit 0 ;;
  *" POST "*) cat "$MOCK/post_response" 2>/dev/null || printf '{}' ;;
  *) exit 0 ;;
esac
SHIM
  chmod +x "$TMP/bin/curl"
  export PATH="$TMP/bin:$PATH"

  : > "$MOCK/stdin.log"
  PWDFILE="$TMP/passwords.json"
  printf '{"engineer":"pw-eng","qualifier":{"password":"pw-qual"}}' > "$PWDFILE"
}

teardown() { rm -rf "$TMP"; }

@test "LCARS header present (SOURCE/AUTHOR/STARDATE/STATUS)" {
  head -5 "$SCRIPT" | grep -q "SOURCE: runtime/services/provision-role-tokens.sh"
  head -5 "$SCRIPT" | grep -q "STATUS:"
}

@test "--help → exit 0 + usage" {
  run "$SCRIPT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"USAGE"* ]]
}

@test "no --forge and no FORGE_BASE_URL → exit 1 fail-loud" {
  run env -u FORGE_BASE_URL "$SCRIPT" --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"--forge"* ]]
}

@test "provisioning mode WITHOUT --passwords-file → exit 1, never a blind mint" {
  run "$SCRIPT" --forge http://f --owner "$(id -un)" --tokens-dir "$TOKDIR" --roles engineer
  [ "$status" -eq 1 ]
  [[ "$output" == *"droit de mint"* ]]
  [ ! -f "$MOCK/calls.log" ]
}

@test "--admin-token-file REMOVED (stillborn mode: Gitea refuses minting by admin token)" {
  run "$SCRIPT" --forge http://f --owner "$(id -un)" --tokens-dir "$TOKDIR" --admin-token-file /whatever --roles engineer
  [ "$status" -eq 1 ]
  [[ "$output" == *"option inconnue"* ]]
}

@test "unreadable passwords-file → exit 1 (the missing right is STATED, not worked around)" {
  run "$SCRIPT" --forge http://f --owner "$(id -un)" --passwords-file "$TMP/inexistant.json" --roles engineer
  [ "$status" -eq 1 ]
  [[ "$output" == *"illisible"* ]]
}

@test "--check: valid local token (probe 200) → OK, exit 0" {
  printf 'tok-ok\n' > "$TOKDIR/engineer.gitea_token"
  printf '200' > "$MOCK/probe_code"
  run "$SCRIPT" --forge http://f --owner "$(id -un)" --tokens-dir "$TOKDIR" --roles engineer --check
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK    engineer"* ]]
}

@test "--check: invalid token (probe 401) → FAIL, exit 2, file INTACT (--check never writes)" {
  printf 'tok-mort\n' > "$TOKDIR/engineer.gitea_token"
  printf '401' > "$MOCK/probe_code"
  run "$SCRIPT" --forge http://f --owner "$(id -un)" --tokens-dir "$TOKDIR" --roles engineer --check
  [ "$status" -eq 2 ]
  [[ "$output" == *"FAIL  engineer"* ]]
  [ "$(cat "$TOKDIR/engineer.gitea_token")" = "tok-mort" ]
}

@test "le compte est le LOGIN, et le FICHIER aussi" {
  # `<catalogue>_<role>` est la forme du compte forge, parce qu'un username Gitea est unique a
  # l'INSTANCE : sans prefixe, deux catalogues nommant chacun un `dev` se partagent un compte.
  # LE FICHIER SUIT, et il ne suivait pas. Il portait le role seul, donc `fleet_writer` et
  # `web_writer` ecrivaient le MEME `writer.gitea_token` : le catalogue provisionne en second
  # prenait en silence l'identite du premier, et rien ne pouvait le dire — le fichier existe et son
  # contenu est un jeton valide. Le motif de l'ancienne forme (« c'est la cle que le runtime
  # connait ») etait vrai tant que le runtime ne savait pas projeter ; il la projette desormais
  # (`RoleIdentity.token_path/1`), et les deux moities se rencontrent sur ce nom.
  printf 'tok-ok\n' > "$TOKDIR/fleet_engineer.gitea_token"
  printf '200' > "$MOCK/probe_code"
  run "$SCRIPT" --forge http://f --owner "$(id -un)" --tokens-dir "$TOKDIR" --roles fleet_engineer --check
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK    fleet_engineer"* ]]
  [[ "$output" == *"fleet_engineer.gitea_token)"* ]]

  # Deux catalogues nommant le meme role tiennent DEUX fichiers distincts — la propriete perdue.
  printf 'tok-a\n' > "$TOKDIR/fleet_dev.gitea_token"
  printf 'tok-b\n' > "$TOKDIR/web_dev.gitea_token"
  run "$SCRIPT" --forge http://f --owner "$(id -un)" --tokens-dir "$TOKDIR" --roles "fleet_dev web_dev" --check
  [ "$status" -eq 0 ]
  [[ "$output" == *"fleet_dev.gitea_token)"* ]]
  [[ "$output" == *"web_dev.gitea_token)"* ]]
  [ "$(cat "$TOKDIR/fleet_dev.gitea_token")" = "tok-a" ]
  [ "$(cat "$TOKDIR/web_dev.gitea_token")" = "tok-b" ]

  # Un role compose garde son tiret : le souligne ne separe que les deux moities du compte.
  printf 'tok-ok\n' > "$TOKDIR/web_code-reviewer.gitea_token"
  run "$SCRIPT" --forge http://f --owner "$(id -un)" --tokens-dir "$TOKDIR" --roles web_code-reviewer --check
  [ "$status" -eq 0 ]
  [[ "$output" == *"web_code-reviewer.gitea_token)"* ]]
}

# ⚠ CE TEMOIN A CHANGE DE SUJET AVEC LE CONTRAT QU'IL GARDE, ET SON EXIGENCE EST INTACTE.
#
# Il disait « groupe != GROUP ». Le jeton naissait `0640 root:fleet`, et le BEAM le lisait A TRAVERS
# LE GROUPE — un groupe que le convergeur remplissait depuis l'equipe `humans` de la forge toutes les
# trente secondes. Le droit de lire un credential avait donc la peremption d'un cache.
#
# Un SEUL process les ouvre maintenant : le service d'autorite, qui pose la question a la forge a
# l'instant du geste. Ce qui doit etre juste n'est donc plus un groupe mais un PROPRIETAIRE.
#
# L'EXIGENCE, ELLE, EST MOT POUR MOT LA MEME : un jeton valide sur la forge mais que le runtime ne
# peut pas ouvrir est un DEPLOIEMENT CASSE, et l'annoncer POSE + exit 0 le cachait derriere un WARN.
@test "local readability is load-bearing: a token whose owner != OWNER FAILS (unreadable by the service)" {
  printf '{"sha1":"tok-frais"}' > "$MOCK/post_response"
  printf '200' > "$MOCK/probe_code"
  run "$SCRIPT" --forge http://f --owner nonexistent-user-zzz --tokens-dir "$TOKDIR" --passwords-file "$PWDFILE" --roles engineer
  [ "$status" -eq 2 ]
  [[ "$output" == *"FAIL  engineer"* ]]
  [[ "$output" == *"ILLISIBLE"* ]]
  # The token IS on disk (the forge mint cost was real; --check will confirm), just flagged unreadable.
  [ -f "$TOKDIR/engineer.gitea_token" ]
}

@test "happy path: mint (sha1) + probe 200 → file written 0600, exit 0" {
  printf '{"sha1":"tok-frais"}' > "$MOCK/post_response"
  printf '200' > "$MOCK/probe_code"
  run "$SCRIPT" --forge http://f --owner "$(id -un)" --tokens-dir "$TOKDIR" --passwords-file "$PWDFILE" --roles engineer
  [ "$status" -eq 0 ]
  [[ "$output" == *"POSE  engineer"* ]]
  [ "$(cat "$TOKDIR/engineer.gitea_token")" = "tok-frais" ]
  # ⚠ `600`, ET C'EST LE TEMOIN FONCTIONNEL DE LA FERMETURE. Un mur qui greppe `chmod 0600` ne peut
  # PAS voir ce mode : l'ecriture est atomique (tmp + mv), donc le mode et le nom du fichier vivent
  # sur deux lignes differentes. Mesure du 2026-08-25 : remettre `chmod 0640` dans le script ne
  # faisait rougir AUCUN mur — seule cette ligne-ci mord. Un mur textuel garde une forme ; c'est un
  # `stat` sur le fichier reellement pose qui garde le fait.
  [ "$(stat -c %a "$TOKDIR/engineer.gitea_token")" = "600" ]
  grep -q "POST" "$MOCK/calls.log"
}

# ⚠ LE REPERTOIRE, ET PAS SEULEMENT LE FICHIER. Fermer les jetons sans fermer ce qui les porte ne
# ferme rien : ce script POSE le repertoire lui aussi, et il le posait `0750`. Le premier
# `provision apply` suivant aurait donc rouvert au groupe, quel que soit le soin mis aux modes de
# fichiers. Une CLASSE D'OBJET entiere avait ete inventoriee a moitie.
#
# ⚠ ET CE TEMOIN EPINGLAIT `700`, CE QUI EST DEVENU FAUX. Mesure du 2026-08-25 sur une install
# reelle : `/opt/lcars/var/tokens` ne contient pas que des secrets — `forge.url` et `forge.public.url` y sont
# en 0644 — et TROIS modules `NEEDS: human` les lisent sous l'uid de l'humain. En `0700` ils
# prenaient « Permission denied » et le conteneur finissait sans `FORGE_BASE_URL`.
#
# L'exigence n'a pas bouge d'un mot : AUCUN uid humain ne LIT un secret. Ce qui bouge est le moyen —
# le groupe TRAVERSE (`x`), il ne LISTE pas (`r`), et les jetons restent `0600`. C'est ce qui se
# verifie ici, et le chiffre du milieu est la seule chose qui change.
@test "le REPERTOIRE des jetons : le groupe TRAVERSE, il ne LISTE pas" {
  printf '{"sha1":"tok-frais"}' > "$MOCK/post_response"
  printf '200' > "$MOCK/probe_code"
  local dir="$TMP/neuf"
  run "$SCRIPT" --forge http://f --owner "$(id -un)" --tokens-dir "$dir" --passwords-file "$PWDFILE" --roles engineer
  [ "$status" -eq 0 ]
  [ "$(stat -c %a "$dir")" = "710" ]
  # Et le jeton dedans reste ferme : c'est le mode du FICHIER qui le tient, plus celui du dossier.
  [ "$(stat -c %a "$dir/engineer.gitea_token")" = "600" ]
}

@test "idempotence: second run on an already-valid token → OK skip, ZERO new POST" {
  printf '{"sha1":"tok-frais"}' > "$MOCK/post_response"
  printf '200' > "$MOCK/probe_code"
  "$SCRIPT" --forge http://f --owner "$(id -un)" --tokens-dir "$TOKDIR" --passwords-file "$PWDFILE" --roles engineer
  posts_before="$(grep -c POST "$MOCK/calls.log")"
  run "$SCRIPT" --forge http://f --owner "$(id -un)" --tokens-dir "$TOKDIR" --passwords-file "$PWDFILE" --roles engineer
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK    engineer"* ]]
  [ "$(grep -c POST "$MOCK/calls.log")" = "$posts_before" ]
}

@test "password missing from the file for a role → FAIL that role, exit 2 (the others' mint is not masked)" {
  printf '{"sha1":"tok-frais"}' > "$MOCK/post_response"
  printf '200' > "$MOCK/probe_code"
  run "$SCRIPT" --forge http://f --owner "$(id -un)" --tokens-dir "$TOKDIR" --passwords-file "$PWDFILE" --roles "architect engineer"
  [ "$status" -eq 2 ]
  [[ "$output" == *"FAIL  architect"* ]]
  [[ "$output" == *"POSE  engineer"* ]]
}

@test "mint refused (POST without sha1) → FAIL, exit 2, no file written" {
  printf '{"message":"forbidden"}' > "$MOCK/post_response"
  printf '200' > "$MOCK/probe_code"
  run "$SCRIPT" --forge http://f --owner "$(id -un)" --tokens-dir "$TOKDIR" --passwords-file "$PWDFILE" --roles engineer
  [ "$status" -eq 2 ]
  [[ "$output" == *"FAIL  engineer"* ]]
  [ ! -f "$TOKDIR/engineer.gitea_token" ]
}

@test "passwords-file: BOTH JSON shapes accepted (bare string and {password:...})" {
  printf '{"sha1":"tok-frais"}' > "$MOCK/post_response"
  printf '200' > "$MOCK/probe_code"
  run "$SCRIPT" --forge http://f --owner "$(id -un)" --tokens-dir "$TOKDIR" --passwords-file "$PWDFILE" --roles "engineer qualifier"
  [ "$status" -eq 0 ]
  [ -f "$TOKDIR/engineer.gitea_token" ]
  [ -f "$TOKDIR/qualifier.gitea_token" ]
}

@test "passwords-file: a CAPITALIZED key matches the lowercase role (Gitea is case-insensitive)" {
  # A human writes the accounts as they see them on the forge (`Architect`); the internal role is
  # `architect`. The lookup must match — otherwise it FAILs while the password EXISTS.
  printf '{"Architect":"pw-arch"}' > "$TMP/caps.json"
  printf '{"sha1":"tok-frais"}' > "$MOCK/post_response"
  printf '200' > "$MOCK/probe_code"
  run "$SCRIPT" --forge http://f --owner "$(id -un)" --tokens-dir "$TOKDIR" --passwords-file "$TMP/caps.json" --roles architect
  [ "$status" -eq 0 ]
  [ "$(cat "$TOKDIR/architect.gitea_token")" = "tok-frais" ]
}

@test "--extra-token ACCOUNT:FILE: mints the system account, writes the file (account is not file)" {
  printf '{"system_starfleet":"pw-sys"}' > "$TMP/syspw.json"
  printf '{"sha1":"tok-sys"}' > "$MOCK/post_response"
  printf '200' > "$MOCK/probe_code"
  run "$SCRIPT" --forge http://f --owner "$(id -un)" --tokens-dir "$TOKDIR" --passwords-file "$TMP/syspw.json" \
      --roles "" --extra-token system_starfleet:system.gitea_token
  [ "$status" -eq 0 ]
  [[ "$output" == *"POSE  system_starfleet"* ]]
  [ "$(cat "$TOKDIR/system.gitea_token")" = "tok-sys" ]
  [ ! -f "$TOKDIR/system_starfleet.gitea_token" ]
}

@test "--extra-token without ':' → exit 1 fail-loud (account:file format required)" {
  run "$SCRIPT" --forge http://f --owner "$(id -un)" --tokens-dir "$TOKDIR" --passwords-file "$PWDFILE" --extra-token bidon
  [ "$status" -eq 1 ]
  [[ "$output" == *"compte>:<fichier"* ]]
}

@test "A4 complete: 1 role + the system account in ONE gesture (the canonical call)" {
  printf '{"engineer":"pw-eng","system_starfleet":"pw-sys"}' > "$TMP/full.json"
  printf '{"sha1":"tok-x"}' > "$MOCK/post_response"
  printf '200' > "$MOCK/probe_code"
  run "$SCRIPT" --forge http://f --owner "$(id -un)" --tokens-dir "$TOKDIR" --passwords-file "$TMP/full.json" \
      --roles engineer --extra-token system_starfleet:system.gitea_token
  [ "$status" -eq 0 ]
  [ -f "$TOKDIR/engineer.gitea_token" ]
  [ -f "$TOKDIR/system.gitea_token" ]
}

# ═══ 6-141 — LES SECRETS HORS D'ARGV ═════════════════════════════════════════════════════════════
#
# Rapatries depuis `deploy/tests/role_tokens.bats` le 2026-08-19, qui n'existe plus : ce script
# avait DEUX maisons de temoins, et j'ai ecrit dans l'une sans voir l'autre — c'est la seconde qui a
# rattrape une collision de nom d'option. Deux maisons pour un contrat, c'est la forme qui derive,
# et la convention du depot est un dossier par script shell (`test/bwrap_launch`, `test/claude_*`).
#
# CE QUI EST MESURE ICI est le canal, pas la politesse : `-u "$role:$pwd"` et `-H "Authorization:
# token $tok"` mettent le secret dans la LIGNE DE COMMANDE, que `/proc/<pid>/cmdline` expose a tout
# l'hote pendant la requete. Un observateur local recolte les mots de passe de tous les roles et les
# tokens fraichement mintes — et un mot de passe re-minte des tokens pour toujours, donc faire
# tourner le token capture ne repare rien.
#
# ⚠ CHAQUE ASSERTION D'ATTAQUE VA PAR PAIRE AVEC UN TEMOIN (P-40) : « le secret n'est pas dans
# argv » serait satisfait par un correctif qui supprimerait l'auth. Le temoin — « il EST dans
# stdin » — est ce qui distingue un secret deplace d'un secret perdu.

mint_ok() {   # etat nominal du shim pour un mint qui aboutit
  printf '200' > "$MOCK/probe_code"
  printf '{"sha1":"TOKEN-MINTE"}' > "$MOCK/post_response"
}

@test "6-141: le mot de passe n'apparait JAMAIS dans argv, et il EST dans stdin" {
  mint_ok
  run "$SCRIPT" --forge http://f --owner "$(id -un)" --tokens-dir "$TOKDIR" \
    --passwords-file "$PWDFILE" --roles engineer
  [ "$status" -eq 0 ]
  refute grep -q 'pw-eng' "$MOCK/calls.log"
  grep -q 'pw-eng' "$MOCK/stdin.log"
}

@test "6-141: le token minte ne repart pas en argv sur la sonde de validite" {
  mint_ok
  run "$SCRIPT" --forge http://f --owner "$(id -un)" --tokens-dir "$TOKDIR" \
    --passwords-file "$PWDFILE" --roles engineer
  [ "$status" -eq 0 ]
  refute grep -q 'TOKEN-MINTE' "$MOCK/calls.log"
  grep -q 'TOKEN-MINTE' "$MOCK/stdin.log"
  # Et la chaine fonctionne encore : le fichier est ecrit avec ce que la forge a rendu.
  grep -q 'TOKEN-MINTE' "$TOKDIR/engineer.gitea_token"
}

@test "6-141: un mot de passe portant guillemets et backslashs traverse INTACT" {
  # Le fichier de config de curl a sa propre syntaxe : un echappement rate coupe le mot de passe en
  # silence, et le mint part en 401 sans que rien ne dise pourquoi.
  mint_ok
  printf '{"engineer":"a\\"b\\\\c d"}' > "$PWDFILE"
  run "$SCRIPT" --forge http://f --owner "$(id -un)" --tokens-dir "$TOKDIR" \
    --passwords-file "$PWDFILE" --roles engineer
  [ "$status" -eq 0 ]
  grep -q 'a\\"b' "$MOCK/stdin.log"
}

# ═══ LA VOIE « FORCER PUIS OUBLIER » (2026-08-19) ════════════════════════════════════════════════
#
# Le mint dependait du password que tofu pose — or le provider ne le pose reellement qu'a la
# CREATION du compte (`deps/instance/accounts.tf`). Des que le fichier et la forge divergent — seed
# regenere, compte cree a une passe anterieure, roster elargi — le mint part en 401 sur des comptes
# SAINS, definitivement. Mesure sur instance vierge : dix comptes en 401, le fichier contenant
# exactement le seed. Avec le jeton master, le minteur pose un password neuf juste avant de s'en
# servir, puis l'oublie : il n'a plus a croire ce qu'un autre outil a bien voulu ecrire.

@test "voie FORCE : le password utilise n'est PAS celui du fichier — il vient d'etre pose" {
  mint_ok
  run "$SCRIPT" --forge http://f --owner "$(id -un)" --tokens-dir "$TOKDIR" \
    --passwords-file "$PWDFILE" --master-token-file <(printf 'JETON-MASTER\n') --roles engineer
  [ "$status" -eq 0 ]
  grep -q 'request = "PATCH"' "$MOCK/stdin.log"
  grep -q 'admin/users/engineer' "$MOCK/calls.log"
  refute grep -q 'pw-eng' "$MOCK/stdin.log"
}

@test "6-141 sur la voie FORCE : ni le jeton master ni le password force ne passent par argv" {
  mint_ok
  run "$SCRIPT" --forge http://f --owner "$(id -un)" --tokens-dir "$TOKDIR" \
    --passwords-file "$PWDFILE" --master-token-file <(printf 'JETON-MASTER\n') --roles engineer
  [ "$status" -eq 0 ]
  refute grep -q 'JETON-MASTER' "$MOCK/calls.log"
  grep -q 'JETON-MASTER' "$MOCK/stdin.log"
  refute grep -qE '"password":' "$MOCK/calls.log"
  grep -q 'password' "$MOCK/stdin.log"
}

@test "PATCH en echec : on RETOMBE sur le fichier, on ne conclut pas a l'echec du mint" {
  # Un jeton master perime ne rend pas faux le password pose a la creation. Refuser tout net
  # transformerait une degradation en panne.
  mint_ok
  run "$SCRIPT" --forge http://f --owner "$(id -un)" --tokens-dir "$TOKDIR" \
    --passwords-file "$PWDFILE" --master-token-file /inexistant/master.token --roles engineer
  [ "$status" -eq 0 ]
  grep -q 'pw-eng' "$MOCK/stdin.log"
}
