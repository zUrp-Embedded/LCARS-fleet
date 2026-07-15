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

  require Logger

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

  # Closed claude CLI `--permission-mode` enum. `permission_mode` is a SECURITY setting (governs the
  # allow/deny enforcement) → bound to this list; an out-of-enum value (config typo / forged profile) is
  # NOT handed raw to the launcher.
  @permission_modes ~w(default acceptEdits bypassPermissions plan)

  @doc """
  Pod permission mode: the cap-profile's `spec.invocation.permission_mode`, default `"default"`
  (→ `--permission-mode default`, allow/deny lists ENFORCED). Non-empty → claude_launch passes
  `--permission-mode <mode>`; to re-open the bypass, a cap-profile sets `"bypassPermissions"`.
  Set as `LCARS_PERMISSION_MODE` by `LaunchEnv.build/4`.

  ABSENT → `"default"` (the schema default: unspecified = enforced). A PRESENT-but-out-of-enum value is a
  SECURITY setting that bypassed the schema (config typo / forged profile) — DR-021: it is REFUSED, not
  normalized. Normalizing a typoed `"bypassPermissions"` to `"default"` (or vice-versa) would silently
  CHANGE the security meaning of an invalid profile; instead we RAISE, and `LaunchEnv.build/4`'s try/rescue
  folds it onto a clean `{:error, {:launch_env_unresolved, _}}` → the pod projection FAILS, no launch.
  """
  @spec permission_mode(Fleet.CapProfile.t() | term()) :: String.t()
  def permission_mode(%Fleet.CapProfile{spec: spec}),
    do: bound_permission_mode(get_in(spec || %{}, ["invocation", "permission_mode"]) || "default")

  def permission_mode(_), do: "default"

  defp bound_permission_mode(mode) when mode in @permission_modes, do: mode

  defp bound_permission_mode(other) do
    # DR-021: a present-but-invalid SECURITY setting → REFUSE the projection (raise, caught by
    # LaunchEnv.build/4), never a downstream repair to "default" that changes an invalid profile's meaning.
    raise ArgumentError,
          "LaunchSpec: SECURITY REFUSAL — permission_mode #{inspect(other)} is out of the closed CLI " <>
            "enum #{inspect(@permission_modes)} (schema-bypassed profile). Pod projection refused — " <>
            "an invalid security setting is NOT normalized to a safe default."
  end

  # Closed bwrap mount-mode enum. `mode` is a SECURITY property (RO vs RW = write out of the sandbox).
  # The cap-profile schema bounds `mode ∈ {ro,rw}` at LOAD; this is the eval-boundary check for a
  # schema-bypassed mount.
  @mount_modes ~w(ro rw)

  defp bound_mount_mode(mode) when mode in @mount_modes, do: mode

  defp bound_mount_mode(other) do
    # DR-021: an out-of-enum mount mode (typo `"RW"`, nil) → REFUSE (raise, caught by LaunchEnv.build/4),
    # never a repair to "ro". Normalizing a typoed RW to RO silently changes the security meaning of an
    # invalid profile; refusing fails the projection loud. Twin of `bound_permission_mode`.
    raise ArgumentError,
          "LaunchSpec: SECURITY REFUSAL — mount mode #{inspect(other)} is out of the closed enum " <>
            "#{inspect(@mount_modes)} (schema-bypassed mount). Pod projection refused — an invalid " <>
            "mount mode is NOT normalized to ro."
  end

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
  @spec pod_mounts_env(Fleet.CapProfile.t(), keyword(), String.t()) :: String.t()
  def pod_mounts_env(cap_profile, opts, claude_launch_path) do
    mounts_env(
      system_mounts(claude_launch_path) ++
        cap_profile_mounts(cap_profile) ++ project_ops_mount(opts, cap_profile)
    )
  end

  # The pod's PROJECT work/ops (`/home/projects.work/<project>`) RO — the worker's PROJECT CONTEXT: the other
  # tickets' briefs, the delivered livrables (provenance), the project doctrine. A context-long/unique worker
  # (engineer) EXISTS to hold this context across tickets ; a judge needs it to weigh completeness. Projecting
  # ONLY ITS OWN project (never `/home/projects.work` entire — that is the arch's RW mount, the whole fleet) is
  # the sanctuary rule: give the agent ITS world so it KNOWS, not the neighbours' (noise + over-exposure), and
  # not nothing (famine → it GUESSES the à-côtés = the poison). RO — it reads its doctrine, never corrupts it.
  # Absent for a pod with no project (rc_project nil) or before onboarding (dir missing) → no mount.
  defp project_ops_mount(opts, cap_profile) do
    case project_ops_path(opts, cap_profile) do
      nil -> []
      path -> [%{"mode" => "ro", "path" => path}]
    end
  end

  @doc """
  The pod's PROJECT work/ops path (`<work_root>/<project>`) when it EXISTS, else `nil`. Public: SHARED by the
  mount (`pod_mounts_env`) and the launch env (`LCARS_PROJECT_OPS`, the var the SP reads) so the projected
  world and the pointer the agent is told to read NEVER drift. The dir check is load-bearing: the launcher
  `--ro-bind`s STRICTLY (a missing source crashes the spawn) → an un-onboarded/project-less pod gets no mount.
  `work_root` is a seam (default `Fleet.Layout.work_root()`, a hardcoded global) so the resolution is testable.
  """
  @spec project_ops_path(keyword(), Fleet.CapProfile.t(), Path.t()) :: String.t() | nil
  def project_ops_path(opts, cap_profile, work_root \\ Fleet.Layout.work_root()) do
    case rc_project(opts, cap_profile) do
      nil ->
        nil

      project ->
        path = Path.join(work_root, project)
        if File.dir?(path), do: path, else: nil
    end
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
  # `/home/...` path) ⇒ le sanctuaire du pod reste INTACT. Skip if already under `/usr` (covered by
  # `--ro-bind /usr` → useless redundant bind; the legacy default `/usr/local/bin` case, incl. its tests).
  defp system_mounts(claude_launch_path) do
    bin = Path.dirname(claude_launch_path)
    if String.starts_with?(bin, "/usr/"), do: [], else: [%{"mode" => "ro", "path" => bin}]
  end

  # Serializes the mounts for bwrap_launch (`LCARS_POD_MOUNTS`): one "mode:path" line per mount.
  defp mounts_env(mounts) when is_list(mounts) do
    # `LCARS_POD_MOUNTS` is NEWLINE-DELIMITED (bwrap_launch reads one `mode:path` per line). A `\n`/`\r`
    # in a mount field would INJECT an extra mount line → an unintended (possibly RW) bind into the
    # sandbox = an escape. A newline in a mount field is NEVER legitimate → DR-021: REFUSE the projection
    # (raise), do NOT drop-and-continue. Dropping repaired an invalid (attack-shaped) profile into a
    # launchable one; refusing fails it loud. The raise is caught by `LaunchEnv.build/4`'s try/rescue →
    # `{:error, {:launch_env_unresolved, _}}` → clean pod-projection failure, no launch (the R1-21 concern
    # "a raise crashes the gen_statem" is moot: every call to this sits inside that try/rescue).
    for m <- Enum.filter(mounts, &mount_has_newline?/1) do
      raise ArgumentError,
            "LaunchSpec: SECURITY REFUSAL — newline in a mount field (LCARS_POD_MOUNTS injection): " <>
              "#{inspect(m)}. Pod projection refused — an injecting mount is NOT dropped-and-launched."
    end

    Enum.map_join(mounts, "\n", fn m ->
      # `mode` is bound to the closed enum `{ro, rw}` — an out-of-enum value (config typo `"RW"`, nil) is
      # NOT serialized raw into `LCARS_POD_MOUNTS` (which would delegate RW/RO semantics to bwrap_launch's
      # parse — a permissive read of an unknown mode = a write OUT of the sandbox). DR-021: an out-of-enum
      # mode REFUSES the projection (`bound_mount_mode` raises), it is not repaired to `ro`. The cap-profile
      # schema already bounds `mode` at LOAD (`enum: [ro, rw]`); this is the eval-boundary check for a
      # schema-bypassed (in-memory) mount, twin of `permission_mode`.
      mode = bound_mount_mode(Map.get(m, "mode") || Map.get(m, :mode))
      path = Map.get(m, "path") || Map.get(m, :path)
      "#{mode}:#{path}"
    end)
  end

  # (Plus de clause `mounts_env(_)` fallback : depuis l'ajout du mount projet-ops, `pod_mounts_env` compose
  # TOUJOURS trois listes via `++` → l'entrée est prouvée-liste, le fallback non-liste était mort — dialyzer
  # `pattern_match_cov`. Une non-liste crasherait de toute façon AU `++`, jamais ici.)

  defp mount_has_newline?(m) do
    has_newline?(Map.get(m, "mode") || Map.get(m, :mode)) or
      has_newline?(Map.get(m, "path") || Map.get(m, :path))
  end

  defp has_newline?(v), do: is_binary(v) and String.contains?(v, ["\n", "\r"])
end
