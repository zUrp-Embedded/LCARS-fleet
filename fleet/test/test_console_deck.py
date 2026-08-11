#!/usr/bin/env python3
# SOURCE: fleet/test/test_console_deck.py
# AUTHOR: DrDree
# STARDATE: 2026-08-08
# STATUS: actif — la sonde du deck de la boite, et sa distinction a trois etats
#
# POURQUOI CE FICHIER. `console-deck.py` interrogeait le deck d'un humain avec `timeout=2` et
# rendait `None` sur n'importe quelle exception ; l'appelant en faisait `fleet=False` et la page
# affichait « fleet eteinte ». Un silence de deux secondes devenait donc une ASSERTION
# d'extinction. C'est le piege que le read-model du runtime a ferme par
# `:live | :deaf | :unavailable`, refait a deux cents lignes de la.
#
# CE QUI EST EPINGLE : la CAUSE discrimine, pas l'echec. Connexion refusee = personne n'ecoute =
# eteinte, et c'est une mesure. Timeout = on n'a PAS mesure, et la page doit le dire.
#
# Les trois etats sont produits contre de vraies sockets — un serveur qui repond, un port ferme, un
# socket qui accepte et se tait — parce qu'un stub d'exception prouverait seulement que le `except`
# est bien ecrit, pas que la bibliotheque leve ce qu'on croit.

import importlib.util
import json
import os
import socket
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
DECK = os.path.join(HERE, "..", "deploy", "docker", "console-deck.py")

ok = True


def check(cond, label):
    global ok
    print(("PASS" if cond else "FAIL") + ": " + label)
    ok = ok and bool(cond)


def load_deck():
    spec = importlib.util.spec_from_file_location("console_deck", DECK)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def serve_pods(pods):
    """Un vrai serveur HTTP qui rend la charge attendue. Rend son port."""

    class H(BaseHTTPRequestHandler):
        def do_GET(self):
            body = json.dumps({"pods": pods}).encode()
            self.send_response(200)
            self.send_header("content-type", "application/json")
            self.send_header("content-length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *a):
            pass

    srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv.server_address[1], srv


def closed_port():
    """Un port sur lequel PERSONNE n'ecoute : bind pour le reserver, puis relache."""
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def silent_port():
    """Un socket qui ACCEPTE la connexion et ne repond jamais — le cas du timeout."""
    s = socket.socket()
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("127.0.0.1", 0))
    s.listen(1)
    port = s.getsockname()[1]

    def hold():
        try:
            conn, _ = s.accept()
            time.sleep(30)
            conn.close()
        except OSError:
            pass

    threading.Thread(target=hold, daemon=True).start()
    return port, s


# LE SUJET DE CE TEST N'EST PAS DANS TOUS LES ARBRES OU CE TEST TOURNE. `console-deck.py` vit sous
# `deploy/`, et l'etage `build` de l'image exclut cet arbre par construction (le layer resterait
# invalide a chaque edition de compose, pour un gate de ~10 min). Le fichier partait donc en
# `FileNotFoundError` a l'import : exit 1 SANS une seule ligne `FAIL:`, donc un gate rouge dont le
# decompte disait `PASS=14 FAIL=0` — un rouge qui n'explique pas de quoi il est fait.
#
# Meme forme que GO-7 dans `shell_gate.sh`, et le discriminant est un FAIT, pas une devinette : un
# depot porte une entree `.git`, l'artefact n'en a aucune. Sujet absent HORS depot = perimetre
# declare ; sujet absent DANS un depot = ECHEC DUR — la, le fichier devrait etre la, et un saut
# silencieux ferait disparaitre ce garde le jour ou quelqu'un supprime son sujet.
if not os.path.isfile(DECK):
    if os.path.exists(os.path.join(HERE, "..", "..", ".git")):
        print("FAIL: console-deck.py introuvable DANS un depot (%s) — sujet manquant, pas perimetre"
              % DECK)
        sys.exit(1)
    print("--- perimetre : console-deck.py absent de cet artefact (`deploy/` hors du stage de"
          " build) — contexte hors-depot, ce test NE MESURE RIEN ici. ---")
    sys.exit(0)

deck = load_deck()
check(hasattr(deck, "fleet_pods"), "console-deck.py se charge et expose fleet_pods")

live_port, srv = serve_pods([{"pod_id": "a"}, {"pod_id": "b"}])
status, pods = deck.fleet_pods({"ports": {"deck": live_port}})
check(status == "live", "un deck qui repond -> 'live' (vu: %s)" % status)
check(len(pods) == 2, "les pods rendus sont ceux du deck (vu: %d)" % len(pods))
srv.shutdown()

status, pods = deck.fleet_pods({"ports": {"deck": closed_port()}})
check(status == "off", "connexion REFUSEE -> 'off' : personne n'ecoute, et on l'a mesure (vu: %s)" % status)
check(pods == [], "'off' ne fabrique aucun pod")

sport, ssock = silent_port()
t0 = time.monotonic()
status, pods = deck.fleet_pods({"ports": {"deck": sport}})
elapsed = time.monotonic() - t0
# LE test de ce fichier : ce cas rendait « fleet eteinte ».
check(
    status == "unknown",
    "un socket qui accepte et se TAIT -> 'unknown', jamais 'off' (vu: %s)" % status,
)
check(elapsed < 10, "la sonde reste bornee par son timeout (%.1fs)" % elapsed)
ssock.close()

check(
    deck.fleet_pods({"ports": {"deck": closed_port()}})[0]
    != deck.fleet_pods({"ports": {"deck": silent_port()[0]}})[0],
    "eteinte et non-mesuree ne sont PAS le meme etat",
)

# ─── LE RATTACHEMENT PROJET ────────────────────────────────────────────────────────────────────
# Le deck le derivait d'un montage `/home/projects.ops/` que `pod_mounts_env` a retire de tous les
# pods de projet : le scan ne repondait plus que pour les architectes, et son repli AFFIRMAIT
# « fleet-level » la ou il voulait dire « je ne sais pas ». Le slug vient desormais du runtime, qui
# le sait. Ces deux cas etaient MUETS dans ce corpus — c'est ce silence qui a laisse la derive
# vivre le temps qu'il a fallu pour la voir a l'oeil.
pport, psrv = serve_pods([
    {"pod_id": "p1", "role": "engineer", "phase": "ready", "project_slug": "vitrine"},
    {"pod_id": "p2", "role": "starfleet", "phase": "ready"},
])
_, pods = deck.fleet_pods({"ports": {"deck": pport}})
by_id = {p["pod_id"]: p for p in pods}
check(
    by_id["p1"].get("project_slug") == "vitrine",
    "le slug publie par le runtime traverse la sonde (vu: %s)" % by_id["p1"].get("project_slug"),
)
check(
    by_id["p2"].get("project_slug") is None,
    "un pod fleet-level n'a pas de projet, et c'est une reponse du runtime",
)
psrv.shutdown()

sys.exit(0 if ok else 1)
