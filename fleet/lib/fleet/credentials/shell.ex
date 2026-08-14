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
  extraheader stays in their environment. The command runs in its **own session/process-group** (the
  port driver opens one per spawned executable, cf. below) and, at the deadline, we kill the
  **whole GROUP** (`kill -KILL -<pgid>`, where the PGID IS the port's `os_pid`): the top-level
  AND its entire descent die together. Verified: a `bash -lc "sleep 30 & wait"`
  that detaches a descendant — `kill -KILL <top>` alone leaves the `sleep` a ZOMBIE, whereas
  `kill -KILL -<pgid>` takes it with it.

  ### 2. The deadline is a WALL (absolute wall-clock), not a re-armable idle-gap

  A hung-network git does not necessarily hang in silence: it can DRIP output (one byte every
  `timeout-1` ms — keepalive, a progress line dragging on). A `receive … after timeout_ms` loop that
  RE-ARMS on each `{:data}` would NEVER kill this git: each byte pushes the deadline back. Yet that is
  its target scenario. So we compute an **absolute deadline** (`monotonic_now + timeout_ms`) ONCE at
  startup; the `receive` loop waits only for the REMAINING time (`deadline - now`), never a re-armed
  `after timeout_ms`. The total wall-clock is bounded whatever the cadence of the output.
  Verified: a process that emits continuously (drip) is killed at the wall deadline.

  ## The process-group mechanism — `os_pid` IS the PGID (6-031)

  The port's `os_pid` is the leader of its own session AND of its own process-group, so `PGID ==
  os_pid` and every descendant the command forks inherits that group. At the deadline, one gesture
  kills the whole descent: `kill -s KILL -- -<os_pid>`.

  ⚠ The `--` separator is LOAD-BEARING: otherwise `/usr/bin/kill` (util-linux) reads the `-<pgid>`
  (it starts with `-`) as an OPTION and returns rc 0 WITHOUT killing the group. Signal via
  `-s KILL`, then `--`, then the negative target.

  ### What this used to be, and why it was worse (6-031)

  It ran `setsid -w <cmd> <args>` and then SEARCHED for the PGID: scan `/proc` for the process whose
  PPID is the wrapper's `os_pid`, read its `pgrp`. Three `/proc` reads, and **if any one of them
  failed the code killed only the wrapper — the real command and its descendants survived, orphaned,
  while the caller received `{:error, {:timeout, _}}` and considered the operation over.** `/proc`
  absent or partial is the ordinary case in a hardened container or under a PID namespace.

  The measurement that removed the whole problem (2026-08-14): **the Erlang port driver already puts
  every spawned executable in a NEW SESSION**, so the port child is a group leader before `setsid`
  runs. `setsid`, seeing itself as a group leader, therefore FORKED — and its child got yet another
  session, distinct from `os_pid`'s. **The mechanism introduced to guarantee the group kill is
  exactly what made the group unknowable.** Dropping it makes the PGID an identity instead of a
  search: no `/proc`, no `setsid` dependency, no branch that can fail, and the "unresolvable PGID"
  case ceases to exist rather than being handled.

  ⚠ That runtime behaviour is an implementation detail of the port driver, not a documented promise.
  So it is **checked, not assumed**: `terminate/2` verifies `pgrp(os_pid) == os_pid` whenever `/proc`
  allows, and logs `error` if it ever stops holding — the claim is tendered by a measurement at the
  moment it matters, not by this paragraph.

  ## Placement (compile cycle)

  `Fleet.ProjectBootstrap` CANNOT depend on `Fleet.Workflow` nor `Fleet.Spawner` (it would close a
  compile cycle — the boundary declarations enforce it). The credentials domain is BELOW all three
  (a common dependency) — it is already the owner of `Fleet.Credentials.ForgeAuth.git_env/0` for the
  same reason. So the wrapper lives here, reachable by bootstrap, workflow AND pilot without
  introducing a cycle.

  ## Default env

  Without `:env`, the system-side git env is injected (`ForgeAuth.git_env/0` → `GIT_TERMINAL_PROMPT=0`
  + auth extraheader if configured). A non-git caller passes `env: [...]` (or `env: []`).

  ## Deliberately NOT split — `git_safe_config_args/0` stays in this module

  The config-hardening vocabulary (`@git_safe_config_args`) shares no helper with the execution
  machinery, yet the two are the two faces of THE SAME boundary "invoke git
  system-side without executing the pod's code" — the bound (deadline + kill-group
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
  # Codex audit F-04 (2026-07-19): the wall deadline bounds TIME, not MEMORY — a 20 MB output
  # was accepted whole (repro'd), and a hostile/verbose producer has the full timeout window to
  # fill the BEAM heap. 8 MiB is generous for every git site in the codebase (ls-remote,
  # rev-parse, push porcelain); larger flows must stream, not buffer.
  @default_max_output_bytes 8_388_608

  @type result ::
          {:ok, {String.t(), non_neg_integer()}}
          | {:error, {:timeout, pos_integer()}}
          | {:error, {:output_overflow, pos_integer(), pos_integer()}}
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
  #     `filter=`/`diff=`), not this flag. This flag closes the GLOBAL-config vector.
  #
  #     THAT LOCK IS `Fleet.Workflow.PayloadGuard`, and naming it is the point: this file
  #     DELIBERATELY does not cover the in-tree vector, and a reader who only sees the deliberate
  #     gap here has no way to learn whether anything covers it. Single dependency, both ends now
  #     named; the refusal itself is held by a test (`deliverable_test`, `:dangerous_gitattributes`),
  #     so the fact survives a prose purge.
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
    * `:max_output_bytes` — output cap (default #{@default_max_output_bytes} bytes). Beyond it,
      the process-GROUP is killed and we return `{:error, {:output_overflow, bytes, max}}` —
      the time deadline is NOT a memory bound (F-04).
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

  Launched by `Port.open`, which holds the `os_pid` — and that pid IS the process-group. At the WALL
  deadline (absolute deadline, not a re-armable idle-gap), we kill the **whole GROUP** (`SIGKILL` to
  `-<pgid>`) AND close the port → the command and ALL its descendants (git transport helpers,
  credential helpers, filters) are really dead. There is no path to call this module without a deadline.
  """
  @spec run(String.t(), [String.t()], keyword()) :: result()
  def run(cmd, args, opts \\ []) when is_binary(cmd) and is_list(args) do
    case parse_run(args, opts) do
      {:error, _} = err ->
        err

      {:ok, timeout_ms, max_output_bytes, env, cd} ->
        case System.find_executable(cmd) do
          nil ->
            {:error, {:exit, {:enoent, cmd}}}

          exe ->
            # 6-031 — LA COMMANDE EST LANCEE DIRECTEMENT, SANS ENVELOPPE `setsid`. Le port place deja
            # son enfant dans une nouvelle session (mesure du 2026-08-14), donc `os_pid` est chef de
            # groupe et le groupe a tuer EST `os_pid`. L'enveloppe d'avant, se voyant chef de groupe,
            # forkait — et son enfant recevait une session de plus, celle qu'il fallait ensuite
            # retrouver en fouillant `/proc`. Moins de processus, moins de dependances, et le PGID
            # devient une identite au lieu d'une recherche qui peut echouer.
            port_opts =
              [
                :binary,
                :exit_status,
                :stderr_to_stdout,
                :hide,
                {:args, args},
                {:env, to_charlist_env(env)}
              ]
              |> maybe_put_cd(cd)

            case safe_port_open(exe, port_opts) do
              {:error, _} = err ->
                err

              {:ok, port} ->
                # `Port.info(:os_pid)` returns `nil` if the port is ALREADY closed (an ultra-fast command
                # finished between open and info) → no group to kill (the process is already gone); the
                # {:data}/{:exit_status} messages are still in the mailbox and `collect` drains them. nil = no-kill.
                os_pid = os_pid(port)

                # ABSOLUTE deadline computed ONCE: the `receive` loop waits only for the REMAINING time, so a
                # dripping output never pushes the deadline back (wall, not idle-gap). The group to kill needs
                # no discovery and therefore no timing: it IS `os_pid` (6-031). The race this comment used to
                # describe — "wait for the timeout, the wrapper has forked by then" — was a property of the
                # `setsid` wrapper, and it left with it.
                deadline = System.monotonic_time(:millisecond) + timeout_ms
                collect(port, os_pid, timeout_ms, deadline, [], 0, max_output_bytes)
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
    max_output_bytes = Keyword.get(opts, :max_output_bytes, @default_max_output_bytes)
    env = Keyword.get(opts, :env, [])
    cd = Keyword.get(opts, :cd)

    cond do
      not Enum.all?(args, &is_binary/1) ->
        {:error, {:bad_opt, :args}}

      not (is_integer(timeout_ms) and timeout_ms > 0) ->
        {:error, {:bad_opt, {:timeout_ms, timeout_ms}}}

      not (is_integer(max_output_bytes) and max_output_bytes > 0) ->
        {:error, {:bad_opt, {:max_output_bytes, max_output_bytes}}}

      not (is_list(env) and Enum.all?(env, &match?({k, v} when is_binary(k) and is_binary(v), &1))) ->
        {:error, {:bad_opt, {:env, env}}}

      not (is_nil(cd) or is_binary(cd)) ->
        {:error, {:bad_opt, {:cd, cd}}}

      true ->
        {:ok, timeout_ms, max_output_bytes, env, cd}
    end
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

  # 6-031 — LA DECOUVERTE DU PGID A DISPARU AVEC L'ENVELOPPE QUI LA RENDAIT NECESSAIRE. Vivaient ici
  # `child_pgid/1`, `find_child/2`, `pid_dir?/1`, `ppid_of/1`, `read_pgrp/1` : trois lectures de
  # `/proc` pour retrouver l'enfant de `setsid`, dont l'echec silencieux laissait la descendance en
  # vie. Le seul reste est le lecteur ci-dessous, et il ne sert plus qu'a VERIFIER la premisse.
  #
  # pgrp = champ 5 de /proc/<pid>/stat. Le format est `pid (comm) state ppid pgrp …` et `comm` peut
  # contenir espaces et parentheses -> on coupe APRES le DERNIER `)` puis on decoupe sur l'espace :
  # [state, ppid, pgrp, …]. Linux seul, qui est la cible documentee de tout ce qui lit `/proc` ici.
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
  defp collect(port, os_pid, timeout_ms, deadline, acc, bytes, max_bytes) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} ->
        # MEMORY bound alongside the wall deadline (F-04): the deadline caps TIME only — a
        # continuous producer had the whole window to fill the heap. Kill the GROUP on overflow
        # (same gesture as the timeout) and return a typed error carrying size vs cap.
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

  # Kill at the deadline. The target is the whole process-GROUP — the top-level AND every descendant
  # (git transport helpers, filters) die together — and the group needs no discovery: it IS `os_pid`
  # (6-031). `kill`'s result is discarded: its expected failure is ESRCH — the target died in the
  # meantime — which IS the state we are driving toward, so the return carries nothing. Then port
  # close. `nil` os_pid = the port closed before we could read it = nothing to kill.
  defp terminate(port, os_pid) do
    _ = kill_scope(os_pid)
    safe_close(port)
  end

  # 6-031 — UN SEUL GESTE, ET IL NE PEUT PLUS ECHOUER A MI-CHEMIN. `os_pid` EST le PGID (cf.
  # @moduledoc), donc le groupe se nomme sans etre cherche. `kill_pid` derriere est une ceinture :
  # si le groupe est mort, il rend ESRCH et ne coute rien ; si la premisse ci-dessous est un jour
  # fausse, il reste le comportement d'avant plutot que rien.
  defp kill_scope(nil), do: :ok

  defp kill_scope(os_pid) do
    warn_if_not_group_leader(os_pid)
    _ = kill_group(os_pid)
    kill_pid(os_pid)
  end

  # LA PREMISSE EST VERIFIEE, PAS SUPPOSEE. Que le port place son enfant dans une session neuve est
  # un detail d'implementation du driver, pas une promesse documentee : si un jour il cesse d'etre
  # vrai, `-os_pid` ne nomme plus rien et une descendance survit a l'echeance EN SILENCE — c'est
  # exactement le defaut que 6-031 ferme. On le dit donc au moment ou ca compte.
  #
  # `/proc` illisible ne declenche RIEN : c'est l'environnement que cette fiche vise (conteneur
  # durci, espace de noms PID), et l'absence d'instrument n'est pas une anomalie du sujet. Le tir de
  # groupe a lieu quand meme — au pire `-os_pid` ne designe aucun groupe et rend ESRCH.
  defp warn_if_not_group_leader(os_pid) do
    case stat_field(os_pid, 2) do
      nil ->
        :ok

      pgrp ->
        unless pgrp == to_string(os_pid) do
          Logger.error(
            "Shell: os_pid #{os_pid} is NOT its own process-group leader (pgrp=#{pgrp}) — the port " <>
              "driver no longer opens a new session per spawned executable. The deadline kill " <>
              "targets a group that does not exist: DESCENDANTS CAN SURVIVE a timeout. See the " <>
              "process-group section of this module's @moduledoc."
          )
        end

        :ok
    end
  end

  # SIGKILL to the whole process-GROUP (negative PID = the group in `kill(2)` semantics). We pass the
  # signal via `-s KILL` and SEPARATE the target argument with `--`: otherwise `/usr/bin/kill`
  # (util-linux) reads the `-<pgid>` (starts with `-`) as an OPTION and NOT as a target → it returns
  # rc 0 WITHOUT killing the group (verified: `kill -KILL -<pgid>` leaves the
  # descendant alive; `kill -s KILL -- -<pgid>` kills it). The `--` closes option parsing → the
  # `-<pgid>` is interpreted as the target.
  defp kill_group(pgid) do
    System.cmd("kill", ["-s", "KILL", "--", "-#{pgid}"], stderr_to_stdout: true)
  end

  # SIGKILL to a single PID — the belt behind the group kill, cf. `kill_scope/1`. `--` to stay
  # homogeneous (a positive PID is not ambiguous, but we keep the same defensive form).
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
