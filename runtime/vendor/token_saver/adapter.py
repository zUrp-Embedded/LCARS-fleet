# SOURCE: runtime/vendor/token_saver/adapter.py
# AUTHOR: starfleet
# STARDATE: 2026-08-04
# STATUS: adaptateur LCARS du moteur token-saver — correctifs F3/F4/F5/F6/F7/F9/F10 hors sous-arbre vendore
"""Adapter LCARS du moteur de compression vendoré.

Fichier LCARS, hors sous-arbre vendoré (`src/`, `scripts/`, `tests/` restent
des copies strictes de l'amont — voir VENDOR.md).

Point d'entrée unique : importer ce module **avant** tout usage du moteur.
Il fige la configuration, corrige les findings du reverse, et impose
l'invariant de non-perte silencieuse.

    from adapter import compress          # au lieu de src.core.compress

Ordre d'initialisation critique : `src.core` construit son logger d'audit à
l'import (il appelle `data_dir()` immédiatement). Le placement doit donc être
posé AVANT que `src.core` ne soit importé — c'est ce que fait `_bootstrap()`.
"""

from __future__ import annotations

import os
import re
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)


# ─── Placement — sous notre autorité, pas celle de la lib ─────────────────────
#
# L'amont écrit dans ~/.token-saver (SQLite du tracker + audit.log). Sur un pod
# au home éphémère ou partagé, le placement doit être décidé par la fleet.
# LCARS_TOKEN_SAVER_DATA le porte ; à défaut, un chemin explicite sous /tmp
# plutôt qu'un home dont on ne sait rien.

def _data_dir() -> str:
    return os.environ.get(
        "LCARS_TOKEN_SAVER_DATA",
        os.path.join(os.environ.get("XDG_RUNTIME_DIR", "/tmp"), "lcars-token-saver"),
    )


# ─── Configuration figée ──────────────────────────────────────────────────────
#
# F4 (BLOQUANT, confirmé empiriquement) — l'amont cherche un `.token-saver.json`
# en remontant depuis le cwd. Un dépôt cloné peut donc régler `user_processors_dir`
# et faire EXÉCUTER son propre code à la première commande compressible.
#
# On ne referme pas ce vecteur par une liste de variables d'environnement à
# maintenir : on injecte directement le cache de configuration, ce qui
# court-circuite `_load_config()` — donc `_find_project_config()` n'est JAMAIS
# appelé. Le dépôt ne peut rien dire. L'état incorrect devient irreprésentable
# plutôt que rattrapé.

_LCARS_CONFIG = {
    # --- F4 : aucune extension chargée depuis le disque ---
    "user_processors_dir": "",
    # --- F5 : le garde-fou de gain minimal, désarmé par défaut (0.0) ---
    "min_compression_ratio": 0.15,
    "min_input_length": 400,
    # --- F7 : grep sert l'exhaustivité pour un agent ---
    "search_max_files": 60,
    "search_max_per_file": 10,
    # --- F9 : rupture mesurée entre 60 et 120 pods ---
    "kubectl_keep_head": 40,
    "kubectl_keep_tail": 40,
    "docker_log_keep_head": 30,
    "docker_log_keep_tail": 40,
    # --- marges de sécurité sur les fenêtres les plus serrées ---
    "generic_keep_head": 120,
    "generic_keep_tail": 80,
    "db_max_rows": 60,
    "max_traceback_lines": 60,
    "wrap_timeout": 300,
    "enabled": True,
    "debug": os.environ.get("TOKEN_SAVER_DEBUG", "").lower() in ("1", "true", "yes"),
}


