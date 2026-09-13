defmodule Fleet.Spawner.Pod.LaunchSpec do
  @moduledoc """
  Resolves pod launch paths, placement and environment values from profiles and spawn options.
  Also reads toolchain declarations and materializes pinned Git references. Shared with
  workspace setup, completion payloads, recall and seed handling to keep placement consistent.
  """

  require Logger

  alias Fleet.CapProfile
  alias Fleet.Credentials.Shell

  @doc """
  Returns opts[:project], then the profile’s static project, then an empty map.
  Shared by launch placement and completion payload construction.
  """
  @spec effective_project(keyword() | nil, CapProfile.t()) :: map()
  def effective_project(opts, cap_profile) do
    Keyword.get(opts || [], :project) || get_in(cap_profile.spec, ["project"]) || %{}
  end

  @doc """
  Returns the explicit `:project_slug` when valid, otherwise nil (no project remap/seed).
  `:project` is the separate project map; `:rc_name` is a display label and is not parsed.

  Reference paths use this slug while `Fleet.Layout.project_name/1` normalizes host names.
  Their outputs agree for the narrower onboarding charset; `Fleet.LayoutTest` guards
  that invariant if accepted project names are widened.
  """
  @spec rc_project(keyword(), CapProfile.t()) :: String.t() | nil
  def rc_project(opts, _cap_profile) do
    # Keep project_slug explicit: parsing rc_name would make a display format govern paths
    # and silently lose remapping when labels gain a ticket suffix.
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
  @spec pod_cwd(keyword(), CapProfile.t(), Path.t()) :: String.t()
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
  @spec sandbox_home(CapProfile.t(), Path.t()) :: String.t()
  def sandbox_home(cap_profile, pod_dir) do
    if CapProfile.bwrap?(cap_profile), do: "/home/.pod", else: pod_dir
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
  @spec maybe_put_pod_cwd(map(), keyword(), CapProfile.t(), Path.t()) :: map()
  def maybe_put_pod_cwd(env, opts, cap_profile, pod_dir) do
    env = Map.put(env, "LCARS_POD_CWD", pod_cwd(opts, cap_profile, pod_dir))

    if rc_project(opts, cap_profile),
      do: Map.put(env, "LCARS_POD_CWD_SRC", pod_cwd_real(opts, cap_profile, pod_dir)),
      else: env
  end

  @doc """
  Adds `LCARS_POD_HOME` for bwrap pods; host pods retain their native home.
  """
  @spec maybe_put_sandbox_home(map(), CapProfile.t(), Path.t()) :: map()
  def maybe_put_sandbox_home(env, cap_profile, pod_dir) do
    if CapProfile.bwrap?(cap_profile),
      do: Map.put(env, "LCARS_POD_HOME", sandbox_home(cap_profile, pod_dir)),
      else: env
  end

  @doc """
  Returns the native human home for host containment and the pod directory otherwise.
  """
  @spec launch_home(String.t(), Path.t(), Path.t()) :: Path.t()
  def launch_home("none", _pod_dir, claude_dir), do: Path.dirname(claude_dir)
  def launch_home(_containment, pod_dir, _claude_dir), do: pod_dir

  @permission_modes ~w(default acceptEdits bypassPermissions plan)

  @doc """
  Returns the profile's closed-enum Claude permission mode, defaulting to `"default"` when absent.

  A present value outside the enum raises instead of being normalized.
  """
  @spec permission_mode(term()) :: String.t()
  def permission_mode(%CapProfile{spec: spec}),
    do: bound_permission_mode(get_in(spec || %{}, ["invocation", "permission_mode"]) || "default")

  def permission_mode(_), do: "default"

  @doc """
  Returns declared/derived profile visibility OR the fleet debug-visibility setting.
  Debug can add visibility, never remove it. LaunchEnv exports this decision as
  `LCARS_POD_REMOTE_CONTROL`; the vendor only derives its own fallback outside that path.
  Changing the setting does not retrofit launch arguments of already running pods.
  """
  @spec remote_control?(term()) :: boolean()
  def remote_control?(cap_profile) do
    CapProfile.remote_control?(cap_profile) or Fleet.Spawner.debug_visibility?()
  end

  @doc """
  Returns profile compression AND the fleet compression setting; either can disable it.
  Neither may force lossy output on the other.

  This verdict is currently unused by production launch code: declaring output_compression
  has no effect on running pods. The shipped token_saver uses a PreToolUse hook, while pod
  projection excludes human hooks and writes no hook configuration. Connecting the verdict
  requires designing a supported hook delivery path, not merely enabling the existing flag.
  """
  @spec output_compression?(term()) :: boolean()
  def output_compression?(cap_profile) do
    CapProfile.output_compression?(cap_profile) and
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
  @spec skills_plugins_env(CapProfile.t()) :: map()
  def skills_plugins_env(%CapProfile{spec: spec}) do
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
  Serializes filtered skill directories as newline-delimited `name:abs_path` entries.
  The first colon separates the basename (a validated skill slug) from its path;
  spaces and later colons remain part of the path. The composer contract returns paths,
  so names are derived with Path.basename. Empty input produces no environment entry.
  """
  @spec skills_paths_env([Path.t()]) :: map()
  def skills_paths_env([]), do: %{}

  def skills_paths_env(paths) when is_list(paths) do
    # Newlines inject extra bind entries; refuse the projection instead of dropping one mount.
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
  Serializes mounts in priority order: system, store, profile, spawn, other-face reference.
  The first entry for each source path wins, including its mode. Modes must be `ro` or `rw`;
  newlines in any field raise.

  The ops ledger is not mounted implicitly for producers: briefs and criteria arrive through
  work items or pinned files. An architect can receive ops through explicit spawn mounts.
  """
  @spec pod_mounts_env(CapProfile.t(), keyword(), String.t(), Path.t() | nil) :: String.t()
  def pod_mounts_env(cap_profile, opts, claude_launch_path, pod_dir \\ nil) do
    (system_mounts(claude_launch_path) ++
       store_mounts() ++
       cap_profile_mounts(cap_profile) ++
       opts_mounts(opts) ++
       other_face_reference_mount(opts, cap_profile, pod_dir))
    |> Enum.uniq_by(fn m -> m["path"] || m[:path] end)
    |> mounts_env()
  end

  # Mount the store RO, then its cache RW so pip/npm/cargo can write without changing tools.
  # bwrap applies mounts in order; reversing them hides the writable cache. An absent
  # LCARS_STORE_ROOT or unmounted directory contributes no mounts.
  defp store_mounts do
    case store_root() do
      nil ->
        []

      root ->
        [%{"mode" => "ro", "path" => root}] ++
          if File.dir?(Path.join(root, "cache")),
            do: [%{"mode" => "rw", "path" => Path.join(root, "cache")}],
            else: []
    end
  end

  @doc false
  @spec store_root() :: Path.t() | nil
  def store_root do
    case System.get_env("LCARS_STORE_ROOT") do
      root when is_binary(root) and root != "" -> if File.dir?(root), do: root, else: nil
      _unset -> nil
    end
  end

  # The converger freezes SDK environment deltas as data. Sourcing downloaded shell while
  # constructing the sandbox would execute it with the launcher’s authority.
  @doc """
  Serializes `<store>/state/env.d/*.env` as KEY=VALUE lines, in sorted filename order.
  No store/directory/declarations yields an empty string. Read failures log and omit the
  unreadable input; malformed declarations raise. Universal build variables are logged
  and dropped. Values are data passed to --setenv, never shell to source in the launcher.
  """
  @spec toolchain_env() :: String.t()
  def toolchain_env do
    case store_root() do
      nil -> ""
      root -> root |> Path.join("state/env.d") |> read_env_dir() |> Enum.join("\n")
    end
  end

  # Global CC/CFLAGS-style settings affect unrelated builds and can silently cross-compile
  # native dependencies. Cross-toolchain choices belong in the project’s own build files.
  @universal_build_vars ~w(CC CXX LD AR NM RANLIB STRIP CFLAGS CXXFLAGS LDFLAGS CPPFLAGS)
  @key_re ~r/\A[A-Z_][A-Z0-9_]*\z/

  defp read_env_dir(dir) do
    case File.ls(dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".env"))
        |> Enum.sort()
        |> Enum.flat_map(&read_env_file(Path.join(dir, &1)))

      {:error, :enoent} ->
        []

      {:error, reason} ->
        Logger.error(
          "LaunchSpec: toolchain env dir #{dir} present but UNREADABLE (#{inspect(reason)}) — " <>
            "the pod launches WITHOUT its toolchain environment. An installed toolchain it cannot see."
        )

        []
    end
  end

  defp read_env_file(path) do
    case File.read(path) do
      {:ok, body} ->
        body |> String.split("\n") |> Enum.flat_map(&parse_env_line(&1, path))

      {:error, reason} ->
        Logger.error("LaunchSpec: toolchain env file #{path} unreadable (#{inspect(reason)})")
        []
    end
  end

  defp parse_env_line(line, path) do
    trimmed = String.trim(line)

    cond do
      trimmed == "" or String.starts_with?(trimmed, "#") ->
        []

      not String.contains?(trimmed, "=") ->
        raise ArgumentError,
              "LaunchSpec: REFUSAL — #{path} carries a line with no `=`: #{inspect(trimmed)}. " <>
                "This file is KEY=VALUE, never shell. Pod projection refused."

      true ->
        [key, value] = String.split(trimmed, "=", parts: 2)
        validate_env_pair(String.trim(key), value, path)
    end
  end

  # Reject embedded CR/LF rather than injecting another environment entry. The reader splits
  # physical lines first; separate valid KEY=VALUE lines remain separate declarations.
  defp validate_env_pair(key, value, path) do
    cond do
      not Regex.match?(@key_re, key) ->
        raise ArgumentError,
              "LaunchSpec: REFUSAL — #{path} declares #{inspect(key)}, which is not a shell " <>
                "environment name (`[A-Z_][A-Z0-9_]*`). Pod projection refused."

      String.contains?(value, "\n") or String.contains?(value, "\r") ->
        raise ArgumentError,
              "LaunchSpec: SECURITY REFUSAL — newline in a toolchain env value for #{key} " <>
                "(#{path}). Pod projection refused — an injecting value is NOT dropped-and-launched."

      key in @universal_build_vars ->
        # Drop disallowed global build variables so one bad store file does not stop every pod.
        # Malformed syntax still refuses projection.
        Logger.error(
          "LaunchSpec: #{key} DROPPED from #{path} — universal build variables are refused. " <>
            "Set globally they make every pod cross-compile: `pip` succeeds and the import fails " <>
            "later with `Exec format error`, naming nothing. A cross build declares its toolchain " <>
            "in its own build files."
        )

        []

      true ->
        ["#{key}=#{value}"]
    end
  end

  defp opts_mounts(opts), do: Keyword.get(opts || [], :mounts, [])

  # Pin the other face into the pod so source edits/removal cannot change a successful copy.
  # Keep its canonical mount destination for existing pointers. Updating a frozen reference
  # requires relaunching the pod on a completed face.
  defp other_face_reference_mount(opts, cap_profile, pod_dir) do
    with path when is_binary(path) <- other_face_reference_path(opts, cap_profile),
         dir when is_binary(dir) <- pod_dir,
         {:ok, pinned} <- pin_reference_face(path, dir) do
      [%{"mode" => "ro", "path" => pinned, "dst" => path}]
    else
      # Missing reference or pod_dir returns no mount; a failed pin logs and falls back to
      # a live RO bind, so reference availability is favored over snapshot consistency.
      nil -> []
      _no_pod_dir_or_failed -> live_reference_mount(opts, cap_profile)
    end
  end

  defp live_reference_mount(opts, cap_profile) do
    case other_face_reference_path(opts, cap_profile) do
      nil -> []
      path -> [%{"mode" => "ro", "path" => path}]
    end
  end

  @doc """
  Copies the reference face at its CURRENT head into `<pod_dir>/ref/<basename>` and returns that
  path. `git archive` + `tar`, so the copy carries no `.git` and no back-reference to the source:
  after this call the pod's reference depends on nothing outside the pod.
  """
  @spec pin_reference_face(Path.t(), Path.t()) :: {:ok, Path.t()} | {:error, term()}
  def pin_reference_face(source, pod_dir) do
    dest = Path.join([pod_dir, "ref", Path.basename(source)])
    tarball = Path.join(pod_dir, "ref-#{Path.basename(source)}.tar")

    with :ok <- require_repo_toplevel(source),
         {:ok, {_, 0}} <-
           Shell.git(
             ["-C", source, "archive", "--format=tar", "-o", tarball, "HEAD"],
             env: []
           ),
         :ok <- File.mkdir_p(dest),
         {:ok, {_, 0}} <- Shell.run("tar", ["-xf", tarball, "-C", dest]) do
      _ = File.rm(tarball)
      {:ok, dest}
    else
      other ->
        _ = File.rm(tarball)

        reason =
          case other do
            {:error, r} -> r
            r -> r
          end

        Logger.warning(
          "LaunchSpec: reference face #{source} NOT pinned (#{inspect(reason)}) — the pod falls " <>
            "back to the live bind, which moves under it"
        )

        {:error, reason}
    end
  end

  @doc """
  Archives the requested path at a pinned SHA into `<pod_dir>/obj/<safe>/<path>`.
  For a file path this supplies only that version, without `.git` or other tickets’ files,
  so a mandate can be delivered without mounting the ops ledger.

  Requires a lowercase 40-hex reference and a repository toplevel. Git resolves the object
  and reports missing references/paths; errors are surfaced rather than yielding an empty mount.
  """
  @spec pin_object(Path.t(), Path.t(), String.t(), String.t()) ::
          {:ok, Path.t()} | {:error, term()}
  def pin_object(source, pod_dir, sha, path)
      when is_binary(source) and is_binary(pod_dir) and is_binary(sha) and is_binary(path) do
    safe = String.replace(path, ~r"[^A-Za-z0-9._-]", "_")
    dest = Path.join([pod_dir, "obj", safe])
    tarball = Path.join(pod_dir, "obj-#{safe}.tar")

    with :ok <- require_commit_sha(sha),
         :ok <- require_repo_toplevel(source),
         {:ok, {_, 0}} <-
           Shell.git(
             ["-C", source, "archive", "--format=tar", "-o", tarball, sha, "--", path],
             env: []
           ),
         :ok <- File.mkdir_p(dest),
         {:ok, {_, 0}} <- Shell.run("tar", ["-xf", tarball, "-C", dest]) do
      _ = File.rm(tarball)
      {:ok, Path.join(dest, path)}
    else
      other ->
        _ = File.rm(tarball)

        reason =
          case other do
            {:error, r} -> r
            r -> r
          end

        Logger.warning(
          "LaunchSpec: object #{path}@#{String.slice(sha, 0, 7)} NOT pinned from #{source} " <>
            "(#{inspect(reason)}) — the pod cannot be given a provable mandate and must not start"
        )

        {:error, reason}
    end
  end

  # Require a full lowercase object ID; branch names and short refs would let the mandate float.
  defp require_commit_sha(sha) do
    if Regex.match?(~r/\A[0-9a-f]{40}\z/, sha),
      do: :ok,
      else: {:error, {:not_a_commit_sha, sha}}
  end

  # git -C walks up to enclosing repositories. Require the source itself to be the toplevel
  # so a plain directory beneath this checkout cannot archive the runtime by accident.
  defp require_repo_toplevel(source) do
    case Shell.git(["-C", source, "rev-parse", "--show-toplevel"], env: []) do
      {:ok, {out, 0}} ->
        same? = Path.expand(String.trim(out)) == Path.expand(source)
        if same?, do: :ok, else: {:error, {:not_a_face_repo, source, String.trim(out)}}

      other ->
        {:error, {:not_a_face_repo, source, other}}
    end
  end

  @doc """
  Returns the other production face’s existing worktree, using the explicit project slug:
  code gets workshop and workshop gets code. Other branches (including ops and feature
  branches), absent slugs and missing worktrees return nil.
  `roots` injects `%{"code" => path, "workshop" => path}`; defaults come from Fleet.Layout.
  """
  @spec other_face_reference_path(keyword(), CapProfile.t(), map()) :: String.t() | nil
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

  defp cap_profile_mounts(%CapProfile{metadata: meta}) when is_map(meta) do
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

      # An explicit dst produces mode:src:dst; otherwise keep the two-field form.
      case Map.get(m, "dst") || Map.get(m, :dst) do
        nil -> "#{mode}:#{path}"
        dst -> "#{mode}:#{path}:#{dst}"
      end
    end)
  end

  defp mount_has_newline?(m) do
    has_newline?(Map.get(m, "mode") || Map.get(m, :mode)) or
      has_newline?(Map.get(m, "path") || Map.get(m, :path)) or
      has_newline?(Map.get(m, "dst") || Map.get(m, :dst))
  end

  defp has_newline?(v), do: is_binary(v) and String.contains?(v, ["\n", "\r"])
end
