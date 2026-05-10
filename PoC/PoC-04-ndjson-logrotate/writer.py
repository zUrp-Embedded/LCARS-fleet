#!/usr/bin/env python3
# SOURCE: writer.py
# AUTHOR: STARFLEET
# STARDATE: 2026.110
# STATUS: PoC done
# PoC-04 — writer NDJSON concurrent.
# Un process par writer. Ecrit N lignes JSON avec writer_id + seq + ts_ns en
# O_APPEND + fsync. Signal SIGHUP = reopen FD (apres rotate).

import json
import os
import signal
import sys
import time


def main():
    writer_id = sys.argv[1]
    path = sys.argv[2]
    total = int(sys.argv[3])
    interval_ms = float(sys.argv[4]) if len(sys.argv) > 4 else 2.0

    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o644)

    reopen = {"flag": False}

    def sighup(signum, frame):
        reopen["flag"] = True

    signal.signal(signal.SIGHUP, sighup)

    sent = 0
    while sent < total:
        if reopen["flag"]:
            os.close(fd)
            fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o644)
            reopen["flag"] = False

        line = json.dumps(
            {
                "writer": writer_id,
                "seq": sent,
                "ts_ns": time.monotonic_ns(),
            },
            separators=(",", ":"),
        ) + "\n"

        data = line.encode("utf-8")
        written = os.write(fd, data)
        if written != len(data):
            # theoriquement O_APPEND garantit atomicite ligne entiere tant
            # que taille < PIPE_BUF (4096). Assert si partial write.
            print(
                f"[{writer_id}] PARTIAL WRITE: {written}/{len(data)}",
                file=sys.stderr,
            )
            sys.exit(2)
        os.fsync(fd)
        sent += 1
        time.sleep(interval_ms / 1000.0)

    os.close(fd)
    print(f"[{writer_id}] done, sent={sent}")


if __name__ == "__main__":
    main()
