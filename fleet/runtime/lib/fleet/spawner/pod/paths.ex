defmodule Fleet.Spawner.Pod.Paths do
  @moduledoc """
  Resolution of the pod substrate's PATHS — a PURE-computation island extracted from `Fleet.Spawner.Pod`.

  A single role: derive, from a `pod_id` (+ the cap-profile scope + `opts`/config overrides), a pod's
  two disk footprints and their scannable root:

  - the **pod_dir** (`<pod_dir_root>/pod_<pod_id>` — git clone + `.lcars`/`.claude`/`issues`),
  - the recovery **state.json** (`<state_fs_root>/<scope>/<pod_id>/state.json`) and its root.

  Every value descends from the HOME of the human who launches the fleet (`runtime_home/0` =
  `System.user_home!()`, fleet-under-the-human) except an explicit override (`opts[:pod_dir_root]` /
  `opts[:state_fs_root]` or the `:fleet_spawner` config). No state, no Port, no timer, no FS write:
  deterministic resolution only. The module does NOT read the Pod's `state` nor call back into a Pod
  private — the Pod passes it `pod_id`/`cap_profile`/`opts` as arguments. Depends on
  `Fleet.CapProfile.lifetime_scope/2` (single source of the scope) and the `:fleet_spawner` config,
  already deps of the app (no cycle).

  ## Contract (called by `Pod`)

  - `pod_dir/2` (PUBLIC, also called by `PodWarden`) — a pod_dir reconstructible from the pod_id ALONE,
    which makes scan-based GC possible (the warden derives the pod_dir to erase from the tombstone, without the cap_profile).
  - `state_fs_root/0` (PUBLIC, also swept by `PodWarden`) — scannable root of the `state.json` files.
  - `pod_dir_for/2`, `state_fs_path_for/3`, `runtime_home/0` — resolutions called by `Pod`
    (`initial_state`, `clear_terminal_snapshot`) and `Pod.LaunchEnv` (`claude_dir` → `runtime_home/0`);
    public because they are crossed from those modules.
  """

  # A pod's deliverable workspace = `<pod_dir>/workspace` (under `$POD_DIR`, bwrap-bound RW).
  # Subdir centralized HERE — single authority for the placement convention (the
  # `Fleet.Spawner.pod_workspace_path/1` facade delegates; the `Pod.*` islands call it directly).
  # `ProjectBootstrap.Clone` keeps its copy (Ring 1 cannot depend on spawner without a
  # spawner⇄bootstrap cycle) BUT it RETURNS the computed workspace → authoritative producer.
  @pod_workspace_subdir "workspace"

  @doc """
  Deliverable workspace from a known `pod_dir`: `<pod_dir>/workspace`. PURE computation — single
  authority for the placement convention (the `"workspace"` literal lives only here on the spawner side).
  Called by the facade (`Fleet.Spawner.pod_workspace_path/1`),
  `Pod.LaunchSpec` (cwd bind) and `Pod.CompletedPayload` (payload's `workspace` key).
  """
  @spec pod_workspace_path(Path.t()) :: Path.t()
  def pod_workspace_path(pod_dir) when is_binary(pod_dir),
    do: Path.join(pod_dir, @pod_workspace_subdir)

  @doc """
  A pod's pod_dir: `<pod_dir_root>/pod_<pod_id>` (full git clone + `.lcars`/`.claude`/`issues`).
  The cap_profile does NOT enter the computation — the pod_dir depends only on the pod_id and the base —
  so it is reconstructible from the pod_id ALONE. This is what makes scan-based GC possible: the `PodWarden`
  finds a tombstone (state.json) by its pod_id and derives from it the pod_dir to erase, without ever
  having the cap_profile out of context. Config `:fleet_spawner, :pod_dir_root`, default `~/pods`.
  """
  @spec pod_dir(String.t(), keyword()) :: String.t()
  def pod_dir(pod_id, opts \\ []) when is_binary(pod_id), do: pod_dir_for(pod_id, opts)

  @doc """
  pod_dir with an explicit override: `opts[:pod_dir_root]` wins over the
  `:fleet_spawner, :pod_dir_root` config, otherwise default `~/pods` (the pod lives UNDER THE HUMAN'S
  HOME, `0700`, OS-isolated for free — the home already ENCODES the human). `pod_<id>` = stable name
  (pod_id = recovery key, stable for `--resume`). Called by `Pod` (`initial_state`) and
  `StateFs.clear_terminal_snapshot/3`.
  """
  @spec pod_dir_for(String.t(), keyword()) :: String.t()
  def pod_dir_for(pod_id, opts) do
    Path.join(pod_dir_root(opts), "pod_#{pod_id}")
  end

  @doc """
  Base under which EVERY pod_dir lives (`opts[:pod_dir_root]` > `:fleet_spawner, :pod_dir_root` config >
  `~/pods`). Exposed as the SINGLE root authority so `StateFs.rm_terminal_artifacts` can verify a
  pod_dir is strictly UNDER it before an `rm_rf` (path-escape guard) — resolved the SAME way the pod_dir
  was built, so the check honours the same opts/config override.
  """
  @spec pod_dir_root(keyword()) :: String.t()
  def pod_dir_root(opts \\ []) do
    Keyword.get(opts, :pod_dir_root) ||
      Application.get_env(:fleet_spawner, :pod_dir_root) ||
      Path.join(runtime_home(), "pods")
  end

  @doc """
  Path of a pod's recovery `state.json`: `<state_fs_root>/<scope>/<pod_id>/state.json`,
  scope derived from the cap-profile's `lifetime_scope` (`pipe` → `pipes`, `run` → `runs`, otherwise
  `pods`). `opts[:state_fs_root]` (per-spawn override, tests) wins over the global root.
  Called by `Pod` (`initial_state`) and `StateFs.clear_terminal_snapshot/3`.
  """
  @spec state_fs_path_for(String.t(), Fleet.CapProfile.t(), keyword()) :: String.t()
  def state_fs_path_for(pod_id, cap_profile, opts) do
    scope = scope_for(Fleet.CapProfile.lifetime_scope(cap_profile, nil))
    Path.join([state_fs_root_for(opts), scope, pod_id, "state.json"])
  end

  @doc """
  State root HONOURING an `opts[:state_fs_root]` override (per-spawn/tests), else the global
  `state_fs_root/0`. The root authority used by `state_fs_path_for/3` AND by
  `StateFs.rm_terminal_artifacts` for its path-escape guard (same resolution as the built path).
  """
  @spec state_fs_root_for(keyword()) :: String.t()
  def state_fs_root_for(opts), do: Keyword.get(opts, :state_fs_root, state_fs_root())

  @doc """
  FS root of the `state.json` snapshots (each pod: `<root>/<scope>/<pod_id>/state.json`, scope ∈
  {pipes,runs,pods}). This is the SCANNABLE base for enumerating the tombstones — the state-side
  counterpart of `PodTmux.sock_base/0` on the sockets side. Config `:fleet_spawner, :state_fs_root`,
  default `~/.lcars/state`. Public because the `PodWarden` sweeps it to GC orphan pod_dirs. An
  `opts[:state_fs_root]` (per-spawn override) wins at the `state_fs_path_for` call-site, but the warden
  sweeps the GLOBAL root (config) — spawns with a custom root (tests) are out of its reach by construction.
  """
  @spec state_fs_root() :: String.t()
  def state_fs_root,
    do: Application.get_env(:fleet_spawner, :state_fs_root, default_state_fs_root())

  # Fleet under the human: the pods' FS state follows the human's HOME (= the runtime user),
  # like `~/pods` (pod_dir) and `~/.lcars/workspaces`, NOT `/var/lib/lcars`.
  # Override via env `LCARS_STATE_FS_ROOT` (→ `config :fleet_spawner, :state_fs_root`).
  # Unresolvable HOME = broken runtime → fail-loud via `runtime_home()` (the single local source,
  # `System.user_home!()`), never a fabricated path: the .lcars state must not scatter silently.
  defp default_state_fs_root,
    do: Path.join(Fleet.Layout.state_dir(), "state")

  defp scope_for("pipe"), do: "pipes"
  defp scope_for("run"), do: "runs"
  # `forever` shares the FS scope `pods/` with `one_shot` (both = pods with
  # their own lifetime).
  defp scope_for("forever"), do: "pods"
  defp scope_for(_), do: "pods"

  @doc """
  Runtime human's HOME. The human running the fleet = the user of the runtime process itself:
  the ONLY users of the instance are the fleet users → the current user IS the human. No config,
  no literal default (a default would mask a wiring hole instead of making it fail). The pod, a child
  of the runtime (Port/tmux), INHERITS that UID → runs in the human's home, binds their creds. If
  someone else installs LCARS tomorrow, it is THEIR user that launches, THEIR home — nothing to
  hardcode. Fail-loud if HOME/user is unresolvable (`System.user_home!()` raises — impossible in
  practice, but never silently caught).
  """
  @spec runtime_home() :: String.t()
  def runtime_home, do: System.user_home!()
end
