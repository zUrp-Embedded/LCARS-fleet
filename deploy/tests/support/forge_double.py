#!/usr/bin/env python3
# SOURCE: deploy/tests/support/forge_double.py
# AUTHOR: bob
# STARDATE: 2026-09-14
# STATUS: une forge HTTP locale pour les témoins — elle répond selon une table de routes et note chaque requête reçue
#
# USAGE  forge_double.py <dossier>
#   <dossier>/port           le port d'écoute, écrit au démarrage (127.0.0.1)
#   <dossier>/routes         une route par ligne, relue à chaque requête :
#                            <MÉTHODE|*> <chemin, * en joker> <code> [x<usages>] [<corps|@fichier|->]
#                            le corps prend le reste de la ligne ; la première route qui répond et
#                            n'a pas épuisé ses usages sert ; aucune : 404
#   <dossier>/requests.jsonl une ligne JSON par requête : method, path, auth, ctype, body
#                            (auth en clair : « token <jeton> », ou « basic <login>:<mot de passe> »)

import base64
import fnmatch
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

DOSSIER = sys.argv[1]
USAGES = {}


def auth_lisible(entete):
    if not entete:
        return None
    schema, _, valeur = entete.partition(" ")
    if schema.lower() == "basic":
        return "basic " + base64.b64decode(valeur).decode("utf-8", "replace")
    return schema.lower() + " " + valeur


def route_pour(methode, chemin):
    try:
        with open(os.path.join(DOSSIER, "routes"), encoding="utf-8") as f:
            lignes = f.read().splitlines()
    except FileNotFoundError:
        lignes = []
    for rang, ligne in enumerate(lignes):
        champs = ligne.split(" ", 3)
        if len(champs) < 3 or ligne.startswith("#"):
            continue
        m, motif, code = champs[0], champs[1], champs[2]
        corps, limite = (champs[3] if len(champs) == 4 else "-"), ""
        tete, _, suite = corps.partition(" ")
        if tete[:1] == "x" and tete[1:].isdigit():
            limite, corps = tete[1:], (suite or "-")
        if m not in ("*", methode) or not fnmatch.fnmatchcase(chemin, motif):
            continue
        if limite and USAGES.get(rang, 0) >= int(limite):
            continue
        USAGES[rang] = USAGES.get(rang, 0) + 1
        if corps == "-":
            corps = ""
        elif corps.startswith("@"):
            with open(corps[1:], encoding="utf-8") as f:
                corps = f.read()
        return int(code), corps
    return 404, '{"message":"route absente du double"}'


class Forge(BaseHTTPRequestHandler):
    def repondre(self):
        n = int(self.headers.get("Content-Length") or 0)
        corps = self.rfile.read(n).decode("utf-8", "replace") if n else ""
        note = {
            "method": self.command,
            "path": self.path,
            "auth": auth_lisible(self.headers.get("Authorization")),
            "ctype": self.headers.get("Content-Type"),
            "body": corps,
        }
        with open(os.path.join(DOSSIER, "requests.jsonl"), "a", encoding="utf-8") as f:
            f.write(json.dumps(note) + "\n")
        code, reponse = route_pour(self.command, self.path)
        donnees = reponse.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(donnees)))
        self.end_headers()
        self.wfile.write(donnees)

    do_GET = do_POST = do_PATCH = do_PUT = do_DELETE = repondre

    def log_message(self, *_):
        pass


serveur = ThreadingHTTPServer(("127.0.0.1", 0), Forge)
with open(os.path.join(DOSSIER, "port.tmp"), "w", encoding="utf-8") as f:
    f.write(str(serveur.server_address[1]))
os.rename(os.path.join(DOSSIER, "port.tmp"), os.path.join(DOSSIER, "port"))
serveur.serve_forever()
