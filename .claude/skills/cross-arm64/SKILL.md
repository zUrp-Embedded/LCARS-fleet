---
name: cross-arm64
context: fork
description: >
  Cross-compilation workflow for Raspberry Pi (aarch64 / armhf) from Ubuntu / WSL.
  Load when working on ARM cross-compilation, RPi builds, aarch64-linux-gnu,
  CMake toolchain files, sysroot setup, CFLAGS_CPU, .env.cross, deploy to RPi,
  or any embedded Linux ARM build workflow. Reads a project profile (YAML) to
  adapt to the active project's paths, constraints, and fleet setup.
allowed-tools:
  - Bash
  - Read
  - Write
  - Edit
  - Glob
  - Grep
when_to_use: >
  Use when the user works on ARM cross-compilation, RPi builds, aarch64 targets,
  CMake toolchain files, sysroot setup, or embedded Linux ARM workflows.
  Examples: 'cross-compile for pi', 'build arm64', 'deploy to raspberry pi',
  'setup sysroot', 'cmake toolchain arm'.
---

# Skill: cross-compile-arm64

**Step 0 — load project profile**: check `cross-arm64.yaml` at project root; if absent,
check `~/.claude/skills/cross-arm64/profiles/`. Read it before using any path, constraint,
or fleet value below — profile overrides all defaults.

## Environment

| Variable | Source | Description |
|---|---|---|
| `CROSS_COMPILE` | `~/.env.cross` | Toolchain triplet prefix |
| `SYSROOT` | `~/.env.cross` | Target sysroot path |
| `CFLAGS_CPU` | `~/.env.cross` (from `~/.rpi-target`) | CPU flags for target |
| `CC`, `CXX` | `~/.env.cross` | Compiler wrappers |
| `PKG_CONFIG_*` | `~/.env.cross` | pkg-config target isolation |

```bash
which aarch64-linux-gnu-gcc || echo "ERROR: toolchain not found — run provisioning"
source ~/.env.cross
cat ~/.rpi-target                        # active target: zero2 | pi4 | pi5
# change target: rpi-target-set <zero2|pi4|pi5> && source ~/.env.cross
```

## Toolchain installation (fresh environment only)

```bash
sudo apt install -y crossbuild-essential-arm64
# Multiarch — for apt-based sysroot libs:
sudo dpkg --add-architecture arm64 && sudo apt update
sudo apt install -y lib<name>-dev:arm64
```

## Sysroot strategies

**A — rsync from a live Pi** (most faithful):
```bash
rsync -avz pi@<PI_IP>:/lib/          $SYSROOT/lib/
rsync -avz pi@<PI_IP>:/usr/lib/      $SYSROOT/usr/lib/
rsync -avz pi@<PI_IP>:/usr/include/  $SYSROOT/usr/include/
symlinks -cr $SYSROOT    # fix absolute symlinks broken by rsync
```

**B — mount Pi image** (fleet: `rpi-img-mount.sh` available in `~/.local/bin/`):
```bash
rpi-img-mount.sh mount image.img /mnt/rpi-rootfs
```

## CMake

Toolchain file is embedded in the project repo (see profile: `toolchain_file`).
Build dirs are per-component (see profile: `build_dirs`).

```bash
source ~/.env.cross
cmake -S <project> -B <build-dir> \
  -DCMAKE_TOOLCHAIN_FILE=<profile:toolchain_file> \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_SYSROOT=$SYSROOT \
  -DCMAKE_C_FLAGS="$CFLAGS_CPU" \
  -DCMAKE_CXX_FLAGS="$CFLAGS_CPU"

cmake --build <build-dir> -j<profile:make_jobs>   # respect WSL memory constraint if set
```

## Verify binary

```bash
file <binary>                                       # must show: ELF 64-bit, aarch64
aarch64-linux-gnu-readelf -d <binary> | grep NEEDED # check shared deps
size <binary>                                       # footprint vs profile:constraints.ram_mb
```

## Deploy

```bash
rsync -avz <binary> <profile:deploy.user>@<profile:deploy.target_ip>:<profile:deploy.dest>
ssh <user>@<target-ip> "sudo systemctl restart <profile:deploy.service>"
ssh <user>@<target-ip> "journalctl -u <service> -f"
# Target IP: see project-refs.md (fleet shared — not hardcoded in profile)
```

## Common issues

| Symptom | Cause | Fix |
|---|---|---|
| `cannot find -l<lib>` | Missing sysroot lib | `apt install lib<x>-dev:arm64` or rsync from Pi |
| `SIGILL` on target | Wrong CPU flags | `cat ~/.rpi-target`, re-source `~/.env.cross`, verify `CFLAGS_CPU` |
| `NOTFOUND` in CMakeCache | Stale cache | `rm -rf <build-dir>/`, reconfigure with `:PATH`/`:FILEPATH` typed `-D` flags |
| Absolute symlinks broken | rsync sysroot | `symlinks -cr $SYSROOT` |
| Wrong arch in binary | Toolchain not active | Check `CC` var, re-source `~/.env.cross` |
| "Exec format error" on Pi | Arch mismatch | `file <binary>` vs `uname -m` on Pi |