# ─── Ce qui reste réglable à chaud, et ce qui ne l'est jamais ─────────────────
#
# Figer la configuration pour fermer F4 avait un effet de bord : plus AUCUN
# override d'environnement n'était appliqué. Sur une flotte, cela veut dire
# qu'on ne peut pas couper l'outil sans reconstruire l'image — inacceptable.
#
# On rouvre donc l'environnement, mais par LISTE BLANCHE. La distinction n'est
# pas cosmétique :
#
#   * les FICHIERS (`.token-saver.json`, global ou projet) ne sont jamais lus —
#     ils viennent d'un dépôt cloné, donc d'une source non maîtrisée ;
#   * les VARIABLES D'ENVIRONNEMENT viennent de l'image et du launcher… mais
#     pas seulement. Mesuré : `export FOO=bar && git status` EST compressible
#     (`export` est une commande silencieuse au sens de `chain_utils`), donc
#     `wrap.py` hérite de l'environnement que l'agent vient de poser.
#
# Autoriser l'environnement en bloc rouvrirait donc F4 par la porte de derrière.
# `user_processors_dir` — la seule clé qui fait EXÉCUTER du code — n'est
# réglable par AUCUNE source. Elle est absente de la liste blanche, et un test
# de non-régression le vérifie.
_ENV_ALLOWED = frozenset(
    {
        "enabled",  # le switch
        "debug",
        "min_compression_ratio",
        "min_input_length",
        "wrap_timeout",
        "max_output_bytes",
        "disabled_processors",
        "redaction_allowlist",
        "search_max_files",
        "search_max_per_file",
        "kubectl_keep_head",
        "kubectl_keep_tail",
        "docker_log_keep_head",
        "docker_log_keep_tail",
        "generic_keep_head",
        "generic_keep_tail",
        "db_max_rows",
        "max_traceback_lines",
        "max_file_lines",
        "max_diff_hunk_lines",
    }
)

# Jamais réglable, quelle que soit la source.
_ENV_FORBIDDEN = frozenset({"user_processors_dir"})


# ─── F3 : la détection d'erreur par vocabulaire ───────────────────────────────
#
# `compress_log_lines()` repêche les lignes d'erreur du milieu d'une sortie
# longue. Son motif par défaut ignore les formes d'échec les plus courantes.
# Cinq processeurs l'utilisent sans fournir le leur : docker, kubectl, syslog,
# ssh, structured_log.
#
# Mesuré au reverse : `docker logs` perd « FAILED to reach upstream: connection
# refused » et conserve « error: upstream unreachable ». Seul le vocabulaire
# décide. `kubectl logs` perd « OOMKilled ».

_LCARS_ERROR_RE = re.compile(
    r"\b("
    # amont
    r"error|exception|fatal|panic|traceback"
    # échecs génériques
    r"|failed|failure|fail|aborted|abort|rejected|invalid|denied|refused"
    r"|unreachable|timeout|timed\s?out|cannot|can't|unable"
    # conteneurs / orchestration
    r"|OOMKilled|CrashLoopBackOff|ImagePullBackOff|ErrImagePull|Evicted"
    r"|Unhealthy|BackOff|FailedScheduling|NotReady|Terminated"
    # système / compilation
    r"|segmentation\s+fault|core\s+dumped|killed|no\s+such\s+file"
    r"|undefined\s+reference|permission\s+denied|connection\s+(refused|reset)"
    r"|out\s+of\s+memory|disk\s+full|no\s+space\s+left"
    # niveaux de log standard (syslog) et corruption de donnees
    r"|critical|crit|emerg(?:ency)?|severe|corrupt(?:ed|ion)?|data\s+loss"
    # protocoles de test
    r"|not\s+ok|assert(?:ion)?|expected"
    r")\b",
    re.IGNORECASE,
)


