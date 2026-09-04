#!/usr/bin/env python3
# SOURCE: runtime/test/crosscutting/uninstructed_commands_test.py
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
# QUATRE PIEGES QUE CE FICHIER A PAYES, tous du meme genre — un instrument qui repond a la question
# voisine. Les deux premiers font des FAUX POSITIFS (il accuse un script correct), les deux suivants
# des FAUX NEGATIFS (il rend vert sur un silence reel), et ceux-la sont les plus chers :
#   - un `case "$1"` DANS une fonction n'est pas un dispatch (son `$1` est l'argument de la
#     fonction) : `script_for_plane()` et `badge()` ressortaient en « sous-commandes ». Ce qui est
#     ecarte est COMPTE et imprime — une soustraction invisible est un mensonge par omission.
#   - l'aide d'un script n'est pas toujours dans le script : les modules de `deploy/modules.d`
#     implementent un protocole (`<module> check|apply`) documente une fois dans le README de leur
#     dossier. Chercher `check` dans chaque module demandait « ce fichier se documente-t-il
#     lui-meme ? », pas « un operateur peut-il l'apprendre ? ».
#   - chercher le MOT n'importe ou dans l'aide : `purge` et `forge` apparaissent dans la prose, donc
#     une sous-commande non documentee portant ces noms passait. Mesure de l'angle mort : 1 sur 3
#     injectees vue. Une instruction a une FORME (synopsis, alternance, invocation), une phrase non.
#   - accepter n'importe quelle invocation : `` `chown root:fleet` `` est bien formee et `fleet` y
#     est un nom de groupe. Le SUJET doit etre le script lui-meme.
#
# Mesure de reference au 2026-08-08, dans les DEUX directions :
#   - corpus reel : 13 scripts dispatchent, 39 sous-commandes, 0 non instruite (`lcars ls`, alias
#     vivant de `list` absent de l'usage, ferme dans le meme geste) ;
#   - sensibilite : 9 sous-commandes non documentees injectees dans 4 scripts, 9 attrapees. Une
#     garde qu'on ne mesure que sur un corpus vert ne prouve que sa politesse.
#
# CE GARDE MARCHE UN ARBRE, ET IL Y A DEUX ARBRES. L'etage `build` de l'image rejoue ce gate sur un
# tree qui n'est PAS le depot : il exclut `deploy/` par construction (le layer resterait invalide a
# chaque edition de compose, et le gate — ~10 min — serait repaye pour rien). Or ONZE des treize
# dispatchers vivent sous `deploy/`. L'image en voyait donc 2 pour 10 sous-commandes, et sa garde de
# population a rougi — CORRECTEMENT : elle disait « je ne vois pas le corpus sur lequel on m'a
# calibree ». Le defaut n'etait pas la garde, c'etait un seuil calibre sur un arbre applique a
# l'autre. Date de la rencontre : garde resserree le 2026-08-08 10h22, derniere image verte le
# 2026-08-07 17h25 — l'image n'avait jamais joue cette garde.
#
# Ce que ce fichier fait desormais, et c'est la forme DEJA en service dans `shell_gate.sh` pour GO-7
# (« NON VERIFIE ici — contexte hors-depot ») : il DECLARE son perimetre au lieu de le supposer.
# Hors depot, le seuil calibre tombe, l'assertion de fond reste. Un pas qui saute en silence est le
# defaut ; un pas qui dit ce qu'il n'a pas mesure est une reponse.
#
# LE DISCRIMINANT EST UN FAIT : un depot porte une entree `.git` (dossier en clone, fichier en
# worktree lie), l'artefact n'en a aucune. On ne relaie pas au binaire `git` comme le fait le shell
# — ce test doit tourner dans une image ou sa presence n'est pas un acquis, et une exception
# `FileNotFoundError` lue comme « hors depot » serait une devinette la ou on veut un fait.

import os
import re
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", ".."))
SCAN = [os.path.join(ROOT, "fleet"), os.path.join(ROOT, ".claude"), ROOT]
IN_REPO = os.path.exists(os.path.join(ROOT, ".git"))
SKIP_DIRS = {"_build", "deps", "node_modules", ".git", "tmp"}

# Etiquettes de `case` qui ne sont pas des sous-commandes : catch-all et portes d'aide.
NOT_A_COMMAND = {"*", "", "-h", "--help", "help", "-?"}

