#!/usr/bin/env python3
# SOURCE: runtime/vendor/token_saver/lcars_hook.py
# AUTHOR: starfleet
# STARDATE: 2026-08-04
# STATUS: hook LCARS — switch, decision de routage, reecriture de commande
"""Hook PreToolUse LCARS — point d'entrée de la compression d'output.

Fichier LCARS, hors sous-arbre vendoré.

UN POD NE PEUT PAS EXECUTER DE HOOK, et ce n'est pas un manque de cablage : c'est le sanctuaire.
Mesure du 2026-08-07 — `bwrap_launch.sh` ne monte que `plugins/` et `skills/` sous le `.claude/` du
pod, aucun `hooks/` ; `pod_settings_json/1` n'ecrit aucune cle `hooks` ; et le `.claude` de l'humain
est deliberement NON monte, avec les hooks pour motif nomme dans le launcher. Le tier `user`
(`~/.claude/hooks/`) est exclu inconditionnellement par `--setting-sources` — un hook deploye la ne
tirerait jamais dans un pod non plus. Ce fichier est un hook `PreToolUse` : il ne s'execute
aujourd'hui NULLE PART, ni pod ni hote. Lit le
JSON de l'appel d'outil sur stdin, décide si la commande est compressible, et
si oui la réécrit pour qu'elle passe par `lcars_wrap.py`.

## Ce que ce fichier ajoute à l'amont

Un seul geste, mais il est la raison d'être du fichier : **le switch est
interrogé en premier**, avant toute lecture de stdin et avant tout import du
moteur. Coupé, le hook rend la main immédiatement et la commande passe intacte.

`engine.compress()` teste bien `config.get("enabled")`, mais beaucoup trop tard
— à ce stade la commande a été réécrite, un interpréteur Python a démarré et le
moteur s'est chargé. Un processus par commande Bash, sur quinze agents, pour un
résultat identique à ne rien faire.

La décision de routage elle-même (`is_compressible`) reste celle de l'amont :
460 lignes d'exclusions construites par danger — streaming, `sudo`, éditeurs,
REPL, redirections, substitutions de processus, récursion — avec des parseurs
attentifs aux guillemets. La réécrire aurait été une perte nette.

## Discipline de défaillance

Fail-open sur toute anomalie : JSON invalide, moteur absent, exception. Un hook
`PreToolUse` cassé bloquerait le travail de l'agent ; celui-ci s'efface. Une
compression manquée coûte des tokens, une commande bloquée coûte un pod.
"""

import json
import os
import shlex
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))


def _passthrough() -> None:
    """Laisse la commande intacte. Aucune sortie = aucune modification."""
    sys.exit(0)


def main() -> None:
    if _HERE not in sys.path:
        sys.path.insert(0, _HERE)

    # 1. LE SWITCH, avant tout le reste.
    try:
        import adapter

        if not adapter.is_enabled():
            _passthrough()
    except Exception:  # noqa: BLE001 — moteur indisponible : on s'efface
        _passthrough()

    # 2. L'appel d'outil.
    try:
        payload = json.loads(sys.stdin.read())
    except (json.JSONDecodeError, ValueError):
        _passthrough()

    if payload.get("tool_name") != "Bash":
        _passthrough()

    command = (payload.get("tool_input") or {}).get("command") or ""
    if not command:
        _passthrough()

    # 3. La décision de routage — celle de l'amont, inchangée.
    try:
        from scripts.hook_pretool import is_compressible

        if not is_compressible(command):
            _passthrough()
    except Exception:  # noqa: BLE001
        _passthrough()

    wrap = os.path.join(_HERE, "lcars_wrap.py")
    if not os.path.isfile(wrap):
        _passthrough()

    # 4. La réécriture. `shlex.quote` sur chaque partie : la commande d'origine
    #    voyage comme UN argument, elle n'est jamais ré-interprétée par le shell.
    python = "python" if os.name == "nt" else "python3"
    session = payload.get("session_id") or ""
    prefix = "LCARS_TOKEN_SAVER_SESSION=%s " % shlex.quote(session) if session else ""
    rewritten = "%s%s %s %s" % (prefix, python, shlex.quote(wrap), shlex.quote(command))

    json.dump(
        {
            "hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "permissionDecision": "allow",
                "updatedInput": {"command": rewritten},
            }
        },
        sys.stdout,
    )
    sys.exit(0)


if __name__ == "__main__":
    main()
