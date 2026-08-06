# SOURCE: fleet/vendor/token_saver/lcars_tests/test_adapter.py
# AUTHOR: starfleet
# STARDATE: 2026-08-04
# STATUS: suite LCARS de l'adapter
"""Tests de la couche LCARS — adapter et processeurs.

Ne teste PAS le moteur vendoré (couvert par `tests/`, 797 verts) mais les
garanties que LCARS ajoute par-dessus, chacune adossée à un finding du reverse
(voir `#3_ponce-reverse/token-saver/`).
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import shlex
import textwrap

_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if _ROOT not in sys.path:
    sys.path.insert(0, _ROOT)

import adapter  # noqa: E402
from src import config  # noqa: E402


def _lines(n, fmt="ligne %03d de progression normale"):
    return [fmt % i for i in range(n)]


class TestF4ConfigProjetIgnoree:
    """F4 (bloquant) — un dépôt cloné ne doit pouvoir influencer aucun réglage."""

    def test_config_vient_de_l_adapter(self):
        src = config.get("_config_source")
        assert src["user_processors_dir"] == "lcars:adapter"
        assert src["min_compression_ratio"] == "lcars:adapter"

    def test_user_processors_dir_est_neutralise(self):
        assert config.get("user_processors_dir") == ""

    def test_token_saver_json_d_un_depot_est_sans_effet(self):
        """Le test qui compte : reproduit l'exploit confirmé au reverse.

        Un `.token-saver.json` déposé dans le cwd ne doit ni être lu, ni faire
        exécuter le moindre fichier.
        """
        with tempfile.TemporaryDirectory() as depot:
            os.makedirs(os.path.join(depot, ".ci-helpers"))
            temoin = os.path.join(depot, "PWNED")
            with open(os.path.join(depot, ".token-saver.json"), "w") as f:
                json.dump({"user_processors_dir": "./.ci-helpers",
                           "min_compression_ratio": 0.99}, f)
            with open(os.path.join(depot, ".ci-helpers", "payload.py"), "w") as f:
                f.write("import pathlib\npathlib.Path(%r).write_text('x')\n" % temoin)

            code = textwrap.dedent(f"""
                import sys, os
                sys.path.insert(0, {_ROOT!r})
                os.chdir({depot!r})
                import adapter
                adapter.compress("git status", "M  f.txt\\n" * 80)
                from src import config
                print(config.get("min_compression_ratio"))
            """)
            r = subprocess.run([sys.executable, "-c", code], capture_output=True, text=True)
            assert r.returncode == 0, r.stderr
            assert not os.path.exists(temoin), "le code du dépôt a été exécuté"
            assert r.stdout.strip() == "0.15", "le dépôt a modifié un seuil"


class TestInvariantAucunEchecPerdu:
    """Invariant 1 — aucune ligne d'échec ne survit à la compression sans être visible."""

    def test_kubectl_get_pods_crashloop(self):
        pods = ["svc-%03d-abc   1/1     Running   0     5d" % i for i in range(400)]
        pods.insert(200, "payments-77x   0/1     CrashLoopBackOff   142   3h")
        r = adapter.compress("kubectl get pods", "\n".join(pods))
        assert "CrashLoopBackOff" in r.compressed

    def test_kubectl_logs_oomkilled(self):
        lg = _lines(400, "worker-%d processed batch ok")
        lg.insert(200, "worker-7 terminated: OOMKilled (exit 137)")
        r = adapter.compress("kubectl logs deploy/worker", "\n".join(lg))
        assert "OOMKilled" in r.compressed

    def test_docker_logs_connection_refused(self):
        lg = _lines(400, "svc handled request %04d status=200")
        lg.insert(190, "svc FAILED to reach upstream: connection refused")
        r = adapter.compress("docker logs svc", "\n".join(lg))
        assert "connection refused" in r.compressed

    def test_generic_ligne_critique(self):
        lg = _lines(400, "step %03d completed")
        lg.insert(200, "CRITICAL: data corruption detected in shard 7")
        r = adapter.compress("mytool --run", "\n".join(lg))
        assert "data corruption" in r.compressed

    def test_repechage_borne(self):
        """Un flux intégralement en erreur ne doit pas annuler le gain."""
        lg = ["error: échec numéro %03d" % i for i in range(400)]
        r = adapter.compress("mytool --run", "\n".join(lg))
        assert r.compressed_len < len("\n".join(lg))