SUBJECT = re.compile(r'^\s*case\s+"?\$\{?(1|cmd|command|subcmd|action)\b')
# La fin de ligne compte AUTANT qu'une espace. `  status)` seul sur sa ligne, corps en dessous, est
# une forme bash ordinaire — 29 lignes de ce depot l'ecrivent. Exiger un `\s` APRES la parenthese
# faisait rater ces etiquettes-la : la sous-commande existait, dispatchait, et ne ressortait jamais
# en « non instruite ». Un faux NEGATIF, la moitie chere de la question, et invisible sur le corpus
# du jour ou les 3 occurrences sous `runtime/` sont toutes des flags `--…` deja ecartes.
LABEL = re.compile(r"^\s*\(?([A-Za-z0-9_|\-\*\?\.]+)\)(?=\s|$)")
# ⚠ UN COMMENTAIRE APRES L'ACCOLADE RENDAIT L'INSTRUMENT AVEUGLE A TOUTE LA FONCTION. `\{\s*$`
# exigeait l'accolade suivie de RIEN — or `_dest_repo_create() {  # cli repo visibility(...)` est
# une forme bash ordinaire, et la ligne ne matchait pas. La profondeur restait a 0, donc le `case
# "$1" in` de la ligne SUIVANTE etait lu comme un dispatch de ligne de commande, et ses etiquettes
# (`gh`, `glab`) ressortaient en « sous-commandes non instruites ». Un faux POSITIF, qui accuse un
# fichier juste — et le pire des deux, parce qu'il envoie corriger ce qui va bien.
#
# Trouve le 2026-08-14 en fusionnant le lot de publication : le garde vivait dans `main`, la forme
# est arrivee avec l'autre chantier. Aucun des deux n'avait tort.
FUNC_OPEN = re.compile(r"^\s*(?:function\s+)?[A-Za-z_][A-Za-z0-9_:-]*\s*\(\)\s*\{\s*(?:#.*)?$")
# Symetrique : `}  # fin de X` ferme aussi une fonction. Sans ca, la profondeur ne redescendrait
# jamais et TOUT le reste du fichier serait ecarte — un faux NEGATIF, l'autre moitie chere.
FUNC_CLOSE = re.compile(r"^\}\s*(?:#.*)?$")

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
                if not (fn.endswith(".sh") or fn in ("fleet", "lcars")):
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


def own_help(text):
    """L'aide DU script : heredocs d'usage, bandeau de commentaires, echos."""
    chunks = []
    for m in re.finditer(r"<<-?\s*'?\"?([A-Za-z_][A-Za-z0-9_]*)'?\"?\n(.*?)\n\s*\1\b", text, re.S):
        chunks.append(m.group(2))
    for m in re.finditer(r"^(#.*(?:\n#.*)*)", text, re.M):
        chunks.append(m.group(1))
    for m in re.finditer(r"^\s*(?:echo|printf)\s+.*$", text, re.M):
        chunks.append(m.group(0))
    return "\n".join(chunks)


def readmes(path):
    out = []
    for d in (os.path.dirname(path), os.path.dirname(os.path.dirname(path))):
        r = os.path.join(d, "README.md")
        if os.path.isfile(r):
            out.append(open(r, encoding="utf-8", errors="replace").read())
    return "\n".join(out)


