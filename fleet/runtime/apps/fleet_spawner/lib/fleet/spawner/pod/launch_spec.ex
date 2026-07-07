defmodule Fleet.Spawner.Pod.LaunchSpec do
  @moduledoc """
  Pod launch placement and environment — an island of PURE reads, extracted from
  `Fleet.Spawner.Pod`.

  Every function here resolves launch PATHS and ENV VARS from three inputs: the `cap_profile`
  (struct), the `opts` (spawn keyword) and the `pod_dir`. No state mutation, no Port, no timer,
  no FS write: deterministic computation only. The module does NOT read the Pod's `state` and
  calls back NO private of Pod — the Pod resolves its values (cap_profile, opts, pod_dir,
  claude_dir, launcher path…) and passes them as arguments. The cap-profile accessors
  (`name`/`containment`) are read from the SINGLE SOURCE `Fleet.CapProfile` (no re-decoding of
  the field).

  ## Contract (called by `Pod`)

  - `effective_project/2` — EFFECTIVE project (brief `opts[:project]` > static `spec["project"]`).
    Public because shared outside placement (`Pod.CompletedPayload`, bootstrap workspace): single source.
  - `rc_project/2` — project name slugified from `rc_name`, or `nil`. Public because shared
    outside placement (`maybe_checkpoint_seed`): single source.
  - `pod_cwd/3` — cwd seen by the agent. Public because also called by recall (`maybe_recall_restore`).
  - `sandbox_home/2` — intra-pod home. Public because also passed to `McpProvision` (`:projecting` state).
  - `maybe_put_pod_cwd/4`, `maybe_put_sandbox_home/3`, `launch_home/3`, `permission_mode/1`,
    `skills_plugins_env/1`, `pod_mounts_env/2` — env builders, merged by the `:launching` state.
  """

  @doc """
  Pod's EFFECTIVE project: the brief (`opts[:project]`, dynamic) takes precedence over the
  cap-profile's static `spec["project"]`, default empty map. Drives the placement (project cwd)
  AND the end-of-step-run payload — hence the public visibility (single source, no re-derivation
  on the Pod side).
  """
  @spec effective_project(keyword() | nil, Fleet.CapProfile.t()) :: map()
  def effective_project(opts, cap_profile) do
    Keyword.get(opts || [], :project) || get_in(cap_profile.spec, ["project"]) || %{}
  end

  @doc """
  CLEAN project name from `rc_name` (`<project>_<role>`, canonical source sanitized by the
  dispatcher). `nil` if no rc_name (permanent / admin pods → no cwd remap). Shared with the
  checkpoint seed-store.

  Confinement boundary: this `project` is the SOLE derivation of the project name from `rc_name`
  (a dispatch/recall input, untrusted), and it ends up interpolated into paths/segments — cwd
  `/home/<project>`, intra-pod home, seed-store directory. So we require it to be a slug HERE, as
  early as possible: a malformed `rc_name` (`../evil_role`, `a/b_role`) → `nil` (pod with no remap
  nor seed, neutral state) rather than a traversing `project` that would reach a `Path.join`. Single
  source → a single point to hold.
  """
  @spec rc_project(keyword(), Fleet.CapProfile.t()) :: String.t() | nil
  def rc_project(opts, cap_profile) do
    with rc when is_binary(rc) <- Keyword.get(opts, :rc_name),
         role <- Fleet.CapProfile.name(cap_profile),
         stripped when stripped != rc <- String.replace_suffix(rc, "_" <> role, ""),
         true <- Fleet.Slug.valid?(stripped) do
      stripped
    else
      _ -> nil
    end
  end

  @doc """
  cwd SEEN BY THE AGENT inside the pod (= `LCARS_POD_CWD` + base of the recall slug). For a
  PROJECT pod, the agent sees `/home/<project>` (containment: neither human nor pod_id); bwrap
  binds the REAL workspace (`pod_cwd_real`) there. Otherwise (no named project) = the real one.
  The REAL pod_dir does NOT move (stays `/home/<human>/pods/...`) — only the intra-pod CWD is
  remapped. Public because also called by recall (`Scaffold.maybe_recall_restore`).
  """
  @spec pod_cwd(keyword(), Fleet.CapProfile.t(), Path.t()) :: String.t()
  def pod_cwd(opts, cap_profile, pod_dir) do
    cond do
      # Worker projet → /home/<project>.
      project = rc_project(opts, cap_profile) ->
        "/home/#{project}"

      # Orchestrator → its declared RW mount (arch → /home/projects.work). Data-driven (cap-profile).
      rw = first_rw_mount(cap_profile) ->
        rw

      # Permanent / legacy (project without rc_name) → the REAL relocated path (pod_dir → sandbox_home).
      # Home-relocated: sandbox_home=/home/.pod → workspace/home relocated; off → pod_dir = identity.
      true ->
        String.replace_prefix(
          pod_cwd_real(opts, cap_profile, pod_dir),
          pod_dir,
          sandbox_home(cap_profile, pod_dir)
        )
    end
  end

  @doc """
  INTRA-POD home. bwrap → `/home/.pod` (the real pod_dir masked behind it); otherwise (host) →
  the real pod_dir (no relocation). Must match `LCARS_POD_HOME` set by
  `maybe_put_sandbox_home/3`. Public because also passed to `McpProvision` by the `:projecting` state.
  """
  @spec sandbox_home(Fleet.CapProfile.t(), Path.t()) :: String.t()
  def sandbox_home(cap_profile, pod_dir) do
    # "Contained by bwrap?" delegated to the AUTHORITY predicate `CapProfile.bwrap?/1` (no hard-matched
    # "bwrap" literal). bwrap → /home/.pod (sandbox relocation); otherwise (host) → real pod_dir.
    if Fleet.CapProfile.bwrap?(cap_profile), do: "/home/.pod", else: pod_dir
  end

  # An orchestrator's cwd = its 1st RW mount (ALREADY bound via LCARS_POD_MOUNTS, so no bind to
  # create). nil if no rw. Reuses the single accessor cap_profile_mounts (no duplicated logic).
  defp first_rw_mount(cap_profile) do
    cap_profile
    |> cap_profile_mounts()
    |> Enum.find_value(fn m -> if (m["mode"] || m[:mode]) == "rw", do: m["path"] || m[:path] end)
  end

  # REAL (host) workspace under the pod_dir: `pod_dir/workspace` if project cloned, otherwise `pod_dir`.
  # This is the SOURCE of the cwd bind (bwrap maps this real one onto the `/home/<project>` seen by the agent).
  defp pod_cwd_real(opts, cap_profile, pod_dir) do
    case effective_project(opts, cap_profile)["repo_path"] do
      nil -> pod_dir
      _ -> Fleet.Spawner.Pod.Paths.pod_workspace_path(pod_dir)
    end
  end

  @doc """
  Sets the pod's cwd (`LCARS_POD_CWD`, read by bwrap_launch; launcher default `$POD_DIR`). cwd = the
  CODE branch (`<pod_dir>/workspace`) when a project is cloned — the agent starts INSIDE its code,
  not in the bare pod_dir. The DOC branch is alongside (`<pod_dir>/work`). No project → cwd =
  pod_dir (permanent/memory-X pods with no repo). Env builder merged by the `:launching` state.
  """
  @spec maybe_put_pod_cwd(map(), keyword(), Fleet.CapProfile.t(), Path.t()) :: map()
  def maybe_put_pod_cwd(env, opts, cap_profile, pod_dir) do
    env = Map.put(env, "LCARS_POD_CWD", pod_cwd(opts, cap_profile, pod_dir))

    # Project worker: the `/home/<project>` cwd is a REMAP of the real workspace → bwrap must bind it
    # (LCARS_POD_CWD_SRC). Orchestrator (catalogue mount) / permanent / legacy (relocated under the
    # HOME bind) → already bound, no SRC to create.
    if rc_project(opts, cap_profile),
      do: Map.put(env, "LCARS_POD_CWD_SRC", pod_cwd_real(opts, cap_profile, pod_dir)),
      else: env
  end

  @doc """
  Relocates the intra-pod home (bwrap ONLY). `LCARS_POD_HOME=/home/.pod` → bwrap_launch
  masks the real pod_dir behind it (SANDBOX_HOME): the agent sees neither human nor pod_id, and
  `ls /home` shows only the mounts. Host pods (containment none): not relocated (real home).
  Env builder merged by the `:launching` state.
  """
  @spec maybe_put_sandbox_home(map(), Fleet.CapProfile.t(), Path.t()) :: map()
  def maybe_put_sandbox_home(env, cap_profile, pod_dir) do
    # bwrap ONLY (authority predicate): relocates the intra-pod home. Host (none) = real home, nothing to set.
    if Fleet.CapProfile.bwrap?(cap_profile),
      do: Map.put(env, "LCARS_POD_HOME", sandbox_home(cap_profile, pod_dir)),
      else: env
  end

  @doc """
  Pod HOME by containment. host (`"none"`) = the human's real home (claude → native `~/.claude`,
  OAuth refresh); bwrap = pod_dir (ignored under the sandbox anyway). The `claude_dir` is
  RESOLVED on the `LaunchEnv` side (`claude_dir_for/1` — creds, honors the `:claude_dir` config
  override and fails loud if the human's passwd is not found) and passed here: the host HOME = its
  parent (`Path.dirname`).
  """
  @spec launch_home(String.t(), Path.t(), Path.t()) :: Path.t()
  def launch_home("none", _pod_dir, claude_dir), do: Path.dirname(claude_dir)
  def launch_home(_containment, pod_dir, _claude_dir), do: pod_dir

  @doc """
  Pod permission mode: the cap-profile's `spec.invocation.permission_mode`, default `"default"`
  (→ `--permission-mode default`, allow/deny lists ENFORCED). Non-empty → claude_launch passes
  `--permission-mode <mode>`; to re-open the bypass, a cap-profile sets `"bypassPermissions"`.
  Set as `LCARS_PERMISSION_MODE` by `LaunchEnv.build/4`.
  """
  @spec permission_mode(Fleet.CapProfile.t() | term()) :: String.t()
  def permission_mode(%Fleet.CapProfile{spec: spec}),
    do: get_in(spec || %{}, ["invocation", "permission_mode"]) || "default"

  def permission_mode(_), do: "default"

  @doc """
  `LCARS_SKILLS_PLUGINS` = unique plugin names extracted from the QUALIFIED `plugin:skill` skills of
  the cap-profile `spec.knowledge.skills`. Consumed by `bin/bwrap_launch.sh` (RO mount-bind). An
  unqualified skill (no `:`) is NOT a plugin → filtered out. Empty → no env var
  (backward-compatible): returns `%{}` or `%{"LCARS_SKILLS_PLUGINS" => "p1 p2"}`.
  """
  @spec skills_plugins_env(Fleet.CapProfile.t()) :: map()
  def skills_plugins_env(%Fleet.CapProfile{spec: spec}) do
    plugins =
      (spec || %{})
      |> Map.get("knowledge", %{})
      |> Kernel.||(%{})
      |> Map.get("skills", [])
      |> Kernel.||([])
      |> Enum.filter(&(is_binary(&1) and String.contains?(&1, ":")))
      |> Enum.map(&(&1 |> String.split(":", parts: 2) |> hd()))
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    case plugins do
      [] -> %{}
      list -> %{"LCARS_SKILLS_PLUGINS" => Enum.join(list, " ")}
    end
  end

  @doc """
  Serializes `LCARS_POD_MOUNTS` (read by bwrap_launch, one `mode:path` line per mount): the SYSTEM
  mount (launchers dir) ++ the cap-profile's CATALOGUE mounts (`metadata.mounts`).
  `claude_launch_path` is resolved on the Pod side (install config) and passed here.
  """
  @spec pod_mounts_env(Fleet.CapProfile.t(), String.t()) :: String.t()
  def pod_mounts_env(cap_profile, claude_launch_path) do
    mounts_env(system_mounts(claude_launch_path) ++ cap_profile_mounts(cap_profile))
  end

  # CATALOGUE mounts (cap-profile-driven): the world projected into the bwrap sandbox is
  # DECLARED by the cap-profile (`metadata.mounts`), not hardcoded in the launcher. bwrap_launch binds them
  # (RO/RW) at the SAME path, after the /home tmpfs. Empty ⇒ no extra mount (bare worker). Inert for
  # containment: none (host = native access).
  defp cap_profile_mounts(%Fleet.CapProfile{metadata: meta}) when is_map(meta) do
    Map.get(meta, "mounts") || Map.get(meta, :mounts) || []
  end

  defp cap_profile_mounts(_), do: []

  # Universal SYSTEM mount: the launchers dir (= `dirname(claude_launch_path)`) must be VISIBLE
  # inside the bwrap sandbox, because `claude_launch.sh` runs there as PID1. `/usr/local/bin` was so by accident
  # (`--ro-bind /usr`); since the install (`/local/LCARS_v2/bin`) or the dev source (`/home/.../bin`) it must
  # be bound explicitly. Derived from the launcher path (= install parameter) → follows the deployment without hardcode.
  # Goes through the catalogue channel `LCARS_POD_MOUNTS` (applied AFTER `--tmpfs /home` → re-exposes even a
  # `/home/...` path) ⇒ `bwrap_launch.sh` sanctuary INTACT. Skip if already under `/usr` (covered by
  # `--ro-bind /usr` → useless redundant bind; the legacy default `/usr/local/bin` case, incl. its tests).
  defp system_mounts(claude_launch_path) do
    bin = Path.dirname(claude_launch_path)
    if String.starts_with?(bin, "/usr/"), do: [], else: [%{"mode" => "ro", "path" => bin}]
  end

  # Serializes the mounts for bwrap_launch (`LCARS_POD_MOUNTS`): one "mode:path" line per mount.
  defp mounts_env(mounts) when is_list(mounts) do
    mounts
    |> Enum.map(fn m ->
      mode = Map.get(m, "mode") || Map.get(m, :mode)
      path = Map.get(m, "path") || Map.get(m, :path)
      "#{mode}:#{path}"
    end)
    |> Enum.join("\n")
  end

  defp mounts_env(_), do: ""
end
