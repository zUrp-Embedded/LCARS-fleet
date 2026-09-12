defmodule Fleet.Credentials.Shell do
  @moduledoc """
  Runs external commands with an output cap and an absolute receive deadline, avoiding
  unbounded waits in bootstrap, pod and poller callers. This common credentials dependency
  keeps bootstrap independent of workflow/spawner compilation.

  Linux setsid -w isolates the command group. Depending on the port driver's initial group,
  setsid execs in place or forks a child session leader. Teardown looks up a child's group in
  /proc, then signals that group, -os_pid and os_pid. Retain both paths: port group behaviour
  differs across environments. The -- separator in kill arguments protects negative targets
  from option parsing. Killing only the parent can leave credential-bearing helpers running.

  Teardown is best effort: kill results are ignored, /proc lookup can fail, and descendants
  that leave the discovered groups may survive. Successful command exit does not trigger
  group cleanup. This is not process-tree containment or proof that all descendants died.

  Output does not rearm the deadline. It starts after launch setup; auth resolution and cleanup
  are outside it, and queued port messages can still be handled after it expires. The output cap
  bounds accumulated bytes, not transient chunks, mailbox backlog or total BEAM memory.

  git/2 adds ForgeAuth env unless explicitly supplied; run/3 does not. Env pairs modify the
  inherited environment, so env: [] is not an empty environment. Neither function automatically
  adds git_safe_config_args/0: callers must compose those flags for pod-writable workspaces.
  Match result errors explicitly and inspect the exit code even on {:ok, {output, code}}.
  """

  @default_timeout_ms 30_000
  # Time limits do not bound output volume; larger flows need streaming rather than this buffer.
  @default_max_output_bytes 8_388_608

  @type result ::
          {:ok, {String.t(), non_neg_integer()}}
          | {:error, {:timeout, pos_integer()}}
          | {:error, {:output_overflow, pos_integer(), pos_integer()}}
          | {:error, {:exit, term()}}
          | {:error, {:bad_opt, term()}}

  # Caller-composed overrides for hooks, index fsmonitor, SSH command, external diff and global
  # attributes. These are not a complete Git sandbox: in-tree .gitattributes/filter drivers remain.
  # PayloadGuard separately rejects payload writes to .git and dangerous filter/diff attributes;
  # that content check does not validate every pre-existing or git-native workspace.
  @git_safe_config_args [
    "-c",
    "core.hooksPath=/dev/null",
    "-c",
    "core.fsmonitor=",
    "-c",
    "core.sshCommand=",
    "-c",
    "diff.external=",
    "-c",
    "core.attributesFile=/dev/null"
  ]

  @doc """
  Returns shared -c overrides for system-side Git on pod-writable workspaces.
  Callers must prepend them; git/2 does not. In-tree filters require separate content controls
  (see the list's comment and PayloadGuard), not just these config overrides.
  """
  @spec git_safe_config_args() :: [String.t()]
  def git_safe_config_args, do: @git_safe_config_args

  @doc """
  Runs Git with merged stdout/stderr. Options are timeout_ms (default #{@default_timeout_ms}),
  max_output_bytes (default #{@default_max_output_bytes}), cd, and env.
  Timeout/output limits must be positive integers. Timeout/overflow attempts group teardown
  and returns a typed error; non-zero command exits remain {:ok, {output, code}}.

  Missing env uses ForgeAuth.git_env/0 (terminal anti-prompt plus optional auth). Supplying env,
  including [], bypasses that default but retains inherited process variables. Default auth
  resolution precedes run/3's deadline and may degrade on errors; auth-required callers should
  resolve ForgeAuth.git_env_result/0 explicitly. See the module's timing and containment limits.
  """
  @spec git([String.t()], keyword()) :: result()
  def git(args, opts \\ []) when is_list(args) do
    env = Keyword.get_lazy(opts, :env, &Fleet.Credentials.ForgeAuth.git_env/0)
    run("git", args, Keyword.put(opts, :env, env))
  end

  @doc """
  Runs cmd/args via setsid and a port, using git/2's options without default ForgeAuth env.
  Requires binary cmd, a list of binary args and keyword options. Unknown keys and invalid
  supported values return bad_opt; malformed option containers/conversions can still raise.
  Error details may contain supplied option values, including env: do not assume they are redacted.
  Missing executables and caught port-open failures return exit errors.
  """
  @spec run(String.t(), [String.t()], keyword()) :: result()
  def run(cmd, args, opts \\ []) when is_binary(cmd) and is_list(args) do
    with {:ok, timeout_ms, max_output_bytes, env, cd} <- parse_run(args, opts),
         {:ok, exe, setsid} <- resolve_executables(cmd) do
      launch(setsid, exe, args, {timeout_ms, max_output_bytes, env, cd})
    end
  end

  # Require setsid rather than silently launching without an isolated group.
  defp resolve_executables(cmd) do
    case {System.find_executable(cmd), System.find_executable("setsid")} do
      {nil, _} -> {:error, {:exit, {:enoent, cmd}}}
      {_exe, nil} -> {:error, {:exit, {:enoent, "setsid"}}}
      {exe, setsid} -> {:ok, exe, setsid}
    end
  end

  # -w keeps a forking setsid wrapper alive so its child can be discovered for teardown.
  defp launch(setsid, exe, args, {timeout_ms, max_output_bytes, env, cd}) do
    port_opts =
      [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        :hide,
        {:args, ["-w", exe | args]},
        {:env, to_charlist_env(env)}
      ]
      |> maybe_put_cd(cd)

    with {:ok, port} <- safe_port_open(setsid, port_opts) do
      # An already-closed port may have no os_pid but still have data/exit messages to collect.
      os_pid = os_pid(port)

      # Compute once so sparse progress output cannot rearm an idle timeout.
      deadline = System.monotonic_time(:millisecond) + timeout_ms
      collect(port, os_pid, timeout_ms, deadline, [], 0, max_output_bytes)
    end
  end

  @run_opts [:timeout_ms, :max_output_bytes, :env, :cd]

  # Reject unknown keys such as timeout (instead of timeout_ms), or a caller's intended
  # deadline silently becomes the default. Keyword structure itself is an input precondition.
  defp parse_run(args, opts) do
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    max_output_bytes = Keyword.get(opts, :max_output_bytes, @default_max_output_bytes)
    env = Keyword.get(opts, :env, [])
    cd = Keyword.get(opts, :cd)

    # Name all unrecognised settings before diagnosing values of recognised ones.
    case Enum.uniq(Keyword.keys(opts)) -- @run_opts do
      [] ->
        with :ok <- valide(Enum.all?(args, &is_binary/1), :args),
             :ok <- valide(entier_positif?(timeout_ms), {:timeout_ms, timeout_ms}),
             :ok <-
               valide(entier_positif?(max_output_bytes), {:max_output_bytes, max_output_bytes}),
             :ok <- valide(paires_de_binaires?(env), {:env, env}),
             :ok <- valide(is_nil(cd) or is_binary(cd), {:cd, cd}) do
          {:ok, timeout_ms, max_output_bytes, env, cd}
        end

      unknown ->
        {:error, {:bad_opt, {:unknown, unknown}}}
    end
  end

  defp valide(true, _quoi), do: :ok
  defp valide(false, quoi), do: {:error, {:bad_opt, quoi}}

  defp entier_positif?(v), do: is_integer(v) and v > 0

  defp paires_de_binaires?(env) do
    is_list(env) and Enum.all?(env, &match?({k, v} when is_binary(k) and is_binary(v), &1))
  end

  # `Port.open` can still raise (badarg on a malformed spec/opts that slipped past the parse) → keep the
  # `result()` contract intact rather than crash the caller.
  defp safe_port_open(exe, port_opts) do
    {:ok, Port.open({:spawn_executable, exe}, port_opts)}
  rescue
    e -> {:error, {:exit, {:port_open, Exception.message(e)}}}
  catch
    kind, reason -> {:error, {:exit, {:port_open, {kind, reason}}}}
  end

  defp os_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} -> pid
      nil -> nil
    end
  end

  # Find a direct child's group, needed when setsid forks a session leader. /proc reads
  # race with process exits; nil also means unreadable data, not proof that no child exists.
  # In the forked case, -os_pid alone cannot replace a failed child-group lookup.
  defp child_pgid(parent_os_pid) do
    with {:ok, entries} <- File.ls("/proc"),
         child when is_binary(child) <- find_child(entries, parent_os_pid),
         {:ok, pgid} <- read_pgrp(child) do
      pgid
    else
      _ -> nil
    end
  end

  defp find_child(entries, parent_os_pid) do
    parent = to_string(parent_os_pid)

    Enum.find_value(entries, fn entry ->
      if pid_dir?(entry) and ppid_of(entry) == parent, do: entry, else: nil
    end)
  end

  defp pid_dir?(entry), do: Regex.match?(~r/^\d+$/, entry)

  defp ppid_of(pid), do: stat_field(pid, 1)

  defp read_pgrp(pid) do
    case stat_field(pid, 2) do
      nil ->
        :error

      s ->
        case Integer.parse(s) do
          {n, _} -> {:ok, n}
          :error -> :error
        end
    end
  end

  # Linux stat fields after the last ')' are state, ppid, pgrp, ...; comm may contain
  # spaces and parentheses, so splitting earlier would read the wrong process group.
  defp stat_field(pid, index) do
    case File.read("/proc/#{pid}/stat") do
      {:ok, stat} ->
        stat
        |> String.split(")")
        |> List.last()
        |> String.trim()
        |> String.split(" ")
        |> Enum.at(index)

      _ ->
        nil
    end
  end

  # Absolute remaining wait, not a fresh idle interval. Even after 0, receive handles matching
  # queued messages first, so a busy mailbox can delay timeout or deliver a late exit_status.
  defp collect(port, os_pid, timeout_ms, deadline, acc, bytes, max_bytes) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} ->
        # Count the received chunk before retaining it; reported bytes may exceed the cap.
        bytes = bytes + byte_size(data)

        if bytes > max_bytes do
          terminate(port, os_pid)
          {:error, {:output_overflow, bytes, max_bytes}}
        else
          collect(port, os_pid, timeout_ms, deadline, [data | acc], bytes, max_bytes)
        end

      {^port, {:exit_status, code}} ->
        {:ok, {acc |> Enum.reverse() |> IO.iodata_to_binary(), code}}
    after
      remaining ->
        terminate(port, os_pid)
        {:error, {:timeout, timeout_ms}}
    end
  end

  # Try group/PID signals then close the port, without waiting for proof of death. Command
  # return statuses are ignored; a failure to launch kill can raise before safe_close is reached.
  defp terminate(port, os_pid) do
    _ = kill_scope(os_pid)
    safe_close(port)
  end

  # Cover both setsid shapes: child session group when forked, os_pid group when exec'd
  # in place, then the wrapper PID. In the exec case the command may also have children;
  # their discovery does not remove the need to signal -os_pid. Nil means no known PID to signal.
  defp kill_scope(nil), do: :ok

  defp kill_scope(os_pid) do
    _ =
      case child_pgid(os_pid) do
        pgid when is_integer(pgid) -> kill_group(pgid)
        nil -> :ok
      end

    _ = kill_group(os_pid)
    kill_pid(os_pid)
  end

  # -- makes the negative PGID a target rather than a kill option.
  defp kill_group(pgid) do
    System.cmd("kill", ["-s", "KILL", "--", "-#{pgid}"], stderr_to_stdout: true)
  end

  defp kill_pid(pid) do
    System.cmd("kill", ["-s", "KILL", "--", to_string(pid)], stderr_to_stdout: true)
  end

  defp safe_close(port) do
    if Port.info(port), do: Port.close(port)
  rescue
    ArgumentError -> :ok
  end

  # Port env pairs use charlists; the public API accepts binaries.
  defp to_charlist_env(env) do
    Enum.map(env, fn {k, v} -> {to_charlist(k), to_charlist(v)} end)
  end

  defp maybe_put_cd(opts, nil), do: opts
  defp maybe_put_cd(opts, cd), do: [{:cd, to_charlist(cd)} | opts]
end
