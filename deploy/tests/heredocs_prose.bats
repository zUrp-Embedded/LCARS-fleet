#!/usr/bin/env bats
# bats file_tags=structure
# SOURCE: deploy/tests/heredocs_prose.bats
# AUTHOR: alice
# STARDATE: 2026-08-28
# STATUS: mur — aucun accent grave dans le corps d'un heredoc NON quote
#
# La prose du dépôt cite avec des accents graves ; dans un heredoc non quoté (`<<EOF`), bash les
# exécute comme des substitutions de commande. Shellcheck les signale sous SC2006, le même code
# que le backtick de style : un SC2006 désactivé rouvrirait le défaut sans le dire. Un seul heredoc
# par ligne est suivi.

load refute

setup() {
  R="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"          # la RACINE du depot — `deploy/` et `runtime/` y sont FRERES
  SCAN="$BATS_TEST_TMPDIR/scan.awk"
  cat > "$SCAN" <<'AWK'
# Sortie : "<fichier>:<ligne>: <texte>" pour tout accent grave dans un heredoc NON quote.
# Sortie : "HD <n>" en fin, le nombre de heredocs NON quotes vus (garde d'instrument).
FNR == 1 { in_hd = 0; delim = ""; strip = 0 }
in_hd {
  l = $0
  if (strip) sub(/^\t+/, "", l)
  if (l == delim) { in_hd = 0; delim = ""; next }
  # un backtick échappé traverse le heredoc en littéral : c'est la forme correcte, retirée avant de regarder
  probe = $0
  gsub(/\\`/, "", probe)
  if (index(probe, "`") > 0) printf "%s:%d: %s\n", FILENAME, FNR, $0
  next
}
{
  # une ligne de commentaire n'ouvre pas de heredoc : l'en-tête de ce fichier cite `<<EOF`
  if ($0 ~ /^[ \t]*#/) next
  line = $0
  gsub(/<<</, "", line)                                 # `<<<` n ouvre rien
  if (match(line, /<<-?[ \t]*[\047"]?[A-Za-z_][A-Za-z0-9_]*[\047"]?/)) {
    tok = substr(line, RSTART, RLENGTH)
    strip = (index(tok, "<<-") == 1)
    quoted = (index(tok, "\047") > 0 || index(tok, "\"") > 0)
    gsub(/^<<-?[ \t]*[\047"]?/, "", tok)
    gsub(/[\047"]$/, "", tok)
    if (!quoted) { in_hd = 1; delim = tok; nu++ }
  }
}
END { printf "HD %d\n", nu + 0 }
AWK
  mapfile -t FILES < <(
    find "$R/deploy" "$R/runtime/services" -type f \( -name '*.sh' -o -name '*.bats' \
         -o -name 'provision' -o -name 'container' -o -name 'accept' \) 2>/dev/null | sort
    echo "$R/install.sh"
  )
  [ "${#FILES[@]}" -ge 40 ]
}

@test "GARDE D'INSTRUMENT : le scanner VOIT des heredocs non quotes" {
  # Sans ce garde, un motif casse (delimiteur renomme, forme `<<-` non geree) rendrait le mur
  # ci-dessous vert en n'ayant RIEN parcouru. C'est la forme d'echec la plus chere : elle certifie.
  local n
  n="$(awk -f "$SCAN" "${FILES[@]}" | sed -n 's/^HD //p')"
  [ "$n" -ge 10 ] || { echo "le scanner ne trouve que $n heredoc(s) non quote(s) — il est casse" >&2; return 1; }
}

@test "AUCUN accent grave dans un heredoc NON quote — bash y EXECUTE la prose" {
  local hits
  hits="$(awk -f "$SCAN" "${FILES[@]}" | grep -v '^HD ' || true)"
  [ -z "$hits" ] || {
    echo "PROSE EXECUTEE — ces accents graves sont dans un heredoc non quote :" >&2
    printf '%s\n' "$hits" >&2
    echo "  soit le heredoc devient \`<<'EOF'\` (le corps n'a rien a expanser)," >&2
    echo "  soit la prose perd ses accents graves (guillemets francais)." >&2
    return 1
  }
}
