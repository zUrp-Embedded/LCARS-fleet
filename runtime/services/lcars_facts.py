#!/usr/bin/env python3
# SOURCE: runtime/services/lcars_facts.py
# AUTHOR: bob
# STARDATE: 2026-09-19
# STATUS: actif — LES FAITS DE LA MACHINE, lus par le Python du produit
"""Lecteur de `etc/facts.env` — la meme source que le shell, l'Elixir et l'installeur.

⚖ Decision 3 du plan runtime (R6). Un fait de la machine — le groupe `fleet`, l'org systeme, le
repertoire des jetons — s'ecrit UNE fois. Il l'etait jusqu'a sept.

⚠ L'ENVIRONNEMENT GAGNE SUR LE FAIT. Un fait est un DEFAUT : ce que l'installeur transporte par
`services.env`, ou ce qu'un operateur pose a la main, prime. L'ordre est le meme que cote shell,
sinon les deux rails liraient deux valeurs differentes du meme nom.

⚠ ET UN FICHIER DE FAITS ILLISIBLE EST UNE ERREUR, PAS UN DICTIONNAIRE VIDE. `get` sans defaut leve
`KeyError` : un service qui tournerait avec un chemin vide irait ecrire a la racine. Ce qu'on n'a
pas pu lire ne se devine pas.
"""
import os

# ⚠ DEUX MONDES, DEUX CHEMINS RELATIFS, ET C'EST STRUCTUREL. Sur une machine posee, ces `.py` sont
# a PLAT dans `/opt/lcars/` et les faits sont sous `etc/` a cote ; dans un checkout ils vivent sous
# `services/` et les faits sont un cran plus haut. Le shell n'a pas ce probleme (son protocole est
# imbrique pareil des deux cotes) ; ici on essaie les deux, dans cet ordre, et `LCARS_FACTS_FILE`
# passe devant les deux — c'est la meme variable que le shell honore.
_ICI = os.path.dirname(os.path.abspath(__file__))
_CANDIDATS = (
    os.path.join(_ICI, "etc", "facts.env"),
    os.path.join(_ICI, os.pardir, "etc", "facts.env"),
)

_CACHE = None


def chemin():
    """Le fichier de faits retenu, ou None si aucun candidat n'est lisible."""
    nomme = os.environ.get("LCARS_FACTS_FILE")
    for c in ((nomme,) if nomme else ()) + _CANDIDATS:
        if c and os.path.isfile(c):
            return c
    return None


def _charge():
    global _CACHE
    if _CACHE is not None:
        return _CACHE
    c = chemin()
    if c is None:
        raise FileNotFoundError(
            "fichier de faits introuvable (essayes : "
            + ", ".join(x for x in _CANDIDATS)
            + ") — les faits de la machine ne se devinent pas"
        )
    faits = {}
    with open(c, "r", encoding="utf-8") as fh:
        for ligne in fh:
            ligne = ligne.strip()
            if not ligne or ligne.startswith("#") or "=" not in ligne:
                continue
            cle, _, val = ligne.partition("=")
            faits[cle.strip()] = val.strip()
    _CACHE = faits
    return faits


def get(cle, defaut=None):
    """La valeur de `cle` : l'environnement d'abord, le fichier de faits ensuite.

    Sans `defaut`, une cle absente des deux leve `KeyError` — un service ne tourne pas sur un fait
    qu'il n'a pas.
    """
    vu = os.environ.get(cle)
    if vu:
        return vu
    faits = _charge()
    if cle in faits:
        return faits[cle]
    if defaut is not None:
        return defaut
    raise KeyError(f"fait inconnu : {cle} (ni dans l'environnement, ni dans {chemin()})")
