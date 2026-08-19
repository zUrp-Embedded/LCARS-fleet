#!/usr/bin/env bats
# SOURCE: fleet/deploy/tests/role_tokens.bats
# AUTHOR: drdree
# STARDATE: 2026-08-14
# STATUS: bats tests for etc/provision-role-tokens.sh — 6-141, les secrets hors d'argv
#
# CE SCRIPT N'AVAIT AUCUN TEST, et il manipule tous les mots de passe de role de l'instance.
#
# Ce qui est mesure ici est le canal, pas la politesse : `-u "$role:$pwd"` et
# `-H "Authorization: token $tok"` mettent le secret dans la LIGNE DE COMMANDE du processus, que
# /proc/<pid>/cmdline expose a tout le monde pendant la requete. Un observateur local recolte les
# mots de passe de tous les roles, les tokens existants et ceux fraichement mintes — et un mot de
# passe re-minte des tokens pour toujours, donc faire tourner le token capture ne repare rien.
#
# Le dispositif : un FAUX `curl` en tete de PATH qui journalise `"$@"` ET son stdin, puis rend une
# reponse canonique. On lit ensuite les deux journaux.
#
# ⚠ CHAQUE ASSERTION D'ATTAQUE VA PAR PAIRE AVEC UN TEMOIN (P-40) : « le secret n'est pas dans
# argv » est satisfait par un correctif qui supprimerait l'auth. Le temoin — « il EST dans stdin » —
# est ce qui distingue un secret deplace d'un secret perdu.

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../../etc/provision-role-tokens.sh"
  [ -f "$SCRIPT" ]

  BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$BIN"
  ARGV_LOG="$BATS_TEST_TMPDIR/argv.log"
  STDIN_LOG="$BATS_TEST_TMPDIR/stdin.log"
  : > "$ARGV_LOG"
  : > "$STDIN_LOG"

  # Faux curl. Il decide sur CE QU'IL RECOIT, jamais sur l'ordre des appels : le nombre de sondes
  # depend de la presence d'un token local, donc un compteur repondrait juste dans un scenario et
  # faux dans l'autre.
  #
  #   * `-w '%{http_code}'` = sonde de validite. Seul le token FRAICHEMENT MINTE est valide (200) ;
  #     tout autre est 401, ce qui declenche le re-mint que ces tests veulent observer. Le fait que
  #     la decision se prenne sur le STDIN prouve au passage que le secret y voyage vraiment.
  #   * le POST = le mint, qui rend le JSON de la forge.
  #   * le DELETE = sans interet, sa sortie va a /dev/null.
  cat > "$BIN/curl" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$ARGV_LOG"
cfg=""
# stdin n'est lu que sur les appels `-K -` ; ailleurs il n'y a rien a lire.
if [[ " $* " == *" -K "* ]]; then cfg="$(cat)"; printf '%s\n' "$cfg" >> "$STDIN_LOG"; fi
if [[ " $* " == *"%{http_code}"* ]]; then
  # Le PATCH de la voie « forcer puis oublier » : il repond 200, comme la vraie forge le fait avec
  # un jeton master valide (mesure du 2026-08-19 sur instance vierge).
  if [[ "$cfg" == *'request = "PATCH"'* ]]; then printf '200'
  elif [[ "$cfg" == *TOKEN-MINTE* ]]; then printf '200'; else printf '401'; fi
else
  printf '{"sha1":"TOKEN-MINTE"}'
fi
FAKE
  chmod +x "$BIN/curl"
  export ARGV_LOG STDIN_LOG
  export PATH="$BIN:$PATH"

  TOKENS_DIR="$BATS_TEST_TMPDIR/tokens"
  mkdir -p "$TOKENS_DIR"
  PASSWORDS="$BATS_TEST_TMPDIR/roles.json"
  printf '{"architect":"MOT-DE-PASSE-SECRET"}\n' > "$PASSWORDS"
}

run_provision() {
  run "$SCRIPT" --forge http://forge.test --passwords-file "$PASSWORDS" \
    --tokens-dir "$TOKENS_DIR" --roles "architect" "$@"
}

@test "6-141: le mot de passe n'apparait JAMAIS dans argv" {
  run_provision
  run grep -c "MOT-DE-PASSE-SECRET" "$ARGV_LOG"
  [ "$output" = "0" ]
}

@test "6-141: TEMOIN — il est bien passe, par stdin (sinon on aurait supprime l'auth)" {
  run_provision
  grep -q "MOT-DE-PASSE-SECRET" "$STDIN_LOG"
  # Et sous la forme que curl attend : `user = "compte:secret"`.
  grep -q 'user = "architect:MOT-DE-PASSE-SECRET"' "$STDIN_LOG"
}

