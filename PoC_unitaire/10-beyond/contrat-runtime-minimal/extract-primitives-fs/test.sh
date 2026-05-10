#!/bin/bash
# SOURCE: test.sh
# AUTHOR: STARFLEET
# STARDATE: 2026.110
# STATUS: PROVEN (primitives seules)
set -u
T=$(mktemp -d /tmp/extract-atom-XXXXXX)

python3 - <<PY
import os, sys
D = "$T"

# T1 : rename-after-write sur fichier. Atomicite ext4.
target = f"{D}/target"
tmp = f"{D}/target.tmp"

# ecrire contenu + fsync + rename
with open(tmp, "w") as f:
    f.write("V1\n")
    f.flush()
    os.fsync(f.fileno())
os.rename(tmp, target)
fd = os.open(D, os.O_RDONLY)
os.fsync(fd)
os.close(fd)

assert open(target).read() == "V1\n"
print("[PASS] rename-after-write fichier: target contient V1")

# T2 : rename dir avec fsync parent
staging = f"{D}/staging"
final = f"{D}/final"
os.makedirs(staging)
with open(f"{staging}/file.txt", "w") as f:
    f.write("content\n")
    os.fsync(f.fileno())
os.rename(staging, final)
fd = os.open(D, os.O_RDONLY)
os.fsync(fd)
os.close(fd)
assert os.path.isdir(final)
assert not os.path.exists(staging)
assert open(f"{final}/file.txt").read() == "content\n"
print("[PASS] rename-after-write repertoire: staging->final atomique")

# T3 : invariant observable - reader ouvert pendant rename voit l ancien
import subprocess
f0 = open(target)
# modifier target : write tmp + rename
with open(tmp, "w") as f:
    f.write("V2\n")
    os.fsync(f.fileno())
os.rename(tmp, target)
# reader a encore file descriptor sur l ancien inode
f0.seek(0)
assert f0.read() == "V1\n", "reader open pre-rename doit voir V1"
f0.close()
# reader re-ouvre : voit V2
assert open(target).read() == "V2\n"
print("[PASS] reader ouvert pre-rename voit l ancien (inode preserve)")
PY
RC=$?
rm -rf "$T"
exit $RC
