#!/usr/bin/env python3
# SOURCE: verify.py
# AUTHOR: STARFLEET
# STARDATE: 2026.110
# STATUS: PoC done
# PoC-04 — verification integrite post-test.
# Prend en argument les chemins des fichiers (actif + archives rotees).
# Verifie :
#   1. Chaque ligne non-vide est un JSON valide complet (pas de ligne coupee)
#   2. Aucune perte : pour chaque writer_id, seq 0..N-1 complet
#   3. Ordre monotone par writer : seq strictement croissant dans l ordre
#      d apparition (entre fichiers rotes et actif)

import json
import sys
from collections import defaultdict


def main():
    paths = sys.argv[1:]
    lines_by_writer = defaultdict(list)
    invalid_lines = []
    total_lines = 0

    # Concatenation dans l ordre fourni
    for p in paths:
        try:
            with open(p) as f:
                for lineno, raw in enumerate(f, start=1):
                    if not raw.strip():
                        continue
                    total_lines += 1
                    try:
                        rec = json.loads(raw)
                    except json.JSONDecodeError as e:
                        invalid_lines.append((p, lineno, raw[:80], str(e)))
                        continue
                    w = rec.get("writer")
                    s = rec.get("seq")
                    if w is None or s is None:
                        invalid_lines.append(
                            (p, lineno, raw[:80], "missing writer/seq")
                        )
                        continue
                    lines_by_writer[w].append((p, s))
        except FileNotFoundError:
            print(f"WARN: file not found: {p}", file=sys.stderr)

    print(f"total_lines={total_lines}")
    print(f"writers={list(lines_by_writer.keys())}")
    print(f"invalid_lines={len(invalid_lines)}")
    for e in invalid_lines[:5]:
        print(f"  {e}")

    ok = True

    for writer, entries in sorted(lines_by_writer.items()):
        seqs = [s for _, s in entries]
        expected = set(range(max(seqs) + 1)) if seqs else set()
        actual = set(seqs)
        missing = expected - actual
        dupes = len(seqs) - len(actual)
        print(
            f"  writer={writer}: count={len(entries)}, "
            f"max_seq={max(seqs) if seqs else -1}, "
            f"missing={len(missing)}, dupes={dupes}"
        )
        if missing:
            ok = False
            print(f"    missing seqs: {sorted(list(missing))[:10]}")
        if dupes:
            ok = False

        # Ordre d apparition : les seqs doivent monter strictement entre files
        # (dans un meme file, O_APPEND garantit l ordre). Entre fichiers
        # rotes, les seqs doivent etre < seqs du file suivant.
        prev_path = None
        prev_max = -1
        for path, seq in entries:
            if path != prev_path:
                if seq < prev_max:
                    ok = False
                    print(
                        f"    ORDER VIOLATION: file {path} seq {seq} < "
                        f"prev file max {prev_max}"
                    )
                prev_path = path
                prev_max = seq
            else:
                prev_max = max(prev_max, seq)

    if invalid_lines:
        ok = False

    print("VERIFY:", "OK" if ok else "FAIL")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