@test "6-141: un token EXISTANT n'apparait pas non plus dans argv (la sonde le lisait aussi)" {
  printf 'TOKEN-EXISTANT\n' > "$TOKENS_DIR/architect.gitea_token"
  run_provision
  run grep -c "TOKEN-EXISTANT" "$ARGV_LOG"
  [ "$output" = "0" ]
}

@test "6-141: TEMOIN — la sonde a bien envoye ce token, par stdin" {
  printf 'TOKEN-EXISTANT\n' > "$TOKENS_DIR/architect.gitea_token"
  run_provision
  grep -q 'header = "Authorization: token TOKEN-EXISTANT"' "$STDIN_LOG"
}

@test "6-141: le token FRAICHEMENT MINTE est ecrit, donc la chaine fonctionne encore" {
  # Sans ceci, un correctif qui casserait le mint passerait les quatre tests ci-dessus : plus
  # aucun secret nulle part, et plus aucun token non plus.
  run_provision
  [ "$(tr -d '[:space:]' < "$TOKENS_DIR/architect.gitea_token")" = "TOKEN-MINTE" ]
}

@test "6-141: un mot de passe qui porte des guillemets et des backslashs traverse INTACT" {
  # La config de curl est un format cite : une valeur non echappee couperait le secret en deux, et
  # l'auth partirait tronquee — un echec silencieux qui ressemble a un mauvais mot de passe.
  printf '{"architect":"a\\"b\\\\c"}\n' > "$PASSWORDS"
  run_provision
  grep -q 'user = "architect:a\\"b\\\\c"' "$STDIN_LOG"
  run grep -c 'a"b' "$ARGV_LOG"
  [ "$output" = "0" ]
}


# ─── LA VOIE « FORCER PUIS OUBLIER » (2026-08-19) ────────────────────────────────────────────────
# Le mint dependait du password que tofu avait pose A LA CREATION du compte. Des que le fichier de
# passwords et la forge divergent — seed regenere, compte cree a une passe anterieure, roster elargi
# — le mint part en 401 sur des comptes sains, DEFINITIVEMENT. Mesure sur instance vierge : dix
# comptes en 401, le fichier contenant exactement le seed. Avec le jeton master, le minteur pose un
# password neuf juste avant de s'en servir, puis l'oublie : il n'a plus a croire ce qu'un autre
# outil a bien voulu ecrire.

@test "voie FORCE : le password utilise n'est PAS celui du fichier — il vient d'etre pose" {
  run "$SCRIPT" --forge http://forge.test --passwords-file "$PASSWORDS" \
    --master-token-file <(printf 'JETON-MASTER\n') \
    --tokens-dir "$TOKENS_DIR" --roles "architect"
  [ "$status" -eq 0 ]
  # Le PATCH a eu lieu, sur le bon compte.
  grep -q 'request = "PATCH"' "$STDIN_LOG"
  grep -q 'admin/users/architect' "$ARGV_LOG"
  # Et la basic-auth du mint n'utilise PAS le mot de passe du fichier : c'est tout l'objet.
  ! grep -q 'MOT-DE-PASSE-SECRET' "$STDIN_LOG"
}

@test "6-141 sur la voie FORCE : ni le jeton master ni le password force ne passent par argv" {
  # Le temoin d'attaque va par paire avec sa preuve : un correctif qui supprimerait l'auth
  # satisferait « pas dans argv » sans rien minter. On verifie donc que le secret EST dans stdin.
  run "$SCRIPT" --forge http://forge.test --passwords-file "$PASSWORDS" \
    --master-token-file <(printf 'JETON-MASTER\n') \
    --tokens-dir "$TOKENS_DIR" --roles "architect"
  [ "$status" -eq 0 ]
  ! grep -q 'JETON-MASTER' "$ARGV_LOG"
  grep -q 'JETON-MASTER' "$STDIN_LOG"
  # Le password force voyage dans le meme canal — jamais en `-d` sur la ligne de commande.
  ! grep -qE '"password":' "$ARGV_LOG"
  grep -q 'password' "$STDIN_LOG"
}

@test "PATCH en echec : on RETOMBE sur le fichier, on ne conclut pas a l'echec du mint" {
  # Un jeton master perime ne rend pas faux le password pose a la creation. Refuser tout net
  # transformerait une degradation en panne.
  run "$SCRIPT" --forge http://forge.test --passwords-file "$PASSWORDS" \
    --master-token-file /inexistant/master.token \
    --tokens-dir "$TOKENS_DIR" --roles "architect"
  [ "$status" -eq 0 ]
  grep -q 'MOT-DE-PASSE-SECRET' "$STDIN_LOG"
}
