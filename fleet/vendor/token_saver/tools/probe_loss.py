#!/usr/bin/env python3
# SOURCE: fleet/vendor/token_saver/tools/probe_loss.py
# AUTHOR: starfleet (reverse ppgranger/token-saver, 2026-08-03)
# STARDATE: 2026-08-03
# STATUS: harnais de mesure de PERTE — critere de recette de la brique (14/24 amont natif,
#         23/24 sous adapter). Hors sous-arbre vendore : il est a nous.
"""Harnais de mesure de perte — brique vendorée token_saver (LCARS).

Copie du harnais du reverse (#3_ponce-reverse/token-saver/tools/), câblée
sur l'adapter LCARS. Sert de critère de recette du gate : mesure ce que la
compression fait disparaître d'une sortie volumineuse.

Référence : 14/24 témoins en configuration amont native, 23/24 sous adapter.
Le 24e (`REFUND_PENDING` dans 400 lignes SQL) est une limite ACCEPTÉE : c'est
une donnée métier, pas une ligne d'échec — compresser un résultat de requête
est le comportement voulu.

Question : une information critique noyee dans une sortie volumineuse
survit-elle a la compression ?

Le projet fournit `audit_compression.py`, qui mesure le GAIN. Ce harnais
mesure la PERTE — le trou instrumental correspondant.

Methode : sorties realistes volumineuses contenant des lignes-temoins
identifiables, passees au moteur reel (src.core.compress). Aucune lecture
de code : on mesure le comportement observable.

Usage :
    python3 probe_loss.py /chemin/vers/clone
    python3 probe_loss.py /chemin/vers/clone -v     # montre la sortie compressee
"""

import os
import sys

REPO = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith("-") else "."
VERBOSE = "-v" in sys.argv
sys.path.insert(0, REPO)
os.chdir(REPO)

from adapter import compress  # noqa: E402
from src.diffstat import summarize  # noqa: E402

N = 400  # volume par defaut, largement au-dessus de tous les seuils


def filler(fmt, n=N, **kw):
    return [fmt % dict(i=i, **kw) for i in range(n)]


def inject(lines, at, *critical):
    out = list(lines)
    for k, c in enumerate(critical):
        out.insert(at + k, c)
    return "\n".join(out)


# ── (label, commande, sortie, temoins critiques) ──────────────────────────────

