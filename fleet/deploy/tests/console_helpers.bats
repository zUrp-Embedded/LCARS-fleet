#!/usr/bin/env bats
# SOURCE: fleet/deploy/tests/console_helpers.bats
# AUTHOR: DrDree
# STARDATE: (posee par /push-github)
# STATUS: bats tests for services/console-status.sh and services/console-pod.sh
#
# ⚠ UN FICHIER QUI CHANGE D'ADRESSE SANS TEMOIN NE PEUT PAS PROUVER QU'IL EST ARRIVE ENTIER.
# C'est pourquoi ceux-ci s'ecrivent AVANT un demenagement, jamais apres : ce qui n'est pas
# mesure avant ne peut pas etre compare apres. Les deux sujets sont poses en `/opt/lcars` sur
# les deux rails, et l'un touche les sockets de console.
#
# CE QUI EST MESURE : la DECISION de chaque script — ce qu'il refuse, ce qu'il compte, ce qu'il rend.
# `tmux` et `lcars` sont des doublures en tete de PATH ; aucune session, aucun pod reel.

# ⚠ SC2016 : CE TEMOIN LIT DU CODE. Ses motifs `grep`/`sed` portent des `${VAR:-defaut}` qui
# doivent atteindre l'outil TELS QUELS — les developper chercherait la valeur dans CE shell au lieu
# du texte audite. Les quotes simples sont l'instrument, pas un oubli.
# ⚠ SC2030/SC2031 : CHAQUE `@test` DE BATS EST UN SOUS-SHELL, et c'est la propriete qu'on veut —
# un test ne teinte pas le suivant. Que les variables posees dans un test soient « locales » est
# l'isolation, pas une fuite.
# shellcheck disable=SC2016,SC2030,SC2031

setup() {
  local _v
  while read -r _v; do unset "$_v" 2>/dev/null || true; done \
    < <(compgen -v | grep -E '^(LCARS_|PROV_)' || true)

  DIR="$BATS_TEST_DIRNAME/../../services"
  STATUS="$DIR/console-status.sh"
  POD="$DIR/console-pod.sh"
  [ -f "$STATUS" ] && [ -f "$POD" ]

  BIN="$BATS_TEST_TMPDIR/bin"; mkdir -p "$BIN"
  export PATH="$BIN:$PATH"
  export HOME="$BATS_TEST_TMPDIR/home"
  export LCARS_TMUX_SOCK_BASE="$BATS_TEST_TMPDIR/socks"
  export LCARS_FLEET_V2_SOCK="$BATS_TEST_TMPDIR/fleet.sock"
  mkdir -p "$HOME" "$LCARS_TMUX_SOCK_BASE"
  export TRACE="$BATS_TEST_TMPDIR/trace"; : > "$TRACE"
}

# `tmux` double : `has-session` repond OUI pour les sessions posees dans $ALIVE, NON sinon.
stub_tmux() { # stub_tmux <session ...>
  printf '%s\n' "$@" > "$BATS_TEST_TMPDIR/alive"
  cat > "$BIN/tmux" <<'SH'
#!/usr/bin/env bash
printf 'tmux %s\n' "$*" >> "$TRACE"
prev=""; target=""
for a in "$@"; do [[ "$prev" == "-t" ]] && target="$a"; prev="$a"; done
case "$1$2$3$4" in *has-session*) grep -qxF "$target" "$BATS_TEST_TMPDIR/alive" && exit 0 || exit 1 ;; esac
exit 0
SH
  chmod +x "$BIN/tmux"
  export LCARS_TMUX_BIN="$BIN/tmux"
}

pod_socket() { # pod_socket <pod_id> — une VRAIE socket unix, pas un fichier
  local d="$LCARS_TMUX_SOCK_BASE/$1"; mkdir -p "$d"
  python3 - "$d/pod.sock" <<'PY'
import socket, sys
s = socket.socket(socket.AF_UNIX); s.bind(sys.argv[1])
PY
}

# ─── console-status.sh — UNE LIGNE, ET ELLE NE MENT PAS ─────────────────────────────────────────

@test "status: fleet morte -> il le DIT, et sort 0" {
  # ⚠ SORTIR NON NUL TUERAIT LA BARRE DE STATUT : tmux n'affiche rien d'un hook en echec, et
  # l'operateur lirait « pas de barre » comme « pas de probleme ». Une sonde rend un ETAT, jamais
  # un verdict d'execution.
  stub_tmux
  run bash "$STATUS"
  [ "$status" -eq 0 ]
  [[ "$output" == "fleet morte" ]]
}

