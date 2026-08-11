defmodule Fleet.Spawner.Pod.LaunchEnv do
  @moduledoc """
  CONSTRUCTION of the launch environment + resolution/validation of the pod's CREDENTIALS —
  extracted from `Fleet.Spawner.Pod`.

  A single role: from the `state` (base env, cap_profile, opts), the `role`, the `containment` and
  the vendor launcher path, produce the COMPLETE env passed to the launch backend — auth `bind`
  set, the human's git identity resolved, login-validity gate passed — or an
  `{:error, reason}` ALREADY tagged. `build/4` touches neither Port, nor timer, nor state machine: it returns a
  value, the `Pod` (state `:launching`) wires it onto `do_launch_backend` or `transition_failed`.

  ## Credential mechanism

  The creds helpers (`claude_dir*`, `passwd_home`, `claude_bin_in_home`, `maybe_put_*`) are capped
  by the boxed credential-invariant block below: per-human YES, shared-writable YES, broker NO.
  The auth is single-valued `LCARS_AUTH_MODE=bind` — no switch, no variant.

  ## Contract (called by `Pod`)

  - `build(state, role, containment, claude_launch_path)` — called by the `:launching` state; returns
    `{:ok, env}` (auth `bind` set, the human's git identity, login-validity gate passed) or
    `{:error, reason}` ALREADY tagged `:launch_env_unresolved` (raise from human/passwd/vendor-bin resolution),
    `:credentials_invalid` (login-validity gate) or `:git_identity_unresolved` (forge commit identity). Order
    auth → git → gate preserved. The `:launching` state wires it onto `do_launch_backend` / `transition_failed`.

  Depends on `Pod.LaunchSpec` (env builders), `Pod.McpProvision` (`mcp_channel_env`),
  `Fleet.Credentials.*` (Human/ForgeIdentity/Gate, full qualif) and
  `Fleet.Spawner.PodTmux` (`sock_base`, full qualif). No dependency on `Fleet.Spawner.Pod`
  (no cycle).
  """

  alias Fleet.Spawner.Pod.LaunchSpec
  alias Fleet.Spawner.Pod.McpProvision

  @doc """
  Builds the COMPLETE pod launch env + resolves/validates the credentials.

  Returns `{:ok, env}` (auth `bind` set, the human's git identity, login-validity gate passed) or
  `{:error, reason}` tagged (`:launch_env_unresolved` | `:credentials_invalid` | `:git_identity_unresolved`),
  wired by the `:launching` state onto `do_launch_backend` / `transition_failed`. `role`/`containment`/
  `claude_launch_path` are resolved on the `Pod` side (state `:launching`) and passed here: `role` ==
  `cap_profile_name(state.cap_profile)` (same value, computed the same way) → we avoid the dependency on
  `Pod`'s private.
  """
  @spec build(map(), String.t(), String.t(), String.t()) ::
          {:ok, %{String.t() => String.t()}} | {:error, term()}
  def build(state, role, containment, claude_launch_path) do
    # Human resolution + the env pipeline can RAISE (runtime_user /
    # claude_dir_from_passwd / maybe_put_vendor_bin = fail-loud on a host without a per-user claude
    # or an unresolvable home). An uncaught raise HERE would crash the pod process (gen_statem) WITHOUT
    # transition_failed → orphaned task :pending + state.json at the stale phase. We
    # fold any env-construction raise onto transition_failed (same cleanup as the
    # other launch failures: clear_pod_task + phase=failed).
    launch_env =
      try do
        human = Keyword.get(state.opts, :human) || runtime_user()
        # Creds resolved ONCE (fail-loud if the human's passwd is not found): serves the host HOME
        # (`launch_home`, parent of the claude_dir) AND CLAUDE_DIR. Deterministic value (config + passwd).
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
          # HOME — depends on containment.
          #   bwrap (default): HOME=pod_dir (coherent; bwrap does `--setenv HOME` anyway,
          #     this value is ignored under the sandbox).
          #   none (host)    : HOME = the human's REAL home → claude reads its native `~/.claude`. This is
          #     `:bind` auth realized NATIVELY on the host (OAuth refresh, full scope, no 8h cliff — the arch
          #     is a pod forever). host_launch.sh does NOT re-setenv (no namespace): this HOME IS the real env.
          |> Map.put("HOME", LaunchSpec.launch_home(containment, state.pod_dir, claude_dir))
          # Session chain: bwrap_launch `--setenv`s them into the pod,
          # claude_launch reads them `:?` strict (no-boot otherwise).
          |> Map.put("LCARS_POD_SESSION_ID", state.session_id)
          |> Map.put("LCARS_POD_RESUME", if(state.resume, do: "1", else: "0"))
          # Permission mode: default `default` → claude_launch passes `--permission-mode default`
          # (allow/deny lists ENFORCED) instead of `--dangerously-skip-permissions` (legacy "agents in the
          # wild" that bypasses EVERYTHING). Override by cap-profile `spec.invocation.permission_mode`
          # (e.g. "bypassPermissions" to explicitly re-open yolo). NB: write enforcement =
          # the MOUNT (RO/RW), not the tool-list → the judges keep Write/Edit (reports), bounded by the mount.
          #
          # ⚠ THIS CHOICE RESTED ON "the bypass is useless, it would only neutralize our lists", AND
          # THAT HALF IS MEASURED FALSE. It is not neutral: under `default` a tool absent from
          # `allowedTools` does not get skipped, it PROMPTS — and a pod has nobody to answer.
          # Measured on a bench 2026-08-09 with a real pod: a scribe reached for `NotebookEdit`
          # (in neither list) and froze on "Do you want to insert this cell? 1. Yes 2. Yes, allow
          # all 3. No", still alive, still holding its slot and the ticket's in-flight lock,
          # producing nothing. The recovery chain then re-dispatches a pod that wedges identically.
          #
          # What the rest of the comment says stays TRUE and is the reason the trade is arguable:
          # the wall is the MOUNT, so a bypass lowers no real barrier — it only removes the prompt
          # path. Every canon cap-profile leaves this field undeclared, so every pod runs `default`
          # today. Which posture the fleet wants is an operator decision, NOT a code one; it is
          # open, and the measurement above is what it should be decided on.
          |> Map.put("LCARS_PERMISSION_MODE", LaunchSpec.permission_mode(state.cap_profile))
          # RC Desktop name: `<project>_<role>` supplied by the dispatch (`opts[:rc_name]`); default = role
          # alone (permanent / project-less pods). claude_launch passes it as
          # `--remote-control "<name>"` EXACT (zero auto suffix → no "random names piling up").
          # Per-user RC sessions (the human sees ONLY their own). NB: the VALUE is the EXACT name,
          # not a prefix — the legacy env name (`_NAME_PREFIX`) is kept (less churn).
          |> Map.put("LCARS_POD_SESSION_NAME_PREFIX", Keyword.get(state.opts, :rc_name, role))
          # Desktop VISIBILITY, decided here and obeyed there. claude_launch.sh used to re-derive it
          # from the cap-profile with its own jq read: two derivations of one fact, which agree only
          # until something tries to change it. `LaunchSpec.remote_control?/1` is now the single
          # authority and this env carries its answer.
          |> Map.put(
            "LCARS_POD_REMOTE_CONTROL",
            to_string(LaunchSpec.remote_control?(state.cap_profile))
          )
          # Tmux sock base: bwrap_launch creates the socket under <base>/<pod_id>/, PodTmux (host) hits it.
          # SAME value on both sides ⇒ the computed sock coincides. The value = PodTmux.sock_base (default
          # home-relative `~/.lcars/run/tmux-sock` for a fleet launched by a human; never /run/lcars).
          |> Map.put("LCARS_TMUX_SOCK_BASE", Fleet.Spawner.PodTmux.sock_base())
          # The pod is the HUMAN's: creds AND vendor binary follow /home/<human> (same rule as
          # pod_dir). The binary is resolved robustly here (from ~/.local/bin, not the `command -v` gamble).
          # The pod runs UNDER the human's UID BY CONSTRUCTION: the runtime runs *as* the human
          # (each human = THEIR fleet under their user), the pod = BEAM Port inherits this UID →
          # ownership/perms/OS isolation for free, NO systemd-run --uid — for EVERY role (since the
          # 2026-07-19 reorg starfleet is an ordinary bwrap pod too, no dedicated off-fleet user).
          |> Map.put("CLAUDE_DIR", claude_dir)
          |> maybe_put_vendor_bin(human)
          |> LaunchSpec.maybe_put_pod_cwd(state.opts, state.cap_profile, state.pod_dir)
          # Relocates the intra-pod home (bwrap only) → bwrap masks the real pod_dir.
          |> LaunchSpec.maybe_put_sandbox_home(state.cap_profile, state.pod_dir)
          # LCARS_POD_DIR (pod root seen by the agent, where watch.sh/turn.flag live) is NOT set here —
          # it would be dead code: bwrap_launch `--clearenv` strips it, and host_launch `export`s it
          # itself (= $POD_DIR). The SP/watch.sh read `${LCARS_POD_DIR:-$HOME}`:
          # host → the var; bwrap → fallback `$HOME` (= /home/.pod = pod root).
          # CATALOGUE mounts (cap-profile-driven) → bwrap_launch binds them. Empty / host_launch = inert.
          # `system_mounts` prefixes the launchers' dir (install) → claude_launch.sh visible in the sandbox.
          |> Map.put(
            "LCARS_POD_MOUNTS",
            LaunchSpec.pod_mounts_env(
              state.cap_profile,
              state.opts,
              claude_launch_path,
              state.pod_dir
            )
          )

        {:ok, human, env}
      rescue
        e -> {:error, {:launch_env_unresolved, Exception.message(e)}}
      end

    case launch_env do
      {:ok, human, env} ->
        with {:ok, env} <- maybe_put_auth_token(env, human),
             {:ok, env} <- maybe_put_git_identity(env, human, role),
             :ok <- Fleet.Credentials.Gate.validate(claude_dir_for(human)) do
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
    Application.get_env(:fleet_spawner, :claude_dir) || claude_dir_from_passwd(human)
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

  defp maybe_put_auth_token(env, _human) do
    {:ok, Map.put(env, "LCARS_AUTH_MODE", "bind")}
  end

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
end