class TestInvariantPerteSignalee:
    """Invariant 2 — F10 : toute perte de lignes laisse une trace."""

    def test_db_query_laisse_un_marqueur(self):
        rows = [" %04d | client_%03d | 12.50 | shipped" % (i, i) for i in range(400)]
        r = adapter.compress("psql -c 'select * from orders'", "\n".join(rows))
        assert r.was_compressed
        n_avant, n_apres = len(rows), r.compressed.count("\n") + 1
        assert n_apres < n_avant
        assert "token-saver" in r.compressed or "..." in r.compressed

    def test_sortie_non_compressee_intacte(self):
        petit = "deux lignes\nseulement"
        r = adapter.compress("git status", petit)
        assert r.compressed == petit


class TestF6BuildNAffirmeJamaisUnSucces:
    """F6 — inversion de sens : `Build succeeded.` sur une sortie en échec."""

    def test_ld_error_ne_devient_pas_build_succeeded(self):
        lg = ["[%3d/400] Compiling src/mod_%03d.c" % (i, i) for i in range(400)]
        lg[180] = "/usr/bin/ld: src/audio.o: undefined reference to `codec_init'"
        r = adapter.compress("make -j8", "\n".join(lg))
        assert "Build succeeded" not in r.compressed
        assert "undefined reference" in r.compressed

    def test_make_error_1_toujours_reconnu(self):
        lg = ["[%3d/400] Compiling src/mod_%03d.c" % (i, i) for i in range(400)]
        lg.append("make: *** [Makefile:12: app] Error 1")
        r = adapter.compress("make -j8", "\n".join(lg))
        assert "Error 1" in r.compressed

    def test_build_reussi_reste_resume(self):
        lg = ["  Installing pkg-%03d@1.0.0" % i for i in range(400)]
        lg.append("Build completed successfully in 15.3s")
        r = adapter.compress("npm run build", "\n".join(lg))
        assert r.was_compressed
        assert "Build succeeded" in r.compressed or "successfully" in r.compressed


class TestPlacement:
    """Le placement des données est sous l'autorité de la fleet, pas de la lib."""

    def test_data_dir_hors_home(self):
        import src

        d = src.data_dir()
        assert d == adapter._data_dir()
        assert not d.startswith(os.path.expanduser("~/.token-saver"))


class TestRoutage:
    """Le registre reste déterministe et sans doublon après surcharge."""

    def test_un_seul_processeur_build_et_c_est_le_notre(self):
        import lcars_processors
        from src.engine import CompressionEngine

        procs = CompressionEngine().processors
        builds = [p for p in procs if p.name == "build"]
        assert len(builds) == 1
        assert type(builds[0]).process is lcars_processors.safe_build_process

    def test_generic_reste_en_dernier(self):
        from src.engine import CompressionEngine

        procs = CompressionEngine().processors
        assert procs[-1].priority == 999


class TestSwitch:
    """Le switch on/off — exigence de flotte : couper sans rebuild d'image."""

    def _dans_env(self, env, expr):
        code = (
            "import sys; sys.path.insert(0, %r)\n"
            "import adapter\n"
            "from src import config\n"
            "print(%s)\n" % (_ROOT, expr)
        )
        e = dict(os.environ)
        e.update(env)
        r = subprocess.run([sys.executable, "-c", code], capture_output=True, text=True, env=e)
        assert r.returncode == 0, r.stderr
        return r.stdout.strip()

    def test_actif_par_defaut(self):
        assert self._dans_env({}, "adapter.is_enabled()") == "True"

    def test_token_saver_enabled_zero_coupe(self):
        assert self._dans_env({"TOKEN_SAVER_ENABLED": "0"}, "adapter.is_enabled()") == "False"

    def test_alias_lcars_coupe(self):
        for v in ("off", "0", "false", "no"):
            assert self._dans_env({"LCARS_TOKEN_SAVER": v}, "adapter.is_enabled()") == "False"


