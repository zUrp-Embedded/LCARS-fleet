<a id="top"></a>
# build-cycle.sh — Incremental build workflow


> 🇫🇷 [Version française](../#04_build-cycle.md)

Script: `fleet/build-cycle.sh` (deployed to `~/.local/bin/` of builder via `deploy.sh`).

**Sections** — [📖 Usage](#usage) · [🛡️ Preservation](#preservation-rules) · [🔄 CMake](#incremental-cmake) · [🔗 Workflow](#workflow-dev-builder) · [🚨 Escalation](#escalation-paths) · [🍴 Fork point](#fork-post-install) · [⚠️ Limitations](#limitations)

<a id="usage"></a>
## 📖 Usage

*The five build modes, from fastest incremental to full INDI rebuild.*

```bash
# Default: rebuild ostmodules + inject only (5–10 min)
build-cycle.sh

# Rebuild ostserver + ostmodules + inject (10–15 min)
build-cycle.sh --rebuild-ost

# Full rebuild of all code except INDI (20–30 min)
build-cycle.sh --rebuild-full

# Rebuild INDI (rare, ~30 min) — includes everything
build-cycle.sh --rebuild-indi

# Rebuild image only, without recompiling code (pi-gen only, 45+ min)
build-cycle.sh --image-only
```

---

<a id="preservation-rules"></a>
## 🛡️ Preservation rules

*Which components are preserved or rebuilt for each flag.*

| Component | Default | `--rebuild-ost` | `--rebuild-full` | `--rebuild-indi` | `--image-only` |
|---|---|---|---|---|---|
| INDI (build-indi, indi-staging) | KEEP | KEEP | KEEP | **REBUILD** | KEEP |
| ostserver (build-ostserver, ost staging partial) | KEEP | **REBUILD** | **REBUILD** | **REBUILD** | KEEP |
| ostmodules (build-ostmodules, ost-staging append) | **REBUILD** | **REBUILD** | **REBUILD** | **REBUILD** | KEEP |
| pi-gen image (img-extract, pi-gen-*) | Use existing | Use existing | **REBUILD** | **REBUILD** | **REBUILD** |
| artifacts (commons/artifacts/arm64/) | Update | Update | Update | Update | No update |

[↑ table of contents](#top)

---

<a id="incremental-cmake"></a>
## 🔄 Incremental CMake logic

*CMake cache is preserved between cycles; stale cache requires a manual rm -rf to recover.*

The script preserves `build-ostmodules/` between cycles unless `--rebuild-full` is used. CMake reuses the cache and recompiles only modified sources.

**If CMakeCache.txt becomes stale** (e.g. FindOSTSERVER fails with NOTFOUND):
```bash
rm -rf /home/builder/build-ostmodules/
build-cycle.sh  # reconfigures from scratch
```

Typical root cause: `:PATH`/`:FILEPATH` values cached as `NOTFOUND` from a previous attempt. `-D` CLI flags do not override stale FILEPATH entries — only an rm -rf of the cache resolves this.

[↑ table of contents](#top)

---

<a id="workflow-dev-builder"></a>
## 🔗 Workflow dev → builder

*Four-step pipeline from dev commit to compressed RPi image in commons/artifacts.*

1. Dev pushes code to `commons/cDs/ostmodules.git`
2. builder runs `build-cycle.sh` (auto pull in step 1)
3. Artifacts delivered to `/home/commons/artifacts/arm64/`
4. Image injected and compressed → `/home/commons/artifacts/rpi-image/image-cds-ost-YYYYMMDD.img.xz`

Typical iteration time: **5–10 min per code change** (vs 60+ min full rebuild).

[↑ table of contents](#top)

---

<a id="escalation-paths"></a>
## 🚨 Escalation paths

*Known failure modes and their resolution, including out-of-scope escalation via fleet-blocker.*

| Issue | Action |
|---|---|
| CMakeCache stale | `rm -rf /home/builder/build-ostmodules/`, re-run |
| inject-image fails | Check mount `/mnt/rpi-rootfs/`, or rerun `inject-image.sh` manually |
| INDI rebuild needed | Use `phase2.sh` (INDI not yet integrated into build-cycle.sh) |
| Out of scope | `fleet-blocker.sh "out-of-scope" "<desc>"` → escalate to StarFleet |

[↑ table of contents](#top)

---

<a id="fork-post-install"></a>
## 🍴 Post-install fork point — instance type

*`post-install.sh` dispatches to each instance type's specific module at provisioning time.*

`post-install.sh` reads `~/.wsl-instance-type` and branches to the specific module `post-install-<type>.sh`.
Validated whitelist: `base|dev|builder|steward|engineer|qualifier`. Fallback to `base` + warn on unknown value.

For builder: `post-install-builder.sh` configures the cross-toolchain, environment variables
(`MAX_THINKING_TOKENS`, `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE`) and ARM64 skills.
A rebuild (`Instanciator.ps1`) directly produces a functional builder instance without manual configuration.

> [!NOTE]
> The `base` fallback on unknown type is intentional: it ensures a misconfigured instance remains functional (normal shell) without gaining access to builder- or qualifier-specific tools.

[↑ table of contents](#top)

---

<a id="limitations"></a>
## ⚠️ Known limitations (TODO build-tools)

*Two partially implemented modes still delegate to phase2.sh pending full integration.*

- `--rebuild-indi`: placeholder `exit 1`, references phase2.sh
- `--image-only` / `--rebuild-full`: pi-gen not integrated, references phase2.sh

[↑ table of contents](#top)