@test "status: fleet vivante sans pod -> le dit sans compter faux" {
  stub_tmux fleet_v2
  run bash "$STATUS"
  [ "$status" -eq 0 ]
  [[ "$output" == "fleet vivante · aucun pod" ]]
}

@test "status: un pod VIVANT est compte, un socket ORPHELIN ne l'est pas" {
  # ⚠ C'EST LA PROPRIETE QUI PORTE. Une socket sur le disque ne prouve pas qu'un pod tourne — un
  # pod mort laisse la sienne. Compter les FICHIERS afficherait des pods qui n'existent plus, et
  # l'operateur lirait « 3 pods » sur une fleet vide.
  stub_tmux fleet_v2 lcars-pod-alpha
  pod_socket alpha
  pod_socket zombie
  run bash "$STATUS"
  [ "$status" -eq 0 ]
  [[ "$output" == "fleet vivante · 1 pod" ]]
}

@test "status: le pluriel suit le compte" {
  stub_tmux fleet_v2 lcars-pod-alpha lcars-pod-beta
  pod_socket alpha; pod_socket beta
  run bash "$STATUS"
  [[ "$output" == "fleet vivante · 2 pods" ]]
}

@test "status: un repertoire de sockets ABSENT n'est pas une erreur" {
  # Une fleet qui vient de demarrer n'a pas encore de pods : l'absence du repertoire est l'etat
  # nominal du premier instant, pas une panne.
  stub_tmux fleet_v2
  export LCARS_TMUX_SOCK_BASE="$BATS_TEST_TMPDIR/jamais-cree"
  run bash "$STATUS"
  [ "$status" -eq 0 ]
  [[ "$output" == "fleet vivante · aucun pod" ]]
}

# ─── console-pod.sh — UN REFUS TIENT L'ECRAN ────────────────────────────────────────────────────

# ⚠ CE SCRIPT NE SORT JAMAIS SUR UN REFUS : il imprime puis `exec sleep infinity`. Sortir fermerait
# la WebSocket avec un code que le navigateur rejette, xterm.js se reconnecterait, et le meme refus
# repartirait en boucle. Les temoins BORNENT donc leur execution — sans `timeout`, ils pendraient.
pod_run() { run env timeout 5 bash "$POD" "$@"; }

@test "pod: sans argument -> refus, et l'ecran est TENU" {
  pod_run
  [ "$status" -eq 124 ]        # 124 = timeout : le refus n'est pas sorti, il attend l'humain
  [[ "$output" == *"un seul argument"* ]]
  [[ "$output" == *"fermer cet onglet"* ]]
}

@test "pod: un pod_id qui n'est pas un slug est REFUSE avant toute socket" {
  # `../` ou `/` fabriquerait un chemin hors de la racine des sockets.
  pod_run "../evade"
  [ "$status" -eq 124 ]
  [[ "$output" == *"pod_id invalide"* ]]
}

@test "pod: un pod_id valide SANS socket -> refus qui nomme la cause" {
  pod_run "fantome"
  [ "$status" -eq 124 ]
  [[ "$output" == *"pas de socket"* ]]
  [[ "$output" == *"fantome"* ]]
}

@test "pod: un FICHIER ordinaire n'est pas une socket" {
  # ⚠ CONTRE-TEMOIN. La garde teste `-S`, pas `-e` : un fichier laisse la par un `touch` ou un
  # `docker cp` passerait un `-e` et ferait attacher sur du vide.
  mkdir -p "$LCARS_TMUX_SOCK_BASE/faux"
  : > "$LCARS_TMUX_SOCK_BASE/faux/pod.sock"
  pod_run "faux"
  [ "$status" -eq 124 ]
  [[ "$output" == *"pas de socket"* ]]
}

@test "pod: socket presente -> il DELEGUE a « lcars attach », il n'attache pas lui-meme" {
  printf '#!/usr/bin/env bash\nprintf "lcars %%s\\n" "$*" >> "$TRACE"\nexit 0\n' > "$BIN/lcars"
  chmod +x "$BIN/lcars"
  pod_socket vrai
  pod_run "vrai"
  [ "$status" -eq 0 ]
  grep -qx "lcars attach vrai" "$TRACE"
}