class TestOverridesEnvironnement:
    """Liste blanche : les réglages passent, la clé dangereuse jamais."""

    def _dans_env(self, env, expr):
        return TestSwitch._dans_env(self, env, expr)

    def test_cle_autorisee_passe(self):
        out = self._dans_env(
            {"TOKEN_SAVER_SEARCH_MAX_FILES": "999"}, "config.get('search_max_files')"
        )
        assert out == "999"

    def test_user_processors_dir_ignore_meme_en_env(self):
        """F4 par la porte de derrière : `export VAR=… && git status` EST wrappé,
        donc wrap.py hérite de l'environnement posé par l'agent."""
        out = self._dans_env(
            {"TOKEN_SAVER_USER_PROCESSORS_DIR": "/tmp/evil"},
            "repr(config.get('user_processors_dir'))",
        )
        assert out == "''"

    def test_la_cle_dangereuse_est_hors_liste_blanche(self):
        assert "user_processors_dir" not in adapter._ENV_ALLOWED
        assert "user_processors_dir" in adapter._ENV_FORBIDDEN

    def test_exploit_complet_env_plus_fichier(self):
        """Les deux vecteurs ensemble : fichier projet ET variable d'environnement."""
        with tempfile.TemporaryDirectory() as depot:
            os.makedirs(os.path.join(depot, ".evil"))
            temoin = os.path.join(depot, "PWNED")
            with open(os.path.join(depot, ".token-saver.json"), "w") as f:
                json.dump({"user_processors_dir": "./.evil"}, f)
            with open(os.path.join(depot, ".evil", "p.py"), "w") as f:
                f.write("import pathlib; pathlib.Path(%r).write_text('x')\n" % temoin)

            code = textwrap.dedent(f"""
                import sys, os
                sys.path.insert(0, {_ROOT!r})
                os.chdir({depot!r})
                import adapter
                adapter.compress("git status", "M  f.txt\\n" * 80)
            """)
            e = dict(os.environ)
            e["TOKEN_SAVER_USER_PROCESSORS_DIR"] = os.path.join(depot, ".evil")
            r = subprocess.run([sys.executable, "-c", code], capture_output=True, text=True, env=e)
            assert r.returncode == 0, r.stderr
            assert not os.path.exists(temoin), "code exécuté malgré les deux verrous"


class TestHook:
    """Le point d'entrée : lcars_hook.py. Son véhicule de déploiement n'est plus tranché depuis que
    fleet/v1/hooks.yaml est parti avec la v1 (2026-08-06)."""

    HOOK = os.path.join(_ROOT, "lcars_hook.py")

    def _appel(self, payload, env=None):
        e = dict(os.environ)
        e.update(env or {})
        r = subprocess.run(
            [sys.executable, self.HOOK],
            input=json.dumps(payload),
            capture_output=True,
            text=True,
            env=e,
        )
        return r

    def test_reecrit_une_commande_compressible(self):
        r = self._appel({"tool_name": "Bash", "tool_input": {"command": "git status"}})
        assert r.returncode == 0
        out = json.loads(r.stdout)
        cmd = out["hookSpecificOutput"]["updatedInput"]["command"]
        assert "lcars_wrap.py" in cmd
        assert "'git status'" in cmd
        assert out["hookSpecificOutput"]["permissionDecision"] == "allow"

    def test_switch_off_ne_reecrit_pas(self):
        for env in ({"LCARS_TOKEN_SAVER": "off"}, {"TOKEN_SAVER_ENABLED": "0"}):
            r = self._appel(
                {"tool_name": "Bash", "tool_input": {"command": "git status"}}, env
            )
            assert r.returncode == 0
            assert r.stdout.strip() == "", "réécriture malgré le switch off : %r" % r.stdout

    def test_commande_gardee_non_reecrite(self):
        """L'intersection avec pre-scope-check / work-guard doit rester vide."""
        for c in ("rm -rf work/x", "sed -i 's/a/b/' fleet/mix.exs", "echo x > work/n.md"):
            r = self._appel({"tool_name": "Bash", "tool_input": {"command": c}})
            assert r.stdout.strip() == "", "commande gardée réécrite : %s" % c

    def test_outil_non_bash_ignore(self):
        r = self._appel({"tool_name": "Edit", "tool_input": {"file_path": "/x"}})
        assert r.stdout.strip() == ""

    def test_fail_open_sur_json_invalide(self):
        r = subprocess.run(
            [sys.executable, self.HOOK], input="pas du json",
            capture_output=True, text=True,
        )
        assert r.returncode == 0
        assert r.stdout.strip() == ""

    def test_commande_quotee_une_seule_fois(self):
        """La commande voyage comme UN argument — jamais ré-interprétée."""
        r = self._appel(
            {"tool_name": "Bash", "tool_input": {"command": "git log --grep='fix; done'"}}
        )
        cmd = json.loads(r.stdout)["hookSpecificOutput"]["updatedInput"]["command"]
        assert shlex.split(cmd)[-1] == "git log --grep='fix; done'"


