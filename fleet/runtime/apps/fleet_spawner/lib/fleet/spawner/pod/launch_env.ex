defmodule Fleet.Spawner.Pod.LaunchEnv do
  @moduledoc """
  CONSTRUCTION of the launch environment + resolution/validation of the pod's CREDENTIALS —
  extracted from `Fleet.Spawner.Pod`.

  A single role: from the `state` (base env, cap_profile, opts), the `role`, the `containment` and
  the vendor launcher path, produce the COMPLETE env passed to the launch backend — auth `bind`
  set, the human's git identity resolved, credentials gate (scope/plan) passed — or an
  `{:error, reason}` ALREADY tagged. `build/4` touches neither Port, nor timer, nor state machine: it returns a
  value, the `Pod` (state `:launching`) wires it onto `do_launch_backend` or `transition_failed`.

  ## CREDENTIAL MECHANISM — sanctuary moved as-is

  The creds helpers (`claude_dir*`, `passwd_home`, `claude_bin_in_home`, `maybe_put_*`) and the boxed
  "DO NOT TOUCH" block that caps them were moved VERBATIM from `Pod`: per-human
  YES, shared-writable YES, broker NO (cf. the boxed block below). The auth stays single-valued
  `LCARS_AUTH_MODE=bind` — no switch, no variant.

  ## Contract (called by `Pod`)

  - `build(state, role, containment, claude_launch_path)` — called by the `:launching` state; returns
    `{:ok, env}` (auth `bind` set, the human's git identity, scope/plan gate passed) or
    `{:error, reason}` ALREADY tagged `:launch_env_unresolved` (raise from human/passwd/vendor-bin resolution),
    `:credentials_invalid` (scope/plan gate) or `:auth_token_required` (auth/git identity). Order
    auth → git → gate preserved. The `:launching` state wires it onto `do_launch_backend` / `transition_failed`.
  - `claude_dir/0` — claudeDir of the runtime human (config override `:claude_dir` else
    `~/.claude`); **public** because also called by the `:injecting` state (`Pod`) for `CLAUDE_DIR` at injection.

  Depends on `Pod.LaunchSpec` (env builders), `Pod.McpProvision` (`mcp_channel_env`), `Pod.Paths`
  (`runtime_home`), `Fleet.Credentials.*` (Human/ForgeIdentity/Gate, full qualif) and
  `Fleet.Spawner.PodTmux` (`sock_base`, full qualif). No dependency on `Fleet.Spawner.Pod`
  (no cycle).
  """

  alias Fleet.Spawner.Pod.LaunchSpec
  alias Fleet.Spawner.Pod.McpProvision
  alias Fleet.Spawner.Pod.Paths

  @doc """
  Builds the COMPLETE pod launch env + resolves/validates the credentials.

  Returns `{:ok, env}` (auth `bind` set, the human's git identity, scope/plan gate passed) or
  `{:error, reason}` tagged (`:launch_env_unresolved` | `:credentials_invalid` | `:auth_token_required`),
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
          # wild" that bypasses EVERYTHING). Shaped world (bwrap RO/RW + cap-profile) → the bypass is useless, it
          # would only neutralize our lists. Override by cap-profile `spec.invocation.permission_mode`
          # (e.g. "bypassPermissions" to explicitly re-open yolo). NB: write enforcement =
          # the MOUNT (RO/RW), not the tool-list → the judges keep Write/Edit (reports), bounded by the mount.
          |> Map.put("LCARS_PERMISSION_MODE", LaunchSpec.permission_mode(state.cap_profile))
          # RC Desktop name: `<project>_<role>` supplied by the dispatch (`opts[:rc_name]`); default = role
          # alone (permanent / project-less pods). claude_launch passes it as
          # `--remote-control "<name>"` EXACT (zero auto suffix → no "random names piling up").
          # Per-user RC sessions (the human sees ONLY their own). Desktop visibility gated on the
          # claude_launch.sh side (reads `invocation.remote_control` of the cap-profile). NB: the VALUE is the
          # EXACT name, not a prefix — the legacy env name (`_NAME_PREFIX`) is kept (less churn).
          |> Map.put("LCARS_POD_SESSION_NAME_PREFIX", Keyword.get(state.opts, :rc_name, role))
          # Tmux sock base: bwrap_launch creates the socket under <base>/<pod_id>/, PodTmux (host) hits it.
          # SAME value on both sides ⇒ the computed sock coincides. The value = PodTmux.sock_base (default
          # home-relative `~/.lcars/run/tmux-sock` for a fleet launched by a human; never /run/lcars).
          |> Map.put("LCARS_TMUX_SOCK_BASE", Fleet.Spawner.PodTmux.sock_base())
          # The pod is the HUMAN's: creds AND vendor binary follow /home/<human> (same rule as
          # pod_dir). The binary is resolved robustly here (from ~/.local/bin, not the `command -v` gamble).
          # The pod runs UNDER the human's UID BY CONSTRUCTION: the runtime runs *as* the human
          # (each human = THEIR fleet under their user), the pod = BEAM Port inherits this UID →
          # ownership/perms/OS isolation for free, NO systemd-run --uid. (Only starfleet has a
          # dedicated user, off-fleet.)
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
            LaunchSpec.pod_mounts_env(state.cap_profile, claude_launch_path)
          )

        {:ok, human, env}
      rescue
        e -> {:error, {:launch_env_unresolved, Exception.message(e)}}
      end

    # The auth step sits outside the pipe (sets LCARS_AUTH_MODE=bind, fail-loud on error). The
    # credentials gate (scope/plan) follows, tagged {:credentials_invalid, _} for a refusal distinct from auth.
    case launch_env do
      {:ok, human, env} ->
        with {:ok, env} <- maybe_put_auth_token(env, human),
             {:ok, env} <- maybe_put_git_identity(env, human, role),
             :ok <- Fleet.Credentials.Gate.validate(claude_dir_for(human), state.cap_profile) do
          {:ok, env}
        else
          {:error, {:credentials_invalid, _} = reason} -> {:error, reason}
          {:error, reason} -> {:error, {:auth_token_required, reason}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # SINGLE source `Fleet.Credentials.Human` (no `id -un` shelled out twice — otherwise
  # spawn-ownership and commit-identity could diverge, which would break the forge identity gate).
  # Fail-loud (raise), caught by `build/4`'s try/rescue (converted to {:error, {:launch_env_unresolved, _}}).
  defp runtime_user, do: Fleet.Credentials.Human.current!()

  # ════════════════════════════════════════════════════════════════════════════════════════
  # CREDENTIAL MECHANISM — DO NOT TOUCH (and above all not to "harden" it).
  #
  # The pod authenticates by mounting the OAuth `.credentials.json` of ITS human (the `~/.claude`
  # of the runtime user), bound RW by the launcher. This file is SHARED and WRITABLE across all
  # the pods of the same human, and this is INTENDED: it is the ONLY multi-agent mechanism the vendor
  # supports under subscription — N Claude Code processes coordinate to refresh the single token
  # via a cross-process lock on `~/.claude/` (native refresh, designed "fleet-wide" on the vendor side).
  #
  # Known and ACCEPTED consequence: a pod with a shell can read the token of its OWN human,
  # and can overwrite the shared file. This is NOT a hole to fix:
  #   - overwriting/corrupting the creds = suicide (no creds, no agent) → nothing to defend;
  #   - reading it = the pod ALREADY runs AS the human (it inherits their UID) → it is ITS own token,
  #     within the boundary the OS grants it anyway.
  # The only real vector — reading ANOTHER human's token — is made impossible HERE: the claudeDir
  # is derived PER-HUMAN (`claude_dir_for/1`; never a global dir shared across humans).
  #
  # Any "fix" that would remove the RW bind, isolate a credential per-pod, or go through a
  # broker necessarily BREAKS one of the three hard pillars:
  #   - an inference-only token (`claude setup-token`) CANNOT sustain a Remote Control session
  #     (= our interactive mode);
  #   - injecting the live access-token = ~8h cliff with no refresh (already tried, already reverted);
  #   - an apiKeyHelper / an API key = METERED billing = leaving the subscription (forbidden).
  # So: per-human YES, shared-writable YES, broker NO. DO NOT "improve" this.
  # ════════════════════════════════════════════════════════════════════════════════════════
  @doc """
  claudeDir of the runtime human: config override `:fleet_spawner, :claude_dir` else `~/.claude`
  (derived from `Paths.runtime_home/0`). Public because also called by the `:injecting` state (`Pod`)
  to set `CLAUDE_DIR` at injection. The arbitrary per-human variant (`claude_dir_for/1`,
  passwd-resolved) stays private to the `build/4` pipeline — cf. the sanctuary block above.
  """
  @spec claude_dir() :: String.t()
  def claude_dir do
    Application.get_env(:fleet_spawner, :claude_dir) || Path.join(Paths.runtime_home(), ".claude")
  end

  # Pod creds = the HUMAN's `~/.claude` (= the runtime user). Config override `:claude_dir` honored
  # (tests / non-standard deployment); else derived from their passwd home. Per-human by construction
  # (cf. the big block above) — NEVER a claudeDir shared across humans.
  defp claude_dir_for(human) do
    Application.get_env(:fleet_spawner, :claude_dir) || claude_dir_from_passwd(human)
  end

  # Pod creds = `.claude` in the human's home, resolved via `getent passwd`. Passwd failure =
  # a real error (the human's user MUST exist) → fail-loud, no guessed `/home/<x>`.
  defp claude_dir_from_passwd(human) do
    case passwd_home(human) do
      {:ok, home} -> Path.join(home, ".claude")
      :error -> raise "claude_dir: home not found (getent passwd #{inspect(human)}) — fail-loud"
    end
  end

  # Pod git identity = the brief's HUMAN (author AND committer; the pod commits AS
  # the human who runs it), resolved via the catalogue (`Fleet.Credentials.ForgeIdentity`). Replaces
  # a role-based COOPERATIVE DEFAULT of `bwrap_launch.sh` (GIT_AUTHOR=LCARS-$ROLE): the role no
  # longer signs the identity — it goes into a `Co-authored-by` trailer. bwrap_launch.sh forwards these
  # GIT_AUTHOR_*/GIT_COMMITTER_*. Catalogue absent → fail-loud {:forge_identity_unresolved,_}
  # (no pod without a verifiable identity at push — the guarantee stays on the WORLD side, gate
  # `allowed_emails=[human]`).
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

  # Auth = `bind` mode ONLY. bwrap mounts the human's `.credentials.json` RW → native OAuth
  # refresh (proactive 5min + reactive 401 + lockfile), full scope, NO ~8h cliff. A token_arg
  # mode would leak the token in argv (`--setenv CLAUDE_CODE_OAUTH_TOKEN`) AND would not refresh
  # (expiresAt:null) → a long eng (>8h) would lose auth mid-work. No toggle.
  defp maybe_put_auth_token(env, _human) do
    {:ok, Map.put(env, "LCARS_AUTH_MODE", "bind")}
  end

  # Vendor binary set in LCARS_VENDOR_BIN (honors the bwrap_launch.sh contract) = the HUMAN's
  # `~/.local/bin/claude` (= the runtime user), resolved via their passwd home. NO `lcars` fallback: the
  # pod IS the human, it is THEIR binary. Not found → fail-loud (otherwise bwrap falls back on
  # `command -v claude` = stale system binary, Monitor tool absent).
  defp maybe_put_vendor_bin(env, human) do
    case claude_bin_in_home(human) do
      bin when is_binary(bin) ->
        Map.put(env, "LCARS_VENDOR_BIN", bin)

      nil ->
        raise "vendor: claude binary not found in ~/.local/bin of #{inspect(human)} (fail-loud)"
    end
  end

  # Looks for `~/.local/bin/claude` in `user`'s passwd home. Returns the real path
  # (readlink -f) or `nil`. The home comes from `getent passwd` (NSS), not a guessed `/home/<x>`.
  defp claude_bin_in_home(user) when is_binary(user) do
    with {:ok, home} <- passwd_home(user),
         link = Path.join([home, ".local", "bin", "claude"]),
         true <- File.exists?(link) do
      case System.cmd("readlink", ["-f", link], stderr_to_stdout: true) do
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

  # `user`'s home via `getent passwd` (field 6, 0-indexed 5). `{:ok, home}` | `:error`.
  defp passwd_home(user) do
    case System.cmd("getent", ["passwd", user], stderr_to_stdout: true) do
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
end
