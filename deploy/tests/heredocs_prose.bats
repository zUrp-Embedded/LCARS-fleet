#!/usr/bin/env bats
# SOURCE: deploy/tests/heredocs_prose.bats
# AUTHOR: alice
# STARDATE: (posee par /push-github)
# STATUS: mur — aucun accent grave dans le corps d'un heredoc NON quote
#
# ⚠ LE DEFAUT QUE CE MUR FERME S'EST PRODUIT DOUZE FOIS DANS CE DEPOT. Ce depot ecrit sa prose avec
# des accents graves — c'est sa convention de citation. Dans un heredoc NON quote (`<<EOF` et non
# `<<'EOF'`), bash y fait de la SUBSTITUTION DE COMMANDE : la prose est executee.
#
# CE QUE CA COUTE, MESURE SUR LE DOUZIEME (`forge-runner.sh`, generation du `config.yaml` du
# runner) : `getent hosts forge`, `wget http://forge:3000/api/v1/version` et `git ls-remote …`
# etaient lances a chaque generation. Sur cette machine, ou la forge ne resout pas, ils ecrivent
# sur stderr et la prose sort AMPUTEE — « n'a que , , . ». Sur l'hote du runner, ou elle resout,
# `git ls-remote` rend deux lignes a tabulations qui atterrissent HORS du `#` : le fichier produit
# n'est plus du YAML valide, et le runner refuse sa config. `wget` telecharge un fichier au passage.
#
# ⚠ ET SHELLCHECK NE SUFFIT PAS, C'EST LE MOTIF DE CE FICHIER. Il voit ces backticks (SC2006) mais
# sous le meme code que le backtick de STYLE dans du vrai code — « prefere $(…) ». Le jour ou
# quelqu'un desactive SC2006 comme du bruit cosmetique, il rouvre celui-la sans le savoir. Onze
# occurrences ont ete corrigees en debut de lot SANS qu'un mur soit pose : la douzieme est passee.
#
# ⚠ LIMITE ASSUMEE : un seul heredoc par ligne est suivi. Deux sur la meme ligne
# (`cmd <<A <<B`) est une forme que ce depot n'emploie pas ; si elle apparait, c'est ici qu'il faut
# descendre — sinon le second heredoc devient un angle mort.

load refute

setup() {
  R="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"          # la RACINE du depot — `deploy/` et `fleet/` y sont FRERES depuis la separation
  SCAN="$BATS_TEST_TMPDIR/scan.awk"
  cat > "$SCAN" <<'AWK'
# Sortie : "<fichier>:<ligne>: <texte>" pour tout accent grave dans un heredoc NON quote.
# Sortie : "HD <n>" en fin, le nombre de heredocs NON quotes vus (garde d'instrument).
FNR == 1 { in_hd = 0; delim = ""; strip = 0 }
in_hd {
  l = $0
  if (strip) sub(/^\t+/, "", l)
  if (l == delim) { in_hd = 0; delim = ""; next }
  # ⚠ UN BACKTICK ECHAPPE N'EST PAS EXECUTE. `\\`` traverse le heredoc non quote en litteral :
  # c'est le geste correct quand la prose doit garder ses accents graves. On les retire AVANT de
  # regarder. Sans ca le mur accuse la solution en meme temps que le defaut.
  probe = $0
  gsub(/\\`/, "", probe)
  if (index(probe, "`") > 0) printf "%s:%d: %s\n", FILENAME, FNR, $0
  next
}
{
  # ⚠ UNE LIGNE DE COMMENTAIRE N'OUVRE PAS DE HEREDOC, et l'oublier rend le scanner FOU. Ce
  # fichier-ci PARLE de `<<EOF` dans son propre en-tete : le premier jet est entre en heredoc a la
  # ligne 8 et n'en est jamais ressorti, signalant tout le reste du corpus. Un instrument qui
  # sur-signale se fait desactiver aussi surement qu'un instrument aveugle.
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
    find "$R/deploy" "$R/fleet/services" -type f \( -name '*.sh' -o -name '*.bats' \
         -o -name 'provision' -o -name 'box' -o -name 'accept' \) 2>/dev/null | sort
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
