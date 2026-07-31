#!/usr/bin/env bash
# SOURCE: fleet/provisioning_v2/docker/console-landing.sh
# AUTHOR: consultant
# STARDATE: 2026-07-31
# STATUS: la home de la boite — sidebar de navigation + page de statut. Etape 1, sans auth.
#
# ─── POURQUOI PAS `ttyd -I` ─────────────────────────────────────────────────────────────────────
# La prospection proposait de servir cette page via le flag `-I/--index` de ttyd. C'est FAUX et je
# le corrige ici : `-I` REMPLACE l'index.html de ttyd — or cet index EST le client xterm.js. Poser
# notre page dessus ne l'ajouterait pas a la console, ca la DETRUIRAIT. La home vit donc dans son
# propre serveur, sur son propre port, et la console n'est pas touchee.
#
# ─── PORT : HORS DE L'ESPACE DES BLOCS ──────────────────────────────────────────────────────────
# Les blocs humains occupent 21000..25999 (`21000 + (uid%500)*10`, +0..9). Cette page n'appartient
# a AUCUN humain — c'est la porte de la BOITE. Elle prend donc 20999, juste sous l'espace des
# blocs : impossible de collisionner avec un humain present ou futur.
#
# ─── CE QUE LA PAGE AFFICHE, ET CE QU'ELLE REFUSE D'AFFICHER ────────────────────────────────────
# Elle est generee UNE FOIS au boot, donc elle ne peut porter que des faits STABLES pour la vie du
# conteneur : hostname, humains, ports, build, revision de la source. L'etat de la fleet (vivante /
# morte, nombre de pods) est volontairement ABSENT : une page statique qui l'afficherait mentirait
# des le premier `fleet_v2 start`. Ce statut-la vit dans la barre tmux de la console, qui sonde.
# La page dit ou le regarder plutot que d'en fabriquer une copie perimee.
#
# USAGE : console-landing.sh [--foreground]
# EXIT  : 0 lance · 1 dependance absente

set -euo pipefail

FOREGROUND=0
[[ "${1:-}" == "--foreground" ]] && FOREGROUND=1

PORT="${LCARS_LANDING_PORT:-20999}"
DIR="${LCARS_LANDING_DIR:-/opt/lcars/landing}"
HUMANS_SH="${LCARS_CONSOLE_HUMANS:-/opt/lcars/console-humans.sh}"

say() { echo "[lcars-landing] $*"; }

command -v python3 >/dev/null || { echo "console-landing.sh: python3 absent de l'image" >&2; exit 1; }
[[ -x "$HUMANS_SH" ]] || { echo "console-landing.sh: $HUMANS_SH introuvable" >&2; exit 1; }

# ─── Collecte : uniquement ce qui resout reellement, jamais de valeur inventee ───────────────────
BOX_HOST="$(hostname)"
GEN_AT="$(date -Is)"

BUILD="inconnu"
build_file="$(ls -1 /local/LCARS_v2/lib/lcars_fleet-*/priv/api/build_info.txt 2>/dev/null | head -1 || true)"
if [[ -n "$build_file" && -r "$build_file" ]]; then
  BUILD="$(tr '\n' ' ' < "$build_file" | sed 's/  */ /g; s/ *$//')"
fi

SOURCE_REV="absente"
if [[ -d /home/projects/LCARS/.git ]]; then
  SOURCE_REV="$(git -C /home/projects/LCARS rev-parse --short HEAD 2>/dev/null || echo '?')"
fi

TTYD_VER="$(ttyd --version 2>/dev/null | head -1 || echo 'absent')"

# ─── Generation ─────────────────────────────────────────────────────────────────────────────────
install -d -m 0755 "$DIR"
tmp="$(mktemp)"

