defmodule Fleet.Credentials.Shell do
  @moduledoc """
  Execution bounded BY CONSTRUCTION of an external command (git, and more generally any
  slow/network binary). The boundary that makes an unbounded `System.cmd("git", …)` UNREPRESENTABLE
  on the PROJECT path: an external call ALWAYS has a deadline, and the deadline kills the child
  process — AND all its descendants — if it expires.

  ## Why a wrapper, not a per-call-site discipline

  `System.cmd/3` has **no native timeout**. A hung network git (slow DNS, TLS that hangs, an
  interrupted packfile) — or worse, a git that opens an interactive PROMPT for lack of a credential
  (no TTY → hangs forever) — blocks the calling process. On the PROJECT path that process is a
  GenServer (the `Fleet.Spawner.Pod` that clones, the `Fleet.Pilot.Poller` that merges): frozen, it
  no longer handles any message → **zombie pod / wedged issue**. This module extracts the bounded
  pattern into a reusable helper so that the bound lives in the TYPE of the call, not in the vigilance
  of each site.

  ## Two HARD properties of the bound

  ### 1. The deadline kills the whole process-GROUP, not just the top-level

  A network `git` does not run alone: it forks transport helpers (`git-remote-https`), credential
  helpers, filters. Killing ONLY the top-level process (`kill -KILL <os_pid>`) leaves these
  descendants alive after the deadline — they keep consuming resources/credentials and the forge auth
  extraheader stays in their environment. So we run the command in its **own session/process-group**
  (`setsid`) and, at the deadline, we kill the **whole GROUP** (`kill -KILL -<pgid>`): the top-level
  AND its entire descent die together. Field-verified (2026-06-24): a `bash -lc "sleep 30 & wait"`
  that detaches a descendant — `kill -KILL <top>` alone leaves the `sleep` a ZOMBIE, whereas
  `kill -KILL -<pgid>` takes it with it.

  ### 2. The deadline is a WALL (absolute wall-clock), not a re-armable idle-gap

  A hung-network git does not necessarily hang in silence: it can DRIP output (one byte every
  `timeout-1` ms — keepalive, a progress line dragging on). A `receive … after timeout_ms` loop that
  RE-ARMS on each `{:data}` would NEVER kill this git: each byte pushes the deadline back. Yet that is
  its target scenario. So we compute an **absolute deadline** (`monotonic_now + timeout_ms`) ONCE at
  startup; the `receive` loop waits only for the REMAINING time (`deadline - now`), never a re-armed
  `after timeout_ms`. The total wall-clock is bounded whatever the cadence of the output.
  Field-verified: a process that emits continuously (drip) is killed at the wall deadline.

  ## The process-group mechanism (setsid + PGID discovery)

  `setsid` places the command in a new session ⇒ it becomes the leader of its own process-group
  (`PGID == its PID`), distinct from the BEAM's. We run `setsid -w <cmd> <args>`: the `-w` option
  keeps the `setsid` wrapper ALIVE as parent (otherwise it fork-and-dies and the `os_pid` held by
  `Port.open` points at an already-dead wrapper, with no link to the real group). The port's `os_pid`
  is then `setsid`'s PID; the real process is its SOLE child, whose PGID we read via
  `/proc/<child>/stat` (`pgrp` field, Linux — documented target). PGID discovery is done AT THE MOMENT
  of the timeout (not right after the open: at that instant `setsid -w` has not necessarily forked the
  real process yet → discovery would return `nil`). At the timeout: `kill -s KILL -- -<child_pgid>`
  (whole group) then closing the port and `kill` of the `setsid` wrapper.

  ⚠ The `--` separator of `kill` is LOAD-BEARING: otherwise `/usr/bin/kill` (util-linux) reads the
  `-<pgid>` (starts with `-`) as an OPTION and returns rc 0 WITHOUT killing the group (field-verified
  2026-06-24). So we pass the signal via `-s KILL` then `--` then the negative target.

  If group discovery fails (rare race, /proc unavailable), we fall back to the wrapper's
  `kill -KILL <os_pid>`: an honest degradation (the wrapper dies, a detached descendant CAN survive) —
  but this is the edge case, not the nominal path, and it is implicitly logged by the absence of a
  group.

  ## Placement (compile cycle)

  `fleet_project_bootstrap` CANNOT depend on `fleet_workflow` nor `fleet_spawner` (compile cycle, cf.
  CLAUDE.md). `fleet_credentials` is BELOW all three (a common dependency) — it is already the owner
  of `Fleet.Credentials.ForgeAuth.git_env/0` for the same reason. So the wrapper lives here, reachable
  by bootstrap, workflow AND pilot without introducing a cycle.

  ## Default env

  Without `:env`, the system-side git env is injected (`ForgeAuth.git_env/0` → `GIT_TERMINAL_PROMPT=0`
  + auth extraheader if configured). A non-git caller passes `env: [...]` (or `env: []`).

  ## Split refused (audit judgment, 2026-07-05) — `git_safe_config_args/0` NOT extracted

  The config-hardening vocabulary (`@git_safe_config_args`) shares no helper with the execution
  machinery — a bundle flagged in the audit. The cut is REFUSED: the two are the two faces of THE SAME
  boundary "invoke git system-side without executing the pod's code" — the bound (deadline + kill-group
  + anti-prompt) closes the TIME/interaction vector, the `-c …` closes the CONFIG vector, and the
  consumers (`Fleet.Workflow.Git`/`DeliverableGate`) ALWAYS compose the two together on `git/2`. A
  one-function module would split the authority of this boundary across two files without decoupling
  anything (the API would remain here as a defdelegate). Co-location is the intended status quo.

  ## TYPED result (non-ignorable)

      {:ok, {output, exit_code}}        # the process returned within the deadline (exit_code may be ≠ 0)
      {:error, {:timeout, timeout_ms}}  # deadline exceeded → OS process-GROUP KILLED (SIGKILL) + port closed
      {:error, {:exit, reason}}         # binary not found / impossible to launch ({:enoent, cmd})

  The caller MUST match: an `{:error, {:timeout, _}}` is not a silent success.
  """

  require Logger

  @default_timeout_ms 30_000

  @type result ::
          {:ok, {String.t(), non_neg_integer()}}
          | {:error, {:timeout, pos_integer()}}
          | {:error, {:exit, term()}}
          | {:error, {:bad_opt, term()}}

  # Neutralization of the git MECHANISMS steerable from a repo's content, to compose (`-c …`)
  # into EVERY system-side git op (launched by the Elixir runtime, outside bwrap) on a workspace
  # co-written by an adversarial pod. SINGLE SOURCE: a site that forgets one of these knobs reopens
  # the hole; this list is THE definition of "system-side git neutralized", every site composes it
  # (NEVER copy the list elsewhere). Each flag renders INERT a code-execution vector that the pod
  # could arm in the `.git/config`, the `.gitattributes` or an includeIf:
  #
  #   * `core.hooksPath=/dev/null` — no hook (`pre-commit`/`pre-push`/… placed in `.git/hooks/`,
  #     or a `core.hooksPath` pointed elsewhere by the pod) executes on the world side.
  #   * `core.fsmonitor=` — disarms an fsmonitor program (launched by git when scanning the index).
  #   * `core.sshCommand=` — disarms a custom ssh command (launched by fetch/push over ssh).
  #   * `diff.external=` — disarms the external diff driver (launched by `git log -p`/`diff`/`show`,
  #     i.e. by the deliverable-gate ops that scan the `base..HEAD` diff).
  #   * `core.attributesFile=/dev/null` — neutralizes the GLOBAL attributes file (a `filter=`/`diff=`
  #     declared out-of-repo). NB: the IN-TREE `.gitattributes` is NOT disableable via `-c` (git has
  #     no "disable all filters" switch); a `filter.<name>.clean` in-tree with an arbitrary name stays
  #     executable by `git add`. The only real lock on the IN-TREE vector is therefore CONTENT-SIDE
  #     (fail-closed refusal of the payload that would write `.git/**` or a `.gitattributes` arming
  #     `filter=`/`diff=`, done by the caller that places the content), not this flag. This flag closes
  #     the GLOBAL-config vector.
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
  `-c <key>=<val>` arguments to prefix to EVERY system-side `git` invocation on a workspace
  co-written by a pod. SINGLE source of the config neutralization (hooks, fsmonitor, sshCommand,
  diff.external, global attributesFile); the sites compose it instead of recopying the list.
  See the comment on `@git_safe_config_args` for the WHY of each flag and the IN-TREE limit
  (the repo's `.gitattributes` filters are closed CONTENT-side, not via `-c`).
  """
  @spec git_safe_config_args() :: [String.t()]
  def git_safe_config_args, do: @git_safe_config_args

  @doc """
  Runs `git <args>` bounded. `output` = stdout+stderr merged (`stderr_to_stdout: true`, like every git
  site in the codebase). Options:

    * `:timeout_ms` — WALL deadline (default #{@default_timeout_ms} ms). Beyond it, the git OS
      process-GROUP is killed (`SIGKILL` to the group + port close) and we return `{:error, {:timeout, timeout_ms}}`.
    * `:cd` — execution directory.
    * `:env` — the child process's env. **Default**: `Fleet.Credentials.ForgeAuth.git_env/0` (carries
      `GIT_TERMINAL_PROMPT=0` → a git with no credential FAILS instead of prompting/hanging). Pass
      `env: [...]` to override, `env: []` for a bare env (but then the anti-prompt bound is lost —
      avoid on git).
  """
  @spec git([String.t()], keyword()) :: result()
  def git(args, opts \\ []) when is_list(args) do
    env = Keyword.get_lazy(opts, :env, &Fleet.Credentials.ForgeAuth.git_env/0)
    run("git", args, Keyword.put(opts, :env, env))
  end

  @doc """
  Runs `cmd <args>` bounded — the generic primitive under `git/2`. Same options as `git/2`, but
  **without** a default env (`env: []` if absent): `git/2` is the only one that injects `git_env/0`.

  ## The bound KILLS the OS process-GROUP (not just the BEAM, not just the top-level)

  Launched via `setsid` (new process-group) then `Port.open` to hold the `os_pid`. At the WALL
  deadline (absolute deadline, not a re-armable idle-gap), we kill the **whole GROUP** (`SIGKILL` to
  `-<pgid>`) AND close the port → the command and ALL its descendants (git transport helpers,
  credential helpers, filters) are really dead. There is no path to call this module without a deadline.
  """
  @spec run(String.t(), [String.t()], keyword()) :: result()
  def run(cmd, args, opts \\ []) when is_binary(cmd) and is_list(args) do
    case parse_run(args, opts) do
      {:error, _} = err ->
        err

      {:ok, timeout_ms, env, cd} ->
        case {System.find_executable(cmd), System.find_executable("setsid")} do
          {nil, _} ->
            {:error, {:exit, {:enoent, cmd}}}

          {_exe, nil} ->
            # `setsid` is the precondition of the killed-by-construction process-group (Linux: always
            # present via util-linux). Absent = we CANNOT guarantee the "whole group killed" invariant →
            # fail-closed rather than a false sense of security with a bare `System.cmd`.
            {:error, {:exit, {:enoent, "setsid"}}}

          {exe, setsid} ->
            # We run `setsid -w <exe> <args>`: `-w` keeps the wrapper ALIVE (parent of the real process),
            # otherwise it fork-and-dies and the port's os_pid points at nothing useful. The port's
            # executable is therefore `setsid`; its args = `["-w", exe | args]`.
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

            case safe_port_open(setsid, port_opts) do
              {:error, _} = err ->
                err

              {:ok, port} ->
                # `Port.info(:os_pid)` returns `nil` if the port is ALREADY closed (an ultra-fast command
                # finished between open and info) → no group to kill (the process is already gone); the
                # {:data}/{:exit_status} messages are still in the mailbox and `collect` drains them. nil = no-kill.
                os_pid = os_pid(port)

                # ABSOLUTE deadline computed ONCE: the `receive` loop waits only for the REMAINING time, so a
                # dripping output never pushes the deadline back (wall, not idle-gap). The PGID of the group to
                # kill is discovered AT THE MOMENT of the timeout (in `terminate`), not here: right after
                # `Port.open`, `setsid -w` has not necessarily forked the real process yet (race) → immediate
                # discovery would return `nil`. By the deadline, the process has run for `timeout_ms` → it is
                # there, fork included.
                deadline = System.monotonic_time(:millisecond) + timeout_ms
                collect(port, os_pid, timeout_ms, deadline, [])
            end
        end
    end
  end

  # Parse-don't-validate at the boundary: `run/3` promises `result()` for ANY caller, so bad opts become a
  # typed `{:error, {:bad_opt, _}}`, never a raise (a non-integer `timeout_ms` used to blow up on the
  # deadline `+`, a malformed `env`/`cd` in the charlist conversion). Prod callers (`git/2`) always pass
  # valid opts; this guards a direct/buggy caller so the contract holds.
  defp parse_run(args, opts) do
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    env = Keyword.get(opts, :env, [])
    cd = Keyword.get(opts, :cd)

    cond do
      not Enum.all?(args, &is_binary/1) ->
        {:error, {:bad_opt, :args}}

      not (is_integer(timeout_ms) and timeout_ms > 0) ->
        {:error, {:bad_opt, {:timeout_ms, timeout_ms}}}

      not (is_list(env) and Enum.all?(env, &match?({k, v} when is_binary(k) and is_binary(v), &1))) ->
        {:error, {:bad_opt, {:env, env}}}

      not (is_nil(cd) or is_binary(cd)) ->
        {:error, {:bad_opt, {:cd, cd}}}

      true ->
        {:ok, timeout_ms, env, cd}
    end
  end

  # `Port.open` can still raise (badarg on a malformed spec/opts that slipped past the parse) → keep the
  # `result()` contract intact rather than crash the caller.
  defp safe_port_open(setsid, port_opts) do
    {:ok, Port.open({:spawn_executable, setsid}, port_opts)}
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

  # PGID of the process-group to kill = that of the SOLE child of `setsid` (the real process). `setsid
  # -w` keeps the wrapper alive → the PPID link is stable for the duration of the discovery. We scan
  # `/proc` for the process whose PPID = the wrapper's os_pid, then read its `pgrp` field (field 5 of
  # `/proc/<pid>/stat`, after the `state` that follows the `(comm)` — comm may contain spaces/
  # parentheses, hence the split AFTER the last `)`). Linux only (documented target); any anomaly → nil
  # (the timeout falls back to `kill <os_pid>`, an honest degradation).
  defp child_pgid(nil), do: nil

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

  # PPID = field 4 of /proc/<pid>/stat; pgrp = field 5. The format is:
  #   pid (comm) state ppid pgrp ...
  # `comm` may contain spaces and parentheses → we cut AFTER the LAST `)` then
  # split on the space: [state, ppid, pgrp, ...].
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

  # Receive loop bounded by a WALL DEADLINE: accumulates the output, returns `{:ok, {output, exit_code}}`
  # on exit; at the deadline (REMAINING time exhausted), kills the process-GROUP and closes the port →
  # `{:error, {:timeout, timeout_ms}}`. The `after` value is `deadline - now` (never re-armed to
  # `timeout_ms`): a dripping output advances the loop but does NOT push the deadline back.
  defp collect(port, os_pid, timeout_ms, deadline, acc) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} ->
        collect(port, os_pid, timeout_ms, deadline, [data | acc])

      {^port, {:exit_status, code}} ->
        {:ok, {acc |> Enum.reverse() |> IO.iodata_to_binary(), code}}
    after
      remaining ->
        terminate(port, os_pid)
        {:error, {:timeout, timeout_ms}}
    end
  end

  # Kill at the deadline. The PGID of the group to kill = that of the REAL process (the child of
  # `setsid -w`), discovered NOW: the process has run for `timeout_ms` (fork included) → the discovery
  # is reliable, unlike right after the open where `setsid -w` has not necessarily forked yet. PREFERRED
  # target = the whole process-GROUP: the top-level AND all its descendants (git transport helpers,
  # filters) die together. Fallback if the PGID could not be discovered (process already gone / /proc
  # unavailable): we kill the `setsid` wrapper (an honest degradation). `kill` is best-effort (the
  # process may have died in the meantime). Then port close. nil = nothing to kill.
  defp terminate(port, os_pid) do
    _ =
      case child_pgid(os_pid) do
        pgid when is_integer(pgid) ->
          _ = kill_group(pgid)

          # The setsid wrapper itself is the leader of ANOTHER session (the BEAM's) → not in the
          # killed group; we finish it off separately so as not to leave the port half-alive.
          kill_pid(os_pid)

        nil ->
          kill_pid(os_pid)
      end

    safe_close(port)
  end

  # SIGKILL to the whole process-GROUP (negative PID = the group in `kill(2)` semantics). We pass the
  # signal via `-s KILL` and SEPARATE the target argument with `--`: otherwise `/usr/bin/kill`
  # (util-linux) reads the `-<pgid>` (starts with `-`) as an OPTION and NOT as a target → it returns
  # rc 0 WITHOUT killing the group (field-verified 2026-06-24: `kill -KILL -<pgid>` leaves the
  # descendant alive; `kill -s KILL -- -<pgid>` kills it). The `--` closes option parsing → the
  # `-<pgid>` is interpreted as the target.
  defp kill_group(pgid) do
    System.cmd("kill", ["-s", "KILL", "--", "-#{pgid}"], stderr_to_stdout: true)
  end

  # SIGKILL to a single PID (the setsid wrapper). `--` to stay homogeneous (a positive PID is not
  # ambiguous, but we keep the same defensive form).
  defp kill_pid(nil), do: :ok

  defp kill_pid(pid) do
    System.cmd("kill", ["-s", "KILL", "--", to_string(pid)], stderr_to_stdout: true)
  end

  defp safe_close(port) do
    if Port.info(port), do: Port.close(port)
  rescue
    ArgumentError -> :ok
  end

  # `Port.open env:` wants charlists ({~c"K", ~c"V"}); we accept the {String, String} of the codebase.
  defp to_charlist_env(env) do
    Enum.map(env, fn {k, v} -> {to_charlist(k), to_charlist(v)} end)
  end

  defp maybe_put_cd(opts, nil), do: opts
  defp maybe_put_cd(opts, cd), do: [{:cd, to_charlist(cd)} | opts]
end