# UNE INSTRUCTION A UNE FORME, ET C'EST TOUT L'ECART ENTRE CE GARDE ET LE PRECEDENT.
#
# La premiere version cherchait le mot n'importe ou dans l'aide. Mesure : sur trois sous-commandes
# non documentees injectees dans un module (`purge`, `human`, `forge`), elle n'en voyait qu'UNE —
# `purge` et `forge` apparaissent dans la prose de l'en-tete et du README, et un mot dans une phrase
# etait accepte comme une instruction. Deux tiers d'angle mort dans un garde cense fermer la classe.
#
# Deux formes admises, et rien d'autre :
#   1. LIGNE DE SYNOPSIS — la commande est le PREMIER token de la ligne (apres un `#`, des espaces,
#      ou le nom du script / `$PROG` / `$0`). C'est la forme de `box` et de `lcars`.
#   2. DOS DE CITATION — la commande est dans un `code span`. C'est la forme de `fleet` dans son
#      bandeau (`` `fleet forge <n>` ``) et du protocole des modules (`` `<module> check|apply` ``).
#   3. ALTERNANCE — la commande est un membre d'un `{start|stop|status}`. C'est la forme de l'usage
#      de `fleet`, et l'oublier faisait ressortir trois de ses six gestes comme non instruits :
#      une regle trop stricte accuse un script correct, ce qui est le cout eleve ici.
#
# Dans un README, SEULE la forme 2 compte : la prose d'un README n'instruit personne, elle raconte.
def instructed(cmd, path, text):
    c = re.escape(cmd)
    prefix = r"(?:[#*\-]\s*)?(?:\$PROG\s+|\$0\s+|" + re.escape(os.path.basename(path)) + r"\s+)?"
    synopsis = re.compile(r"^\s*" + prefix + c + r"(?![A-Za-z0-9_-])", re.M)
    brace = re.compile(r"\{[A-Za-z0-9_|\- \[\]]*(?<![A-Za-z0-9_-])" + c + r"(?![A-Za-z0-9_-])"
                       r"[A-Za-z0-9_|\- \[\]]*\}")

    # Une citation doit etre une INVOCATION, pas une mention, et la regle vaut PARTOUT — dans le
    # README comme dans l'aide du script. `` `fleet` `` designe un groupe unix, `` `50-forge` `` un
    # fichier : les accepter laissait passer des sous-commandes `fleet` et `forge` non documentees
    # (mesure : 2 des 4 injectees, puis 1 apres avoir resserre le seul README). Une invocation a un
    # token DEVANT elle — `` `<module> check|apply` ``, `` `fleet start` `` — donc la commande ne
    # peut pas etre le premier mot de la citation.
    # Et ce qui precede doit etre le SCRIPT, pas n'importe quel token. `` `chown root:fleet` `` est
    # une invocation parfaitement formee ou `fleet` est un nom de groupe : la derniere sous-commande
    # injectee passait par la. Le sujet nomme (`<module>`, le basename, `$PROG`, `$0`) suivi de son
    # argument — dont les membres d'une alternance `check|apply` — est la seule forme retenue.
    subject = r"(?:<module>|\$PROG|\$0|" + re.escape(os.path.basename(path)) + r")"
    invocation = re.compile(r"`[^`\n]*" + subject + r"\s+([A-Za-z0-9_|.\-]+)")

    def invoked(blob):
        return any(cmd in m.group(1).split("|") for m in invocation.finditer(blob))

    own = own_help(text)
    if synopsis.search(own) or brace.search(own) or invoked(own):
        return True
    return invoked(readmes(path))


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
    for c in cmds:
        if not instructed(c, path, text):
            silent_all.append((os.path.relpath(path, ROOT), c))

print("mesure : %d scripts dispatchent, %d sous-commandes, %d `case` internes ecartes"
      % (dispatchers, total_cmds, skipped_total))

# L'instrument doit TROUVER quelque chose : s'il ne voit plus aucun dispatch (regex cassee, arbre
# deplace), il rendrait « zero non instruite » — un vert par cecite, la forme la plus chere.
#
# Les seuils 10/30 sont calibres sur LE DEPOT (13/39 au 2026-08-08) et n'ont de sens que la. Hors
# depot, le plancher tombe a « l'instrument matche encore quelque chose » — et pas a un seuil
# calibre sur l'artefact (2/10 au 2026-08-09) : ce chiffre est decide par le `COPY` du Dockerfile,
# donc le figer ici ferait de ce test le gardien d'un perimetre qu'il ne choisit pas, rouge le jour
# ou l'etage de build exclut un arbre de plus pour une raison qui le regarde. Ce qui reste garde est
# ce que ce fichier possede : sa regex trouve des dispatchers, ou elle est cassee.
if IN_REPO:
    check(dispatchers >= 10, "l'instrument voit encore les dispatchers (%d >= 10)" % dispatchers)
    check(total_cmds >= 30, "il voit encore leurs sous-commandes (%d >= 30)" % total_cmds)
else:
    print("--- perimetre : arbre HORS DEPOT (pas de .git sous %s) — `deploy/` et la racine du depot"
          " sont absents de cet artefact. Seuils de population calibres NON APPLIQUES ;"
          " ce qui suit ne porte que sur les %d dispatcher(s) presents ici. ---"
          % (ROOT, dispatchers))
    check(dispatchers >= 1, "l'instrument matche encore un dispatch (%d >= 1)" % dispatchers)

for path, c in silent_all:
    print("   SILENCE: %s -> `%s`" % (path, c))
check(not silent_all,
      "aucune sous-commande n'existe sans etre instruite (%d trouvee(s))" % len(silent_all))

sys.exit(0 if ok else 1)
