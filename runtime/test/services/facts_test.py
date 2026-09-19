#!/usr/bin/env python3
# SOURCE: runtime/test/services/facts_test.py
# AUTHOR: bob
# STARDATE: 2026-09-20
# STATUS: actif — le banc de `services/lcars_facts.py`, le lecteur Python des FAITS DE LA MACHINE
#
# POURQUOI CE FICHIER. Un fait s'ecrit UNE fois dans `etc/facts.env` et quatre langages le lisent.
# Ce qui casse un tel dispositif n'est pas qu'un lecteur refuse : c'est qu'il REPONDE, depuis
# ailleurs, sans le dire. Les deux temoins ci-dessous tiennent les deux endroits ou ce lecteur
# pouvait repondre a cote — releve hostile du 2026-09-19.
#
# ⚠ `LCARS_FACTS_FILE` NOMME LE FICHIER DE FACON EXCLUSIVE. Nomme, il est le SEUL candidat. Avant
# cette passe il n'etait que le premier d'une liste : un temoin ou un operateur qui designait un
# fichier absent recevait en silence les faits de la machine hote, donc l'org systeme reelle la ou
# il croyait lire un decor.

import importlib.util
import os
import sys
import tempfile
import unittest

_ICI = os.path.dirname(os.path.abspath(__file__))
_MODULE = os.path.join(_ICI, "..", "..", "services", "lcars_facts.py")


def _charge_module():
    """Une instance NEUVE du module : son cache de faits est un global, donc un etat partage."""
    spec = importlib.util.spec_from_file_location("lcars_facts_sous_test", _MODULE)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class FaitsPython(unittest.TestCase):
    def setUp(self):
        self._env = dict(os.environ)
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.addCleanup(self._restaure)

    def _restaure(self):
        os.environ.clear()
        os.environ.update(self._env)

    def test_fichier_nomme_est_lu(self):
        decor = os.path.join(self.tmp.name, "facts.env")
        with open(decor, "w", encoding="utf-8") as fh:
            fh.write("# un commentaire\nLCARS_FLEET_GROUP=flotte\n\nLCARS_PRIVATE_DIR=/ailleurs\n")
        os.environ["LCARS_FACTS_FILE"] = decor

        mod = _charge_module()
        self.assertEqual(mod.chemin(), decor)
        self.assertEqual(mod.get("LCARS_FLEET_GROUP"), "flotte")
        self.assertEqual(mod.get("LCARS_PRIVATE_DIR"), "/ailleurs")

    def test_nomme_mais_absent_REFUSE_au_lieu_de_retomber(self):
        # Le defaut mesure : ce chemin absent laissait le lecteur repondre depuis
        # `/opt/lcars/etc/facts.env`, la machine reelle, sans un mot.
        os.environ["LCARS_FACTS_FILE"] = os.path.join(self.tmp.name, "pas-la.env")

        mod = _charge_module()
        self.assertIsNone(mod.chemin())
        with self.assertRaises(FileNotFoundError) as leve:
            mod.get("LCARS_FORGE_ORG")
        # Le refus nomme le fichier QU'ON LUI A DIT DE LIRE, pas la liste des candidats par defaut.
        self.assertIn("pas-la.env", str(leve.exception))
        self.assertNotIn("/opt/lcars", str(leve.exception))

    def test_environnement_gagne_sur_le_fait(self):
        decor = os.path.join(self.tmp.name, "facts.env")
        with open(decor, "w", encoding="utf-8") as fh:
            fh.write("LCARS_FLEET_GROUP=du_fichier\n")
        os.environ["LCARS_FACTS_FILE"] = decor
        os.environ["LCARS_FLEET_GROUP"] = "de_l_environnement"

        mod = _charge_module()
        self.assertEqual(mod.get("LCARS_FLEET_GROUP"), "de_l_environnement")

    def test_cle_repetee_la_derniere_gagne(self):
        # Meme regle que les trois autres lecteurs : le shell, l'Elixir et `env_field`.
        decor = os.path.join(self.tmp.name, "facts.env")
        with open(decor, "w", encoding="utf-8") as fh:
            fh.write("LCARS_FLEET_GROUP=premier\nLCARS_FLEET_GROUP=dernier\n")
        os.environ["LCARS_FACTS_FILE"] = decor

        mod = _charge_module()
        self.assertEqual(mod.get("LCARS_FLEET_GROUP"), "dernier")

    def test_cle_absente_sans_defaut_leve(self):
        decor = os.path.join(self.tmp.name, "facts.env")
        with open(decor, "w", encoding="utf-8") as fh:
            fh.write("LCARS_FLEET_GROUP=flotte\n")
        os.environ["LCARS_FACTS_FILE"] = decor

        mod = _charge_module()
        with self.assertRaises(KeyError):
            mod.get("LCARS_PAS_UN_FAIT")
        self.assertEqual(mod.get("LCARS_PAS_UN_FAIT", "repli"), "repli")


if __name__ == "__main__":
    sys.exit(0 if unittest.main(exit=False).result.wasSuccessful() else 1)
