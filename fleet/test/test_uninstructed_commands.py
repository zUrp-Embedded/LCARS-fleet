#!/usr/bin/env python3
# SOURCE: fleet/test/test_uninstructed_commands.py
# AUTHOR: DrDree
# STARDATE: 2026-08-08
# STATUS: actif — la garde de la classe « une commande existe et personne ne l'instruit »
#
# POURQUOI CE FICHIER. Le jumeau de cette question — « un geste est instruit et la commande
# n'existe pas » — a ete ratisse et ferme. La direction MIROIR avait ete declaree non mesurable :
# l'instrument d'alors greppait le texte d'aide en cherchant « <script> <sous-commande> » et
# ressortait donc en « jamais instruite » toute commande documentee sans le nom du script devant.
# C'etait vrai de l'INSTRUMENT, et faux de la QUESTION. Un instrument incapable ne ferme pas une
# question : il se remplace.
#
# CE QUI EST MESURE, en deux temps separes :
#   1. ce qui EXISTE  = les etiquettes du `case` de dispatch — le code qui repond reellement
#   2. ce qui est DIT = l'aide DU MEME script, plus le README de son dossier
# et l'ecart est un echec.
#
# DEUX PIEGES QUE CE FICHIER A DEJA PAYES, tous deux du meme genre — un instrument qui repond a la
# question voisine :
#   - un `case "$1"` DANS une fonction n'est pas un dispatch (son `$1` est l'argument de la
#     fonction) : `script_for_plane()` et `badge()` ressortaient en « sous-commandes ». Ce qui est
#     ecarte est COMPTE et imprime — une soustraction invisible est un mensonge par omission.
#   - l'aide d'un script n'est pas toujours dans le script : les modules de `deploy/modules.d`
#     implementent un protocole (`<module> check|apply`) documente une fois dans le README de leur
#     dossier. Chercher `check` dans chaque module demandait « ce fichier se documente-t-il
#     lui-meme ? », pas « un operateur peut-il l'apprendre ? ».
#
# Mesure de reference au 2026-08-08 : 13 scripts dispatchent, 39 sous-commandes, 0 non instruite
# (`lcars ls`, alias vivant de `list` absent de l'usage, ferme dans le meme geste).

import os
import re
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
SCAN = [os.path.join(ROOT, "fleet"), os.path.join(ROOT, ".claude"), ROOT]
SKIP_DIRS = {"_build", "deps", "node_modules", ".git", "tmp"}

# Etiquettes de `case` qui ne sont pas des sous-commandes : catch-all et portes d'aide.
NOT_A_COMMAND = {"*", "", "-h", "--help", "help", "-?"}

SUBJECT = re.compile(r'^\s*case\s+"?\$\{?(1|cmd|command|subcmd|action)\b')
LABEL = re.compile(r"^\s*\(?([A-Za-z0-9_|\-\*\?\.]+)\)\s")
FUNC_OPEN = re.compile(r"^\s*(?:function\s+)?[A-Za-z_][A-Za-z0-9_:-]*\s*\(\)\s*\{\s*$")
FUNC_CLOSE = re.compile(r"^\}\s*$")

ok = True


def check(cond, label):
    global ok
    print(("PASS" if cond else "FAIL") + ": " + label)
    ok = ok and bool(cond)


def candidate_files():
    seen = set()
    for base in SCAN:
        for dirpath, dirnames, filenames in os.walk(base):
            dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
            for fn in filenames:
                p = os.path.join(dirpath, fn)
                if p in seen:
                    continue
                if not (fn.endswith(".sh") or fn in ("fleet_v2", "lcars")):
                    continue
                seen.add(p)
                yield p


def dispatch_labels(text):
    """Etiquettes du `case` de la LIGNE DE COMMANDE, et le nombre de `case` internes ecartes."""
    out, skipped = [], 0
    lines = text.splitlines()
    depth, i = 0, 0
    while i < len(lines):
        if FUNC_OPEN.match(lines[i]):
            depth += 1
        elif FUNC_CLOSE.match(lines[i]) and depth > 0:
            depth -= 1

        if SUBJECT.match(lines[i]) and depth > 0:
            skipped += 1
        elif SUBJECT.match(lines[i]):
            # Compteur DISTINCT : reutiliser `depth` ecraserait la profondeur de fonction, et le
            # prochain `case` interne du fichier serait lu comme un dispatch.
            nested, j = 0, i + 1
            while j < len(lines):
                s = lines[j].strip()
                if re.match(r"^case\s", s):
                    nested += 1
                elif s.startswith("esac"):
                    if nested == 0:
                        break
                    nested -= 1
                elif nested == 0:
                    m = LABEL.match(lines[j])
                    if m:
                        out.extend(m.group(1).split("|"))
                j += 1
            i = j
        i += 1
    return [c for c in out if c not in NOT_A_COMMAND and not c.startswith("-")], skipped


def help_text(path, text):
    """L'aide du script : heredocs, bandeau de commentaires, echos — plus le README de son dossier
    et du parent. On prend LARGE a dessein : le faux positif « non instruite » est le cout eleve
    (il accuse un script correct), le faux negatif se paie au prochain ratissage."""
    chunks = []
    for m in re.finditer(r"<<-?\s*'?\"?([A-Za-z_][A-Za-z0-9_]*)'?\"?\n(.*?)\n\s*\1\b", text, re.S):
        chunks.append(m.group(2))
    for m in re.finditer(r"^(#.*(?:\n#.*)*)", text, re.M):
        chunks.append(m.group(1))
    for m in re.finditer(r"^\s*(?:echo|printf)\s+.*$", text, re.M):
        chunks.append(m.group(0))
    for d in (os.path.dirname(path), os.path.dirname(os.path.dirname(path))):
        r = os.path.join(d, "README.md")
        if os.path.isfile(r):
            chunks.append(open(r, encoding="utf-8", errors="replace").read())
    return "\n".join(chunks)


dispatchers, total_cmds, skipped_total = 0, 0, 0
silent_all = []

for path in sorted(candidate_files()):
    try:
        text = open(path, encoding="utf-8", errors="replace").read()
    except OSError:
        continue
    cmds, skipped = dispatch_labels(text)
    skipped_total += skipped
    if not cmds:
        continue
    dispatchers += 1
    cmds = list(dict.fromkeys(cmds))
    total_cmds += len(cmds)
    doc = help_text(path, text)
    for c in cmds:
        # Mot entier : `up` ne doit pas etre satisfait par `setup`.
        if not re.search(r"(?<![A-Za-z0-9_-])" + re.escape(c) + r"(?![A-Za-z0-9_-])", doc):
            silent_all.append((os.path.relpath(path, ROOT), c))

print("mesure : %d scripts dispatchent, %d sous-commandes, %d `case` internes ecartes"
      % (dispatchers, total_cmds, skipped_total))

# L'instrument doit TROUVER quelque chose : s'il ne voit plus aucun dispatch (regex cassee, arbre
# deplace), il rendrait « zero non instruite » — un vert par cecite, la forme la plus chere.
check(dispatchers >= 10, "l'instrument voit encore les dispatchers (%d >= 10)" % dispatchers)
check(total_cmds >= 30, "il voit encore leurs sous-commandes (%d >= 30)" % total_cmds)

for path, c in silent_all:
    print("   SILENCE: %s -> `%s`" % (path, c))
check(not silent_all,
      "aucune sous-commande n'existe sans etre instruite (%d trouvee(s))" % len(silent_all))

sys.exit(0 if ok else 1)
