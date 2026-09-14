# SOURCE: deploy/tests/support/minisign_double.bash
# AUTHOR: bob
# STARDATE: 2026-09-14
# STATUS: helper bats — un minisign doublé qui signe et vérifie sous la forme qu'emploient pack, door-gen et l'installeur
#
#   load ../support/minisign_double
#   minisign_double <dossier>              pose <dossier>/minisign (le dossier se met en tête du PATH par le cas)
#   minisign_cle <fichier> <clé publique>  une clé secrète doublée : elle signe pour cette clé publique
#
# -S -s <clé secrète> -m <f> écrit <f>.minisig ; -V[q] -P <clé publique> -m <f> rend 0 si <f>.minisig
# vient de la clé secrète de cette clé publique et si <f> n'a pas changé depuis la signature.

minisign_double() {
  mkdir -p "$1"
  cat > "$1/minisign" <<'EOF'
#!/usr/bin/env bash
mode="" sec="" pub="" m=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -S) mode=signe; shift ;;
    -V|-Vq) mode=verifie; shift ;;
    -q) shift ;;
    -s) sec="$2"; shift 2 ;;
    -P) pub="$2"; shift 2 ;;
    -m) m="$2"; shift 2 ;;
    *) echo "minisign doublé : option non jouée « $1 »" >&2; exit 2 ;;
  esac
done
empreinte="$(sha256sum "$m" | cut -d' ' -f1)" || exit 1
case "$mode" in
  signe)   printf 'untrusted comment: signature doublée\n%s %s\n' "$(cat "$sec")" "$empreinte" > "$m.minisig" ;;
  verifie) [[ "$(sed -n 2p "$m.minisig" 2>/dev/null)" == "$pub $empreinte" ]] ;;
  *) echo "minisign doublé : ni -S ni -V" >&2; exit 2 ;;
esac
EOF
  chmod 0755 "$1/minisign"
}

minisign_cle() { printf '%s\n' "$2" > "$1"; }