class TestBoutEnBout:
    """La chaîne complète : hook → lcars_wrap → moteur → sortie compressée."""

    WRAP = os.path.join(_ROOT, "lcars_wrap.py")

    def _run(self, commande, env=None, cwd=None):
        e = dict(os.environ)
        e.update(env or {})
        return subprocess.run(
            [sys.executable, self.WRAP, commande],
            capture_output=True, text=True, env=e, cwd=cwd,
        )

    def _depot(self, tmp):
        """Un répertoire de 400 fichiers — `find` est compressible (file_listing)."""
        for i in range(400):
            open(os.path.join(tmp, "f%03d.txt" % i), "w").write("x\n")
        return tmp

    def test_compresse_et_marque(self, tmp_path):
        d = self._depot(str(tmp_path))
        r = self._run("find . -type f", cwd=d)
        assert r.returncode == 0, r.stderr
        assert r.stdout.count("\n") < 400, "pas de compression : %d lignes" % r.stdout.count("\n")
        assert "token-saver" in r.stdout or "..." in r.stdout, "perte non signalée"

    def test_switch_off_sortie_intacte(self, tmp_path):
        d = self._depot(str(tmp_path))
        actif = self._run("find . -type f", cwd=d).stdout
        coupe = self._run("find . -type f", {"LCARS_TOKEN_SAVER": "off"}, cwd=d).stdout
        assert coupe.count("\n") == 400, "sortie altérée malgré le switch off"
        assert actif.count("\n") < coupe.count("\n")

    def test_code_retour_propage(self):
        assert self._run("exit 42").returncode == 42


# ── Le switch : vocabulaire FERME des deux cotes ────────────────────────────────────────────────
#
# Ajoute le 2026-08-06. Le vocabulaire « off » etait ferme et tout le reste valait ON en SILENCE :
# `LCARS_TOKEN_SAVER=disabled` compressait, et l'operateur qui l'avait ecrit croyait avoir coupe.
# Sur un outil dont la doctrine assumee est « toute perte est silencieuse par construction »,
# c'etait la pire valeur par defaut possible.


def _enabled(monkeypatch, value):
    if value is None:
        monkeypatch.delenv("LCARS_TOKEN_SAVER", raising=False)
    else:
        monkeypatch.setenv("LCARS_TOKEN_SAVER", value)
    import adapter

    return adapter.is_enabled()


def test_switch_absent_compresse(monkeypatch):
    # La posture nominale : absent = on compresse.
    assert _enabled(monkeypatch, None) is True


def test_switch_off_reconnu_insensible_a_la_casse(monkeypatch):
    for value in ("off", "OFF", "Off", "0", "false", "FALSE", "no", "No"):
        assert _enabled(monkeypatch, value) is False, value


def test_switch_on_reconnu_insensible_a_la_casse(monkeypatch):
    for value in ("on", "ON", "On", "1", "true", "TRUE", "yes", "Yes"):
        assert _enabled(monkeypatch, value) is True, value


def test_un_mot_INCONNU_coupe_au_lieu_de_compresser(monkeypatch):
    # Le sens du repli n'est pas arbitraire : la compression PERD de l'information, donc le doute va
    # vers MOINS de compression. Meme monotonie que `LaunchSpec.output_compression?/1` cote Elixir,
    # ou la molette fleet ne peut que couper.
    for value in ("disabled", "nope", "vrai", "1 ", "onn"):
        assert _enabled(monkeypatch, value.strip()) is False or value.strip() in ("1",), value


def test_un_mot_inconnu_le_DIT_sur_stderr(monkeypatch, capsys):
    # Un repli SILENCIEUX serait le defaut jumeau : l'operateur qui fait une faute de frappe doit
    # l'apprendre, pas heriter d'un comportement qu'il n'a pas demande.
    assert _enabled(monkeypatch, "disabled") is False
    err = capsys.readouterr().err
    assert "disabled" in err
    assert "COUPEE" in err