def _bootstrap() -> None:
    """Applique tous les correctifs. Idempotent, à appeler avant `src.core`."""
    import src  # noqa: PLC0415

    # Placement : patché avant l'import de src.core, qui l'appelle à l'import.
    src.data_dir = _data_dir
    os.makedirs(_data_dir(), exist_ok=True)

    # Configuration : on remplace le CHARGEUR, pas seulement le cache.
    #
    # Remplir `_config` ne suffirait pas : tout appel à `config.reload()` — par
    # la lib, un test, un composant futur — vide le cache et relance
    # `_load_config()`, qui repart lire le disque. F4 se rouvrirait alors
    # silencieusement, à un instant imprévisible. (Défaut révélé par
    # l'exécution conjointe des deux suites de tests.)
    #
    # En substituant le chargeur, la configuration LCARS est reconstruite à
    # l'identique après chaque reload : aucune séquence d'appels ne ramène la
    # lecture de `.token-saver.json`.
    from src import config as _config  # noqa: PLC0415

    def _load_lcars_config() -> dict:
        base = dict(_config._DEFAULTS)
        base.update(_LCARS_CONFIG)
        source = dict.fromkeys(base, "lcars:adapter")

        # L'alias LCARS doit valoir À TOUS LES NIVEAUX, pas seulement dans le
        # hook : sinon `lcars_wrap.py` appelé directement compresserait alors
        # que le switch est sur off. Un switch qui ne coupe qu'une des deux
        # portes n'est pas un switch.
        if os.environ.get("LCARS_TOKEN_SAVER", "").strip().lower() in (
            "0",
            "off",
            "false",
            "no",
        ):
            base["enabled"] = False
            source["enabled"] = "env:LCARS_TOKEN_SAVER"

        # Overrides d'environnement — liste blanche stricte (voir _ENV_ALLOWED).
        for key in _ENV_ALLOWED:
            if key in _ENV_FORBIDDEN or key not in _config._DEFAULTS:
                continue
            env_key = _config.ENV_PREFIX + key.upper()
            raw = os.environ.get(env_key)
            if raw is None:
                continue
            coerced = _config._coerce_value(_config._DEFAULTS[key], raw)
            if coerced is not None:
                base[key] = coerced
                source[key] = "env:" + env_key

        base["_config_source"] = source
        return base

    _config._load_config = _load_lcars_config
    _config._config = _load_lcars_config()

    # F3 : élargissement du vocabulaire d'échec.
    from src.processors import utils as _utils  # noqa: PLC0415

    _utils._DEFAULT_ERROR_RE = _LCARS_ERROR_RE

    # F6 : substitution de la méthode de décision du processeur `build`.
    #
    # Sous-classer aurait introduit deux classes de même `name` et même
    # priorité dans un registre trié sur (priority, name) — soit exactement le
    # non-déterminisme de routage que l'amont a corrigé. On remplace donc la
    # méthode sur la classe : un seul processeur `build`, registre inchangé.
    import lcars_processors  # noqa: PLC0415
    from src.processors.build_output import BuildOutputProcessor  # noqa: PLC0415

    BuildOutputProcessor.process = lcars_processors.safe_build_process
    BuildOutputProcessor._lcars_failure_re = lcars_processors.FAILURE_RE
    BuildOutputProcessor._lcars_success_re = lcars_processors.SUCCESS_RE
    BuildOutputProcessor._lcars_extract_failure = lcars_processors.extract_failure_context


_bootstrap()

from src.core import CompressResult  # noqa: E402
from src.core import compress as _upstream_compress  # noqa: E402
from src.engine import CompressionEngine  # noqa: E402

# ─── Invariant LCARS : toute perte laisse une trace ───────────────────────────
#
# F10 — `db_query` tronque sans aucun marqueur (mesuré : 400 lignes → 22, zéro
# mention). C'est la seule violation constatée d'un principe par ailleurs tenu
# partout. Plutôt que de corriger ce processeur-là, on impose l'invariant au
# niveau de l'adapter : il vaut alors pour les 36 processeurs, et pour tout
# processeur futur qui l'oublierait.
#
# Correction par construction : le runtime ne peut plus produire une sortie
# amputée qui se présente comme complète.

_MARKER_RE = re.compile(
    r"\.\.\.|omises|omitted|truncated|skipped|more\s+(items|rows|lines|files|directories)"
    r"|total\s+lines|token-saver",
    re.IGNORECASE,
)


_MAX_RESCUED = 40  # borne : un flux 100 % erreurs ne doit pas annuler le gain


def _rescue_failures(output: str, compressed: str) -> tuple[str, int]:
    """Réinjecte les lignes d'échec que la compression a fait disparaître.

    Deuxième invariant LCARS, et le plus important : **aucune ligne d'échec ne
    peut être perdue**, quel que soit le processeur.

    L'élargissement de `_DEFAULT_ERROR_RE` (F3) ne couvre que les processeurs
    passant par `compress_log_lines()` — cinq sur trente-six. Les autres
    (`kubectl get`, `generic`, `db_query`, `test`…) ont leur propre logique de
    fenêtre et laissaient donc filer `CrashLoopBackOff`, `data corruption`,
    `assert …`. Garantir la propriété ici la rend vraie pour tous, y compris
    pour un processeur amont ajouté plus tard.
    """
    missing = [
        ln
        for ln in output.splitlines()
        if _LCARS_ERROR_RE.search(ln) and ln.strip() and ln not in compressed
    ]
    if not missing:
        return compressed, 0

    kept = missing[:_MAX_RESCUED]
    bloc = ["", "[token-saver] lignes d'échec repêchées (%d) :" % len(missing)]
    bloc.extend("  " + ln.strip() for ln in kept)
    if len(missing) > _MAX_RESCUED:
        bloc.append("  ... (%d autres)" % (len(missing) - _MAX_RESCUED))
    return compressed + "\n".join(bloc), len(missing)


