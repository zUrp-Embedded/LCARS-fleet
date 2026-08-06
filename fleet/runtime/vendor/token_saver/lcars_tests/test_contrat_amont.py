"""Contrat d'ancrage avec l'amont — garde-fou de mise à jour.

La couche LCARS ne modifie aucun fichier vendoré : elle **s'accroche** à des
points précis du moteur amont (constantes, méthodes, fonctions de module).
Ces points ne font partie d'aucune API publique — l'amont peut les renommer ou
les supprimer sans que ce soit une rupture de son point de vue.

Sans ce fichier, une mise à jour du sous-arbre romprait ces ancrages **en
silence** : `adapter.py` continuerait de s'exécuter, ses correctifs ne
s'appliqueraient simplement plus. Un `_DEFAULT_ERROR_RE` renommé, et les
échecs redisparaissent des logs sans qu'aucun test ne rougisse.

Chaque test ci-dessous vérifie qu'un ancrage existe toujours. Ils doivent être
lus comme la liste exhaustive de ce que `update_vendor.sh` peut casser.
"""

from __future__ import annotations

import inspect
import os
import sys

_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if _ROOT not in sys.path:
    sys.path.insert(0, _ROOT)

import adapter  # noqa: E402,F401  (bootstrap)


class TestAncragePlacement:
    def test_src_expose_data_dir(self):
        import src

        assert callable(src.data_dir), "src.data_dir a disparu — placement non maîtrisé"


class TestAncrageConfiguration:
    """L'adapter substitue le chargeur pour fermer F4."""

    def test_defaults_existe(self):
        from src import config

        assert isinstance(config._DEFAULTS, dict)

    def test_load_config_existe(self):
        from src import config

        assert callable(config._load_config), (
            "config._load_config a disparu — F4 se rouvre : la configuration "
            "projet redeviendrait lisible depuis un dépôt cloné"
        )

    def test_cache_config_existe(self):
        from src import config

        assert hasattr(config, "_config")

    def test_cles_figees_existent_toujours(self):
        """Une clé disparue en amont = un réglage LCARS sans effet."""
        from src import config

        manquantes = [k for k in adapter._LCARS_CONFIG if k not in config._DEFAULTS]
        assert not manquantes, "clés absentes de l'amont : %s" % manquantes

    def test_reload_ne_rouvre_pas_f4(self):
        """Le cas qui avait échappé au premier jet de l'adapter."""
        from src import config

        config.reload()
        assert config.get("user_processors_dir") == ""
        assert config.get("_config_source")["user_processors_dir"] == "lcars:adapter"


class TestAncrageVocabulaireErreur:
    """F3 — l'adapter réassigne cette constante de module."""

    def test_default_error_re_existe(self):
        from src.processors import utils

        assert hasattr(utils, "_DEFAULT_ERROR_RE"), (
            "utils._DEFAULT_ERROR_RE a disparu — F3 se rouvre : OOMKilled, "
            "connection refused et consorts redeviennent invisibles"
        )

    def test_default_error_re_est_le_notre(self):
        from src.processors import utils

        assert utils._DEFAULT_ERROR_RE is adapter._LCARS_ERROR_RE

    def test_compress_log_lines_accepte_error_re(self):
        from src.processors.utils import compress_log_lines

        params = inspect.signature(compress_log_lines).parameters
        assert "error_re" in params, "signature de compress_log_lines modifiée"


class TestAncrageProcesseurBuild:
    """F6 — l'adapter substitue la méthode `process` sur la classe amont."""

    def test_classe_existe(self):
        from src.processors.build_output import BuildOutputProcessor  # noqa: F401

    def test_process_est_le_notre(self):
        import lcars_processors
        from src.processors.build_output import BuildOutputProcessor

        assert BuildOutputProcessor.process is lcars_processors.safe_build_process, (
            "la substitution F6 n'a pas pris — `build` peut de nouveau répondre "
            "'Build succeeded.' sur un échec"
        )

    def test_signature_process_inchangee(self):
        import lcars_processors

        params = list(inspect.signature(lcars_processors._upstream_process).parameters)
        assert params == ["self", "command", "output"], (
            "signature amont de process() modifiée : %s" % params
        )

    def test_is_progress_line_existe(self):
        """Utilisé par safe_build_process pour reproduire la décision amont."""
        from src.processors.build_output import BuildOutputProcessor

        assert callable(BuildOutputProcessor._is_progress_line)

    def test_summarize_success_existe_toujours(self):
        """C'est lui qui produit 'Build succeeded.' — sa disparition changerait
        la nature de F6 et rendrait notre correctif inutile (ou nuisible)."""
        from src.processors.build_output import BuildOutputProcessor

        assert callable(BuildOutputProcessor._summarize_success)


class TestAncrageMoteur:
    def test_compress_result_a_les_champs_attendus(self):
        from src.core import CompressResult

        attendus = {
            "compressed",
            "processor",
            "was_compressed",
            "is_mismatch",
            "attempted_processor",
            "original_len",
            "compressed_len",
        }
        assert attendus <= set(CompressResult._fields)

    def test_compress_signature(self):
        from src.core import compress

        params = list(inspect.signature(compress).parameters)
        assert params[:2] == ["command", "output"]

    def test_discover_processors_existe(self):
        from src.processors import discover_processors

        assert callable(discover_processors)

    def test_generic_reste_le_dernier_recours(self):
        from src.engine import CompressionEngine

        procs = CompressionEngine().processors
        assert procs[-1].priority == 999
        assert procs[-1].name == "generic"


class TestAncrageRoutage:
    """scripts/ est vendoré : la décision de routage reste celle de l'amont."""

    def test_is_compressible_existe(self):
        from scripts.hook_pretool import is_compressible

        assert is_compressible("git status") is True
        assert is_compressible("rm -rf work/") is False

    def test_les_commandes_gardees_restent_hors_perimetre(self):
        """L'intersection avec les gardes LCARS doit rester vide.

        `pre-scope-check.sh` et `work-guard.sh` lisent `.tool_input.command`
        pour décider un deny. Si token-saver se mettait à réécrire une commande
        qu'ils surveillent, leur extraction de chemin porterait sur la commande
        enveloppée.
        """
        from scripts.hook_pretool import is_compressible

        gardees = [
            "rm -rf work/scratchpad",
            "mv work/plan.md work/done/",
            "cp secrets.env /tmp/x",
            "sed -i 's/a/b/' fleet/runtime/mix.exs",
            "echo x > work/notes.md",
            "cat foo >> work/journal.md",
            "chmod 777 /home/projects/LCARS",
            "git add . && git commit -m 'x'",
        ]
        wrappees = [c for c in gardees if is_compressible(c)]
        assert not wrappees, "collision avec les gardes LCARS : %s" % wrappees