{
cat <<'HTML_HEAD'
<!doctype html>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>LCARS — bridge</title>
<style>
  :root { --or:#FF9900; --am:#FFCC66; --bg:#000; --pan:#141414; --dim:#7a7a7a; }
  * { box-sizing:border-box }
  body { margin:0; background:var(--bg); color:var(--am);
         font:15px/1.55 ui-monospace,"DejaVu Sans Mono",Menlo,monospace; display:flex; min-height:100vh }
  nav { width:210px; flex:0 0 210px; background:var(--pan); padding:18px 0; border-right:3px solid var(--or) }
  nav h1 { color:var(--or); font-size:15px; letter-spacing:.22em; margin:0 0 18px 18px; font-weight:700 }
  nav .grp { color:var(--dim); font-size:11px; letter-spacing:.16em; margin:16px 0 6px 18px }
  nav a { display:block; padding:7px 18px; color:var(--am); text-decoration:none; border-left:4px solid transparent }
  nav a:hover { background:#1f1f1f; border-left-color:var(--or); color:var(--or) }
  nav a.here { border-left-color:var(--or); color:var(--or) }
  main { flex:1; padding:26px 30px; max-width:900px }
  h2 { color:var(--or); font-size:17px; letter-spacing:.1em; margin:0 0 4px }
  p.sub { color:var(--dim); margin:0 0 22px }
  table { border-collapse:collapse; width:100%; margin-bottom:26px }
  th,td { text-align:left; padding:7px 10px; border-bottom:1px solid #262626; vertical-align:top }
  th { color:var(--or); font-weight:400; width:190px; white-space:nowrap }
  td.num { color:var(--or) }
  .note { border-left:3px solid var(--or); background:var(--pan); padding:11px 14px; color:var(--dim) }
  .note b { color:var(--am); font-weight:400 }
  a { color:var(--or) }
  @media (max-width:640px){ body{flex-direction:column} nav{width:auto;flex:none;border-right:0;border-bottom:3px solid var(--or)} }
</style>
<nav>
  <h1>LCARS</h1>
  <div class="grp">CONSOLES</div>
  <div id="nav-consoles"></div>
  <div class="grp">OBSERVATION</div>
  <div id="nav-decks"></div>
  <div class="grp">BOÎTE</div>
  <a class="here" href="/">Statut</a>
</nav>
<main>
  <h2>STATUT DE LA BOÎTE</h2>
  <p class="sub">Faits stables, relevés au démarrage du conteneur.</p>
  <table>
HTML_HEAD

printf '    <tr><th>hostname</th><td>%s</td></tr>\n'        "$BOX_HOST"
printf '    <tr><th>build runtime</th><td>%s</td></tr>\n'   "$BUILD"
printf '    <tr><th>source LCARS</th><td>%s</td></tr>\n'    "$SOURCE_REV"
printf '    <tr><th>ttyd</th><td>%s</td></tr>\n'            "$TTYD_VER"
printf '    <tr><th>page générée</th><td>%s</td></tr>\n'    "$GEN_AT"

echo '  </table>'
echo '  <h2>HUMAINS ET LEURS BLOCS</h2>'
echo '  <p class="sub">Un bloc de 10 ports par humain : <code>21000 + (uid % 500) × 10</code>.</p>'
echo '  <table><tr><th>humain</th><th>uid</th><th>console</th><th>deck</th></tr>'
while read -r login uid base; do
  [[ -n "$login" ]] || continue
  printf '    <tr><th>%s</th><td class="num">%s</td><td class="num">%s</td><td class="num">%s</td></tr>\n' \
         "$login" "$uid" "$(( base + 4 ))" "$(( base + 1 ))"
done < <("$HUMANS_SH")
echo '  </table>'

cat <<'HTML_TAIL'
  <div class="note">
    <b>L'état de la fleet n'est pas sur cette page</b>, et c'est voulu : elle est générée une fois
    au démarrage. Elle afficherait un « fleet vivante » figé qui mentirait dès le premier
    <code>fleet_v2 start</code>. Ce statut-là est sondé en continu dans la barre de la console.
    Le deck d'observation ne répond que si la fleet de cet humain tourne.
  </div>
</main>
<script>
// Les liens sont construits depuis l'hôte courant : la page est jointe via le port publié sur la
// loopback, et les autres portes le sont sur le même hôte. Aucune ressource externe (CSP-safe,
// et la boîte n'a aucune garantie de sortie réseau).
(function () {
  var h = location.hostname, rows = document.querySelectorAll('main table')[1];
  if (!rows) return;
  var nc = document.getElementById('nav-consoles'), nd = document.getElementById('nav-decks');
  Array.prototype.slice.call(rows.rows, 1).forEach(function (r) {
    var who = r.cells[0].textContent, cons = r.cells[2].textContent, deck = r.cells[3].textContent;
    function link(box, port, label) {
      var a = document.createElement('a');
      a.href = 'http://' + h + ':' + port; a.textContent = label; box.appendChild(a);
    }
    link(nc, cons, who);
    link(nd, deck, who);
    r.cells[2].innerHTML = '<a href="http://' + h + ':' + cons + '">' + cons + '</a>';
    r.cells[3].innerHTML = '<a href="http://' + h + ':' + deck + '">' + deck + '</a>';
  });
})();
</script>
HTML_TAIL
} > "$tmp"

install -m 0644 "$tmp" "$DIR/index.html"
rm -f "$tmp"
say "home générée : $DIR/index.html ($(wc -c < "$DIR/index.html") octets)"

# ─── Service ────────────────────────────────────────────────────────────────────────────────────
# `nobody` : la page est statique et publique, ce serveur n'a besoin d'AUCUN droit. Le faire tourner
# en root pour servir 4 Ko de HTML serait un privilege gratuit — exactement le genre qu'on refuse.
SERVE=(python3 -m http.server "$PORT" --bind 0.0.0.0 --directory "$DIR")
say "home sur le port $PORT (http://127.0.0.1:$PORT une fois publié)"

if [[ "$FOREGROUND" -eq 1 ]]; then
  exec setpriv --reuid nobody --regid nogroup --init-groups -- "${SERVE[@]}"
fi
setpriv --reuid nobody --regid nogroup --init-groups -- "${SERVE[@]}" &
say "home lancée (pid $!)"