CASES = [
    # --- build / langages ---
    ("make: ld error seule", "make -j8",
     inject(filler("[%(i)3d/400] Compiling src/mod_%(i)03d.c"), 180,
            "/usr/bin/ld: src/audio.o: undefined reference to `codec_init'"),
     ["undefined reference"]),

    ("make: ld error + 'Error 1' final", "make -j8",
     inject(filler("[%(i)3d/400] Compiling src/mod_%(i)03d.c"), 180,
            "/usr/bin/ld: undefined reference to `codec_init'") + "\nmake: *** [Makefile:12: app] Error 1",
     ["Error 1"]),

    ("go build: undefined", "go build ./...",
     inject(filler("ok  \tpkg/mod%(i)03d\t0.00%(i)ds"), 200,
            "# pkg/audio", "./codec.go:12:2: undefined: CodecInit"),
     ["undefined: CodecInit"]),

    ("cargo: error[E0425]", "cargo build",
     inject(filler("   Compiling crate_%(i)03d v0.1.0"), 200,
            "error[E0425]: cannot find value `codec` in this scope"),
     ["E0425"]),

    ("pytest: echec noye", "pytest -v",
     inject(filler("tests/test_m%(i)03d.py::test_c PASSED   [ 50%%]"), 200,
            "tests/test_pay.py::test_refund FAILED   [ 50%]",
            "E       assert 10.005 == 10.01"),
     ["FAILED", "assert 10.005"]),

    # --- logs de conteneurs / systeme ---
    ("docker logs: FAILED/refused (sans 'error')", "docker logs svc",
     inject(filler("2026-08-03T04:12:00Z svc handled id=%(i)04d status=200"), 190,
            "2026-08-03T04:12:31Z svc FAILED to reach upstream: connection refused"),
     ["connection refused"]),

    ("docker logs: CONTROLE avec 'error'", "docker logs svc",
     inject(filler("2026-08-03T04:12:00Z svc handled id=%(i)04d status=200"), 190,
            "2026-08-03T04:12:31Z svc error: upstream unreachable"),
     ["upstream unreachable"]),

    ("kubectl logs: OOMKilled", "kubectl logs deploy/worker",
     inject(filler("worker-%(i)d processed batch ok"), 200,
            "worker-7 terminated: OOMKilled (exit 137)"),
     ["OOMKilled"]),

    ("ssh: permission denied", "ssh host 'tail -n 400 /var/log/app.log'",
     inject(filler("Aug  3 04:12:00 host app: request %(i)04d ok"), 200,
            "Aug  3 04:12:31 host app: permission denied opening /data/keys"),
     ["permission denied"]),

    # --- infra ---
    ("terraform plan: destroy noye", "terraform plan",
     inject(filler("  # module.net.aws_subnet.s%(i)03d will be created"), 200,
            "  # aws_db_instance.production will be destroyed",
            "  - identifier = \"prod-main-db\" -> null"),
     ["will be destroyed", "prod-main-db"]),

    ("kubectl get pods: CrashLoopBackOff", "kubectl get pods",
     inject(filler("svc-%(i)03d-abc   1/1     Running   0     5d"), 200,
            "payments-77x   0/1     CrashLoopBackOff   142   3h"),
     ["CrashLoopBackOff"]),

    ("docker ps: unhealthy", "docker ps",
     inject(filler("c%(i)03d  img:latest  Up 5 days (healthy)  svc_%(i)03d"), 200,
            "cdead  img:latest  Up 2 hours (unhealthy)  payments"),
     ["unhealthy"]),

    ("ansible: failed=1", "ansible-playbook site.yml",
     inject(filler("ok: [host%(i)03d]"), 200,
            "fatal: [host200]: FAILED! => {\"msg\": \"disk full on /var\"}"),
     ["disk full"]),

    # --- paquets / deps ---
    ("npm ls: UNMET DEPENDENCY", "npm ls",
     inject(filler("+-- pkg-%(i)03d@1.0.%(i)d"), 200,
            "+-- UNMET DEPENDENCY react@^18.0.0"),
     ["UNMET"]),

    ("pip install: conflit", "pip install -r requirements.txt",
     inject(filler("Collecting pkg-%(i)03d==1.0.%(i)d"), 200,
            "ERROR: Cannot install urllib3==2.0 and botocore 1.29 (conflict)"),
     ["Cannot install"]),

    # --- recherche / fichiers ---
    ("grep: 400 hits / 50 fichiers", "grep -rn api_key src/",
     "\n".join("src/pkg%02d/mod.py:%d:  api_key = env['S_%02d_%d']" % (f, 10 + k, f, k)
               for f in range(50) for k in range(8)),
     ["src/pkg00/mod.py", "src/pkg49/mod.py"]),

    ("find: 300 fichiers, 1 cible", "find . -name '*.py'",
     inject(["./src/pkg%02d/f_%03d.py" % (i // 20, i) for i in range(300)], 150,
            "./config/production_secrets.yaml"),
     ["production_secrets.yaml"]),

    # --- reseau / donnees ---
    ("curl -v: HTTP 500", "curl -v https://api.example.com/health",
     inject(filler("< x-trace-%(i)03d: abcdef"), 200,
            "< HTTP/2 500 ", "< x-error: upstream timeout"),
     ["500"]),

    ("psql: lignes nombreuses", "psql -c 'select * from orders'",
     inject(filler(" %(i)04d | client_%(i)03d | 12.50 | shipped"), 200,
            " 9999 | client_XXX | 99999.00 | REFUND_PENDING"),
     ["REFUND_PENDING"]),

    # --- fallback ---
    ("generic: sortie inconnue", "mytool --run-everything",
     inject(filler("step %(i)03d completed"), 200,
            "CRITICAL: data corruption detected in shard 7"),
     ["data corruption"]),

    # --- perte VOULUE (controle inverse : le temoin DOIT disparaitre) ---
    ("env: secret (expurgation attendue)", "env",
     inject(filler("VAR_%(i)03d=value%(i)d"), 200,
            "AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI0EXAMPLEKEY"),
     ["!wJalrXUtnFEMI0EXAMPLEKEY"]),  # '!' = on attend l'ABSENCE
]


def main():
    print("=" * 76)
    print("MESURE DE PERTE — token-saver (ppgranger)")
    print("=" * 76)
    lost, ok_count, total = [], 0, 0

    for label, command, output, witnesses in CASES:
        res = compress(command, output)
        st = summarize(output, res.compressed)
        ratio = (1 - res.compressed_len / res.original_len) * 100 if res.original_len else 0
        marks = [ln for ln in res.compressed.splitlines()
                 if "..." in ln and any(w in ln for w in
                                        ("skipped", "truncated", "more", "total lines"))]

        flags = []
        for w in witnesses:
            total += 1
            expect_absent = w.startswith("!")
            needle = w[1:] if expect_absent else w
            present = needle in res.compressed
            good = (not present) if expect_absent else present
            if good:
                ok_count += 1
            else:
                lost.append((label, needle, expect_absent))
            flags.append("%s %r" % ("OK " if good else "!! ", needle[:42]))

        status = "OK" if all(f.startswith("OK") for f in flags) else "PERTE"
        print("\n[%-5s] %s" % (status, label))
        print("         proc=%-13s %6d->%-6d chars (%.1f%%)  lignes %d->%d  marqueurs=%d%s"
              % (res.processor, res.original_len, res.compressed_len, ratio,
                 st["original_lines"], st["compressed_lines"], len(marks),
                 "  [MISMATCH]" if res.is_mismatch else ""))
        for f in flags:
            print("         " + f)
        if VERBOSE:
            print("         --- sortie vue par l'agent ---")
            for ln in res.compressed.splitlines()[:12]:
                print("         | " + ln[:100])

    print("\n" + "=" * 76)
    print("BILAN : %d/%d temoins conformes — %d ecarts" % (ok_count, total, len(lost)))
    for label, w, inv in lost:
        kind = "FUITE (devait disparaitre)" if inv else "PERDU"
        print("  %-26s [%s] %s" % (kind, label, w[:45]))
    print("=" * 76)
    return 1 if lost else 0


if __name__ == "__main__":
    sys.exit(main())
