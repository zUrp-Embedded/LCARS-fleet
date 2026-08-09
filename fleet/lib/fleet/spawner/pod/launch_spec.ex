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
  - `rc_project/2` — project slug of the pod (opt `:project_slug`), or `nil`. Public because shared
    outside placement (`maybe_checkpoint_seed`): single source.
  - `pod_cwd/3` — cwd seen by the agent. Public because also called by recall (`maybe_recall_restore`).
  - `sandbox_home/2` — intra-pod home. Public because also passed to `McpProvision` (`:projecting` state).
  - `maybe_put_pod_cwd/4`, `maybe_put_sandbox_home/3`, `launch_home/3`, `permission_mode/1`,
    `skills_plugins_env/1`, `pod_mounts_env/2` — env builders, merged by the `:launching` state.
  - `remote_control?/1` — EFFECTIVE Desktop visibility, the ONE authority. Public because its three
    consumers sit in three places (slot capture, slot resume, and the vendor launcher through
    `LCARS_POD_REMOTE_CONTROL`); a second derivation is what it exists to prevent.
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
  CLEAN project name of the pod, read from the EXPLICIT `:project` opt. `nil` when the caller names
  no project (permanent / admin pods → no cwd remap). Shared with the checkpoint seed-store.

  Confinement boundary: this `project` is a dispatch/recall input (untrusted) that ends up
  interpolated into paths/segments — cwd `/home/<project>`, intra-pod home, seed-store directory.
  So we require it to be a slug HERE, as early as possible: a malformed value (`../evil`, `a/b`) →
  `nil` (pod with no remap nor seed, neutral state) rather than a traversing `project` that would
  reach a `Path.join`. Single source → a single point to hold.

  ⚠ Its consumer `other_face_reference_path/3` builds a HOST path (`<face_root>/<project>`) whose
  documented authority is `Fleet.Layout.project_name/1`, not the slug. The two derivations differ on `_`, `.` and
  uppercase, so this would place a pod on a directory that does not exist. It does NOT, and the
  reason is a charset and not a contract: every onboarding entry point validates the project name
  against `^[a-z0-9][a-z0-9-]*[a-z0-9]$`, strictly inside what the slug preserves, so a project
  that HAS a directory has a name on which both derivations agree. Pinned as an invariant in
  `Fleet.LayoutTest` — widen that charset and the test parts company before a pod does.
  """
  @spec rc_project(keyword(), Fleet.CapProfile.t()) :: String.t() | nil
  def rc_project(opts, _cap_profile) do
    # The key is `:project_slug`, NOT `:project`: `:project` is ALREADY the project MAP of the brief
    # (`effective_project/2` — repo_path / base_branch / repo). Two different objects, two keys. A
    # slug parked under `:project` is silently swallowed by the map (last writer wins) and lands
    # here as a non-binary → `nil` → a pod with no remap, which is the exact silence below.
    #
    # READ, never re-parsed (2026-08-03). The slug is an EXPLICIT input now: every caller that
    # names a pod already holds it — it is what `rc_name` was BUILT from. Deriving it back out of
    # the label made the label a load-bearing structure: its format was frozen by this parse, so
    # adding the ticket number to the Desktop name (`tetris#42_engineer`) would have made
    # `Slug.valid?` fail → `nil` → a pod with NO cwd remap and NO seed, silently. One string was
    # doing two jobs; now the label is a label.
    #
    # No fallback to the old parse ON PURPOSE: it would not have saved a missed call site (the
    # parse fails on the new format anyway), it would only have hidden WHICH site was missed. The
    # refusal lives at the spawn choke point instead, where the other structural guards are.
    case Keyword.get(opts, :project_slug) do
      p when is_binary(p) ->
        if Fleet.Slug.valid?(p), do: p, else: nil

      _ ->
        nil
    end
  end

  @doc """
  Returns the cwd visible to the agent.

  Project workers use `/home/<project>`, orchestrators use their first RW mount, and other pods use
  their workspace path relocated under the sandbox home when applicable.
  """
  @spec pod_cwd(keyword(), Fleet.CapProfile.t(), Path.t()) :: String.t()
  def pod_cwd(opts, cap_profile, pod_dir) do
    cond do
      project = rc_project(opts, cap_profile) ->
        "/home/#{project}"

      rw = first_rw_mount(cap_profile, opts) ->
        rw

      true ->
        String.replace_prefix(
          pod_cwd_real(opts, cap_profile, pod_dir),
          pod_dir,
          sandbox_home(cap_profile, pod_dir)
        )
    end
  end

  @doc """
  Returns `/home/.pod` for bwrap containment and the real pod directory otherwise.
  """
  @spec sandbox_home(Fleet.CapProfile.t(), Path.t()) :: String.t()
  def sandbox_home(cap_profile, pod_dir) do
    if Fleet.CapProfile.bwrap?(cap_profile), do: "/home/.pod", else: pod_dir
  end

  defp first_rw_mount(cap_profile, opts) do
    (opts_mounts(opts) ++ cap_profile_mounts(cap_profile))
    |> Enum.find_value(fn m -> if (m["mode"] || m[:mode]) == "rw", do: m["path"] || m[:path] end)
  end

  defp pod_cwd_real(opts, cap_profile, pod_dir) do
    case effective_project(opts, cap_profile)["repo_path"] do
      nil -> pod_dir
      _ -> Fleet.Spawner.Pod.Paths.pod_workspace_path(pod_dir)
    end
  end

  @doc """
  Adds the agent-visible cwd and, for project workers, its real bind source to the launch environment.
  """
  @spec maybe_put_pod_cwd(map(), keyword(), Fleet.CapProfile.t(), Path.t()) :: map()
  def maybe_put_pod_cwd(env, opts, cap_profile, pod_dir) do
    env = Map.put(env, "LCARS_POD_CWD", pod_cwd(opts, cap_profile, pod_dir))

    if rc_project(opts, cap_profile),
      do: Map.put(env, "LCARS_POD_CWD_SRC", pod_cwd_real(opts, cap_profile, pod_dir)),
      else: env
  end

  @doc """
  Adds `LCARS_POD_HOME` for bwrap pods; host pods retain their native home.
  """
  @spec maybe_put_sandbox_home(map(), Fleet.CapProfile.t(), Path.t()) :: map()
  def maybe_put_sandbox_home(env, cap_profile, pod_dir) do
    if Fleet.CapProfile.bwrap?(cap_profile),
      do: Map.put(env, "LCARS_POD_HOME", sandbox_home(cap_profile, pod_dir)),
      else: env
  end

  @doc """
  Returns the native human home for host containment and the pod directory otherwise.
  """
  @spec launch_home(String.t(), Path.t(), Path.t()) :: Path.t()
  def launch_home("none", _pod_dir, claude_dir), do: Path.dirname(claude_dir)
  def launch_home(_containment, pod_dir, _claude_dir), do: pod_dir

  # DR-021
  @permission_modes ~w(default acceptEdits bypassPermissions plan)

  @doc """
  Returns the profile's closed-enum Claude permission mode, defaulting to `"default"` when absent.

  A present value outside the enum raises instead of being normalized.
  """
  @spec permission_mode(Fleet.CapProfile.t() | term()) :: String.t()
  def permission_mode(%Fleet.CapProfile{spec: spec}),
    do: bound_permission_mode(get_in(spec || %{}, ["invocation", "permission_mode"]) || "default")

  def permission_mode(_), do: "default"

  @doc """
  EFFECTIVE Desktop visibility of a pod — the ONE authority, obeyed by all three consumers.

  Visibility used to be derived twice, independently: `Fleet.CapProfile.remote_control?/1` on the
  Elixir side (the Desktop-slot capture and the slot resume) and a `jq` read of the same field in
  `claude_launch.sh` (the `--remote-control` flag and `remoteControlAtStartup`). Two derivations of
  one fact agree only as long as nothing tries to change it — and the moment something does, the
  half that is not reached produces a pod VISIBLE in Desktop whose slot is never captured nor
  resumed: visible now, a new slot every boot, which is the "12 archs" bug wearing a new hat.

  So this is the single site, and the launcher stops deriving: `LaunchEnv.build/4` exports the
  answer as `LCARS_POD_REMOTE_CONTROL` and the shell obeys it.

  The declaration is the FLOOR; the fleet's debug mode (`fleet_v2 start --debug` →
  `:debug_visibility`) is the only thing above it, and it is MONOTONE by construction — an `or`,
  never a replacement. A mode that could also CLOSE would let an operator ask for observability and
  lose a pod they had; and a mode that lies in either direction is worse than no mode, because the
  operator stops looking. So: debug can add a window, it can never take one away.

  The mode is fixed for the fleet's whole life, deliberately: this is read at LAUNCH, so it governs
  the pods spawned while it is on and does not retro-fit the ones already up. A pod's visibility is
  therefore a property of its own launch, not a fleet-wide state that shifts under it.
  """
  @spec remote_control?(Fleet.CapProfile.t() | term()) :: boolean()
  def remote_control?(cap_profile) do
    Fleet.CapProfile.remote_control?(cap_profile) or Fleet.Spawner.debug_visibility?()
  end

  @doc """
  Does this pod compress its Bash output before it enters the agent's context? THE authority.

  Composed by an **AND**, and the contrast with `remote_control?/1` one function above is the whole
  design: that one is an `or` because debug may only ADD a window, this one is an `and` because the
  fleet may only REMOVE compression. Both are monotone, in opposite directions, and the direction is
  forced by what is at stake rather than chosen — visibility that fails closed costs an operator a
  pane they had; compression that fails open costs an agent an error line it never saw, on a defect
  the agent then reports as absent.

  So a role that declared `false` keeps it whatever the fleet says, and a fleet knob set to `false`
  cuts every pod whatever the profiles say. Neither can force the lossy direction on the other.

  Read at LAUNCH, like its neighbour: a pod's compression is a property of its own launch, not a
  fleet-wide state that shifts under a pod already running.
  """
  @spec output_compression?(Fleet.CapProfile.t() | term()) :: boolean()
  def output_compression?(cap_profile) do
    Fleet.CapProfile.output_compression?(cap_profile) and
      Fleet.Spawner.output_compression_allowed?()
  end

  defp bound_permission_mode(mode) when mode in @permission_modes, do: mode

  defp bound_permission_mode(other) do
    raise ArgumentError,
          "LaunchSpec: SECURITY REFUSAL — permission_mode #{inspect(other)} is out of the closed CLI " <>
            "enum #{inspect(@permission_modes)} (schema-bypassed profile). Pod projection refused — " <>
            "an invalid security setting is NOT normalized to a safe default."
  end

  @mount_modes ~w(ro rw)

  defp bound_mount_mode(mode) when mode in @mount_modes, do: mode

  defp bound_mount_mode(other) do
    raise ArgumentError,
          "LaunchSpec: SECURITY REFUSAL — mount mode #{inspect(other)} is out of the closed enum " <>
            "#{inspect(@mount_modes)} (schema-bypassed mount). Pod projection refused — an invalid " <>
            "mount mode is NOT normalized to ro."
  end

  @doc """
  Returns `LCARS_SKILLS_PLUGINS` with unique plugin prefixes from qualified `plugin:skill` entries.

  Unqualified skills are ignored; an empty result returns no environment entry.
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
  `LCARS_SKILLS_PATHS` = the FILTERED plain-skill dirs to bind RO into the pod's
  `~/.claude/skills/` (BL-6-22 — the delivery half `filter_skills` never had). NEWLINE-delimited
  `name:abs_path` entries — the `LCARS_POD_MOUNTS` pattern, NOT the plugins one above: plugins
  carry bare NAMES, these carry PATHS, and a space-separated format would shatter on a skills
  root containing a space. The first `:` separates (a skill name is a `Fleet.Slug`, no `:` in
  the alphabet), so a path containing `:` stays whole. The name is `Path.basename(path)` —
  legitimate BY CONSTRUCTION (`filter_skills` builds each path as `Path.join(skills_root, name)`;
  do NOT "improve" filter_skills to return tuples — that is the `SPBuilder.Composer` behaviour
  contract, with stubs and tests on it). Empty → `%{}` (no var, no bind loop).
  """
  @spec skills_paths_env([Path.t()]) :: map()
  def skills_paths_env([]), do: %{}

  def skills_paths_env(paths) when is_list(paths) do
    # DR-021, same refusal as `mounts_env`: a `\n`/`\r` INSIDE a path would INJECT an extra bind
    # line into the sandbox projection → REFUSE the projection (raise, caught by LaunchEnv.build's
    # try/rescue → clean pod-projection failure), never drop-and-launch.
    case Enum.find(paths, &String.match?(&1, ~r/[\n\r]/)) do
      nil ->
        :ok

      injecting ->
        raise ArgumentError,
              "LaunchSpec: SECURITY REFUSAL — newline in a skill path (LCARS_SKILLS_PATHS " <>
                "injection): #{inspect(injecting)}. Pod projection refused — an injecting " <>
                "bind is NOT dropped-and-launched."
    end

    %{
      "LCARS_SKILLS_PATHS" =>
        Enum.map_join(paths, "\n", fn path -> "#{Path.basename(path)}:#{path}" end)
    }
  end

  @doc """
  Serializes the system, profile, spawn and other-face mounts for bwrap.

  Earlier entries win on duplicate paths. Modes must be `ro` or `rw`; newline-bearing fields raise.

  THE PROJECT'S OPS TREE IS NOT HERE, and its absence is the point. Every project pod used to carry
  a read-only bind of `<ops_root>/<project>` — the runtime's own record: what was asked, what was
  judged, what was proven. It was there so that ONE role could read ONE file out of it, and the
  brief and the judging criterion now travel as text instead. A producer holding the ledger its own
  work is scored in is a hazard that buys nothing once the text is in its hands. The architect keeps
  the tree, through its explicit spawn `mounts:`, because reporting on the work IS its function.
  """
  @spec pod_mounts_env(Fleet.CapProfile.t(), keyword(), String.t()) :: String.t()
  def pod_mounts_env(cap_profile, opts, claude_launch_path) do
    (system_mounts(claude_launch_path) ++
       cap_profile_mounts(cap_profile) ++
       opts_mounts(opts) ++
       other_face_reference_mount(opts, cap_profile))
    |> Enum.uniq_by(fn m -> m["path"] || m[:path] end)
    |> mounts_env()
  end

  defp opts_mounts(opts), do: Keyword.get(opts || [], :mounts, [])

  defp other_face_reference_mount(opts, cap_profile) do
    case other_face_reference_path(opts, cap_profile) do
      nil -> []
      path -> [%{"mode" => "ro", "path" => path}]
    end
  end

  @doc """
  Returns the OTHER production face's worktree as a read-only reference for this pod.

  A producer on `code` gets `workshop`, a producer on `workshop` gets `code` — each one reads what it must
  compose with and may not edit. A branch that is neither face (a judge cloning a producer's head)
  and a missing worktree both return `nil`.

  NEVER `ops`, and no clause is needed to say so: no card can declare that face, so no producer
  clone ever sits on that branch and `face_of/1` never answers it here. `face_root/1` raises on
  anything outside the declared faces rather than guessing a directory.

  `roots` is a test seam: `%{"code" => path, "workshop" => path}`, defaulting to the layout.
  """
  @spec other_face_reference_path(keyword(), Fleet.CapProfile.t(), map()) :: String.t() | nil
  def other_face_reference_path(opts, cap_profile, roots \\ default_face_roots()) do
    with face when face in ["code", "workshop"] <-
           Fleet.Layout.face_of(effective_project(opts, cap_profile)["base_branch"]),
         project when is_binary(project) <- rc_project(opts, cap_profile),
         path = Path.join(Map.fetch!(roots, other_face(face)), project),
         true <- File.dir?(path) do
      path
    else
      _ -> nil
    end
  end

  defp other_face("code"), do: "workshop"
  defp other_face("workshop"), do: "code"

  defp default_face_roots,
    do: %{
      "code" => Fleet.Layout.face_root("code"),
      "workshop" => Fleet.Layout.face_root("workshop")
    }

  defp cap_profile_mounts(%Fleet.CapProfile{metadata: meta}) when is_map(meta) do
    Map.get(meta, "mounts") || Map.get(meta, :mounts) || []
  end

  defp cap_profile_mounts(_), do: []

  # bwrap already exposes /usr; launchers elsewhere need an explicit mount after /home is masked.
  defp system_mounts(claude_launch_path) do
    bin = Path.dirname(claude_launch_path)
    if String.starts_with?(bin, "/usr/"), do: [], else: [%{"mode" => "ro", "path" => bin}]
  end

  defp mounts_env(mounts) when is_list(mounts) do
    case Enum.find(mounts, &mount_has_newline?/1) do
      nil ->
        :ok

      injecting ->
        raise ArgumentError,
              "LaunchSpec: SECURITY REFUSAL — newline in a mount field (LCARS_POD_MOUNTS injection): " <>
                "#{inspect(injecting)}. Pod projection refused — an injecting mount is NOT dropped-and-launched."
    end

    Enum.map_join(mounts, "\n", fn m ->
      mode = bound_mount_mode(Map.get(m, "mode") || Map.get(m, :mode))
      path = Map.get(m, "path") || Map.get(m, :path)
      "#{mode}:#{path}"
    end)
  end

  defp mount_has_newline?(m) do
    has_newline?(Map.get(m, "mode") || Map.get(m, :mode)) or
      has_newline?(Map.get(m, "path") || Map.get(m, :path))
  end

  defp has_newline?(v), do: is_binary(v) and String.contains?(v, ["\n", "\r"])
end
