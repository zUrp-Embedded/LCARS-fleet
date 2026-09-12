defmodule Fleet.Spawner.Pod.LaunchEnv do
  @moduledoc """
  Builds the launch environment and resolves per-human credentials and Git identity.
  `Pod` supplies resolved role, containment and launcher inputs, then dispatches the
  result or enters its failure transition. Authentication uses `LCARS_AUTH_MODE=bind`:
  bwrap shares the owning human’s writable credentials file for OAuth refresh;
  host containment uses the native directory. No credential broker or token argv.
  """

  require Logger

  alias Fleet.Spawner.Pod.LaunchSpec
  alias Fleet.Spawner.Pod.McpProvision

  @doc """
  Builds the environment, sets bind authentication, resolves Git identity, then
  validates login against the same credentials directory used for launch.
  Returns `{:ok, env}` or an error tagged `:launch_env_unresolved`,
  `:git_identity_unresolved` or `:credentials_invalid`.
  """
  @spec build(map(), String.t(), String.t(), String.t()) ::
          {:ok, %{String.t() => String.t()}} | {:error, term()}
  def build(state, role, containment, claude_launch_path) do
    # Convert environment-construction exceptions into the pod’s normal failure/cleanup path.
    launch_env =
      try do
        human = Keyword.get(state.opts, :human) || runtime_user()
        # Resolve once for both launch HOME/CLAUDE_DIR and the later login check.
        claude_dir = claude_dir_for(human)

        env =
          state.env_vars
          |> Map.merge(LaunchSpec.skills_plugins_env(state.cap_profile))
          |> Map.merge(LaunchSpec.skills_paths_env(Map.get(state, :skills_paths, [])))
          |> Map.merge(
            McpProvision.mcp_channel_env(
              state.pod_id,
              role
            )
          )
          # Host containment needs the native credentials HOME; bwrap sets its in-namespace HOME.
          |> Map.put("HOME", LaunchSpec.launch_home(containment, state.pod_dir, claude_dir))
          |> Map.put("LCARS_POD_SESSION_ID", state.session_id)
          |> Map.put("LCARS_POD_RESUME", if(state.resume, do: "1", else: "0"))
          # In default mode, tools absent from allowedTools may prompt and stall a headless pod
          # (e.g. NotebookEdit in a recorded bench run). Permission mode is a profile/operator choice.
          # RO/RW mounts remain the filesystem boundary even when tool permission prompts are bypassed.
          |> Map.put("LCARS_PERMISSION_MODE", LaunchSpec.permission_mode(state.cap_profile))
          # Despite _NAME_PREFIX, this is the exact Desktop name; no automatic suffix is added.
          |> Map.put("LCARS_POD_SESSION_NAME_PREFIX", Keyword.get(state.opts, :rc_name, role))
          # Export the shared visibility decision so slot handling and the vendor launcher agree.
          |> Map.put(
            "LCARS_POD_REMOTE_CONTROL",
            to_string(LaunchSpec.remote_control?(state.cap_profile))
          )
          # The launchers and host PodTmux must compute the same socket path.
          |> Map.put("LCARS_TMUX_SOCK_BASE", Fleet.Spawner.PodTmux.sock_base())
          # The Port inherits the runtime UID. Credentials and vendor binary resolve for that human.
          |> Map.put("CLAUDE_DIR", claude_dir)
          |> maybe_put_vendor_bin(human)
          |> LaunchSpec.maybe_put_pod_cwd(state.opts, state.cap_profile, state.pod_dir)
          |> LaunchSpec.maybe_put_sandbox_home(state.cap_profile, state.pod_dir)
          # LCARS_POD_DIR is launcher-owned; the spawner exports LCARS_POD_HOME for bwrap.
          # Provision the proxy before handing its socket path to the launcher.
          |> Map.put("LCARS_POD_EGRESS_SOCK", egress_socket(state, claude_launch_path))
          |> Map.put("LCARS_POD_TOOLCHAIN_ENV", LaunchSpec.toolchain_env())
          |> Map.put(
            "LCARS_POD_MOUNTS",
            LaunchSpec.pod_mounts_env(
              state.cap_profile,
              state.opts,
              claude_launch_path,
              state.pod_dir
            )
          )

        {:ok, human, claude_dir, env}
      rescue
        e -> {:error, {:launch_env_unresolved, Exception.message(e)}}
      end

    case launch_env do
      # Carry the resolved directory through: a second lookup could validate a different path
      # or raise outside the environment-construction rescue.
      {:ok, human, claude_dir, env} ->
        with {:ok, env} <- maybe_put_git_identity(put_auth_mode(env), human, role),
             :ok <- Fleet.Credentials.Gate.validate(claude_dir) do
          {:ok, env}
        else
          {:error, {:credentials_invalid, _} = reason} -> {:error, reason}
          {:error, reason} -> {:error, {:git_identity_unresolved, reason}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp runtime_user, do: Fleet.Credentials.Human.current!()

  defp claude_dir_for(human) do
    Application.get_env(:lcars_fleet, :spawner_claude_dir) || claude_dir_from_passwd(human)
  end

  defp claude_dir_from_passwd(human) do
    case passwd_home(human) do
      {:ok, home} -> Path.join(home, ".claude")
      :error -> raise "claude_dir: home not found (getent passwd #{inspect(human)}) — fail-loud"
    end
  end

  defp maybe_put_git_identity(env, human, role) do
    case Fleet.Credentials.ForgeIdentity.for_role(role, human: human) do
      {:ok, id} ->
        {:ok,
         env
         |> Map.put("GIT_AUTHOR_NAME", id.author_name)
         |> Map.put("GIT_AUTHOR_EMAIL", id.author_email)
         |> Map.put("GIT_COMMITTER_NAME", id.committer_name)
         |> Map.put("GIT_COMMITTER_EMAIL", id.committer_email)}

      {:error, reason} ->
        {:error, {:forge_identity_unresolved, reason}}
    end
  end

  # Bind authentication carries a directory path, not a token in the launch environment.
  defp put_auth_mode(env), do: Map.put(env, "LCARS_AUTH_MODE", "bind")

  defp maybe_put_vendor_bin(env, human) do
    case claude_bin_in_home(human) do
      bin when is_binary(bin) ->
        Map.put(env, "LCARS_VENDOR_BIN", bin)

      nil ->
        raise "vendor: claude binary not found in ~/.local/bin of #{inspect(human)} (fail-loud)"
    end
  end

  defp claude_bin_in_home(user) when is_binary(user) do
    with {:ok, home} <- passwd_home(user),
         link = Path.join([home, ".local", "bin", "claude"]),
         true <- File.exists?(link) do
      case cmd_with_timeout("readlink", ["-f", link]) do
        {out, 0} -> String.trim(out)
        _ -> link
      end
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp claude_bin_in_home(_), do: nil

  defp passwd_home(user) do
    case cmd_with_timeout("getent", ["passwd", user]) do
      {line, 0} ->
        case String.split(String.trim(line), ":") do
          fields when length(fields) >= 6 -> {:ok, Enum.at(fields, 5)}
          _ -> :error
        end

      _ ->
        :error
    end
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end

  @cmd_timeout_ms 5_000
  defp cmd_with_timeout(cmd, args) do
    case Fleet.Credentials.Shell.run(cmd, args, timeout_ms: @cmd_timeout_ms) do
      {:ok, {out, status}} -> {out, status}
      {:error, _} -> {"", 124}
    end
  end

  # Start the proxy, not just compute a path. On failure return an empty socket value: bwrap
  # then starts without a relay, leaving its isolated namespace unable to reach the vendor.
  defp egress_socket(state, claude_launch_path) do
    case Fleet.Spawner.Pod.Egress.provision(state.pod_id, state.cap_profile, claude_launch_path) do
      {:ok, nil} ->
        ""

      {:ok, path} ->
        path

      {:error, reason} ->
        Logger.error(
          "LaunchEnv: egress NOT provisioned for #{state.pod_id} (#{inspect(reason)}) — the " <>
            "launcher will refuse rather than start a pod with no way to reach its vendor"
        )

        ""
    end
  end
end
