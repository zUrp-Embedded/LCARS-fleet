#!/usr/bin/env python3
"""Exécution LCARS d'une commande compressible.

Fichier LCARS, hors sous-arbre vendoré.

Point d'entrée appelé par `lcars_hook.py` à la place de `scripts/wrap.py`.
Sa seule raison d'être : **importer `adapter` avant** de déléguer à l'amont.

Cet import n'est pas décoratif — il fait tout le travail :

    * la configuration est figée (F4 fermé, seuils LCARS, liste blanche env) ;
    * le vocabulaire d'échec est élargi (F3) ;
    * `BuildOutputProcessor.process` est substitué (F6) ;
    * `CompressionEngine.compress` porte les deux invariants LCARS ;
    * `data_dir()` pointe où la fleet le décide.

`scripts/wrap.py` fait ensuite son travail inchangé : exécution du processus
fils, gestion des signaux, découpage des chaînes par marqueurs, propagation du
code de retour. Rien de tout cela n'avait besoin d'être réécrit.

Usage (posé par le hook, jamais tapé à la main) :
    python3 lcars_wrap.py '<commande>'
"""

import os
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

import adapter  # noqa: E402,F401  — bootstrap : tout se joue à cet import

from scripts.wrap import main  # noqa: E402

if __name__ == "__main__":
    main()