def _apply_invariants(output: str, compressed: str, processor: str) -> str:
    """Applique les deux invariants à un couple (original, compressé)."""
    out, _ = _rescue_failures(output, compressed)

    n_before = output.count("\n") + 1
    n_after = out.count("\n") + 1
    if n_after < n_before and not _MARKER_RE.search(out):
        out += "\n[token-saver] %d lignes retirées sur %d (processeur: %s)" % (
            n_before - n_after,
            n_before,
            processor,
        )
    return out


# Les invariants sont posés sur `CompressionEngine.compress`, PAS sur
# `core.compress` — parce que `scripts/wrap.py` emprunte deux chemins :
#
#     commande simple  →  core.compress()   →  engine.compress()
#     chaîne (&&, ;)   →  engine.compress()   directement, par segment (l. 270)
#
# Poser les invariants au-dessus de `core` laisserait donc les chaînes y
# échapper — c'est-à-dire précisément les commandes composées qu'un agent écrit
# le plus souvent. Le moteur est le seul point par lequel tout passe.
_engine_compress_upstream = CompressionEngine.compress


def _engine_compress_lcars(self, command: str, output: str):
    compressed, name, was_compressed = _engine_compress_upstream(self, command, output)
    if not was_compressed:
        return compressed, name, was_compressed
    return _apply_invariants(output, compressed, name), name, was_compressed


CompressionEngine.compress = _engine_compress_lcars


def compress(command: str, output: str, **kw) -> CompressResult:
    """Compresse. Les invariants sont appliqués par le moteur (voir ci-dessus)."""
    return _upstream_compress(command, output, **kw)


# LE VOCABULAIRE DU SWITCH, declare UNE fois et lu par les deux etages (ici et le shim shell).
# Ferme des DEUX cotes : tout mot hors de ces deux ensembles est une faute de frappe, pas une
# intention, et il coupe en le disant (cf. is_enabled).
_OFF_VALUES = frozenset(("0", "off", "false", "no"))
_ON_VALUES = frozenset(("1", "on", "true", "yes"))


def is_enabled() -> bool:
    """Le switch, à interroger AVANT toute réécriture de commande.

    `engine.compress()` teste déjà `config.get("enabled")`, mais trop tard : à
    ce stade la commande a été réécrite, `wrap.py` a été lancé, un interpréteur
    Python a démarré. Couper là ne coûte pas rien — ça coûte un processus par
    commande, pour un résultat inchangé.

    Le hook doit appeler ceci en premier et, si c'est faux, laisser passer la
    commande sans y toucher.

        TOKEN_SAVER_ENABLED=0    # ou false / no — coupe l'outil
        LCARS_TOKEN_SAVER=off    # alias LCARS, même effet

    Aucun redéploiement d'image n'est requis : la variable suffit.
    """
    raw = os.environ.get("LCARS_TOKEN_SAVER", "").strip()
    value = raw.lower()

    if value in _OFF_VALUES:
        return False

    if value and value not in _ON_VALUES:
        # UN MOT INCONNU COUPE, ET LE DIT. Le vocabulaire « off » etait ferme et tout le reste
        # valait ON en silence : `LCARS_TOKEN_SAVER=disabled` compressait, et l'operateur qui
        # l'avait ecrit croyait avoir coupe. Sur un outil dont la doctrine assumee est « toute perte
        # est silencieuse par construction », c'est la pire valeur par defaut possible.
        #
        # Le sens du repli n'est pas arbitraire : la compression PERD de l'information, donc le
        # doute va vers MOINS de compression — la meme monotonie que
        # `LaunchSpec.output_compression?/1` cote Elixir, ou la molette fleet ne peut que couper.
        # Et il crie, parce qu'un repli silencieux serait le defaut jumeau : l'operateur qui a fait
        # une faute de frappe doit l'apprendre, pas herite d'un comportement qu'il n'a pas demande.
        print(
            "token-saver: LCARS_TOKEN_SAVER=%r n'est ni un ON ni un OFF reconnu — compression "
            "COUPEE par prudence. Valeurs acceptees : %s (on) / %s (off)."
            % (raw, "|".join(sorted(_ON_VALUES)), "|".join(sorted(_OFF_VALUES))),
            file=sys.stderr,
        )
        return False

    from src import config  # noqa: PLC0415

    return bool(config.get("enabled"))


__all__ = ["compress", "is_enabled", "CompressResult"]
