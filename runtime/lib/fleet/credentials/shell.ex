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
  descendants alive after the deadline — they keep consuming resources and **the forge auth
  extraheader stays in their environment**. So the command runs in its **own session/process-group**
  and the deadline kills the **whole GROUP**: the top-level and its entire descent die together.
  Killing the top-level alone leaves a detached descendant running.

  ### 2. The deadline is a WALL (absolute wall-clock), not a re-armable idle-gap

  A hung-network git does not necessarily hang in silence: it can DRIP output (one byte every
  `timeout-1` ms — keepalive, a progress line dragging on). A `receive … after timeout_ms` loop that
  RE-ARMS on each `{:data}` would NEVER kill this git: each byte pushes the deadline back. Yet that is
  its target scenario. The deadline is therefore computed ONCE at startup and the loop waits only
  for the REMAINING time, never a re-armed `after timeout_ms`. The total wall-clock is bounded
  whatever the cadence of the output.

  ## The process-group mechanism — `setsid`, and TWO states to cover (6-031)

  The command runs under `setsid -w`, which guarantees the real process is a session leader — so it
  leads its own process-group and every descendant it forks inherits it. At the deadline we kill
  that group: `kill -s KILL -- -<pgid>`.

  ⚠ The `--` separator is LOAD-BEARING: otherwise `/usr/bin/kill` (util-linux) reads the `-<pgid>`
  (it starts with `-`) as an OPTION and returns rc 0 WITHOUT killing the group. Signal via
  `-s KILL`, then `--`, then the negative target.

  ### Which pid is the leader depends on the environment, and BOTH cases are live here

  `setsid` forks only if it is ALREADY a process-group leader, so:

    * when the port driver hands its child a fresh session, `setsid` FORKS — the real process is its
      only child, and `os_pid` is the WRAPPER, not the pgid to kill;
    * when the port child inherits the BEAM's group, `setsid` does NOT fork — it execs in place and
      `os_pid` IS the pgid.

  The teardown covers both without telling them apart: it kills the discovered child's group when
  there is a child, and ALWAYS also kills `-os_pid`. One of the two shots is a no-op; the other is
  the whole group. Killing only `os_pid` leaves the descendants ORPHANED while the caller is told
  the operation timed out and is over.

  ⚠ **Dropping `setsid` "because the port driver already opens a session" is green on the machine
  where that is true and RED where it is not** — there, `-os_pid` names no group at all. The lesson
  is in the shape of the measurement, not in the mechanism: **a runtime behaviour measured on ONE
  machine is a property of that machine until a second one agrees.**

  ## Placement (compile cycle)

  `Fleet.ProjectBootstrap` CANNOT depend on `Fleet.Workflow` nor `Fleet.Spawner` (it would close a
  compile cycle — the boundary declarations enforce it). The credentials domain is BELOW all three
  (a common dependency) — it is already the owner of `Fleet.Credentials.ForgeAuth.git_env/0` for the
  same reason. So the wrapper lives here, reachable by bootstrap, workflow AND pilot without
  introducing a cycle.

  ## Default env

  Without `:env`, the system-side git env is injected (`ForgeAuth.git_env/0` → `GIT_TERMINAL_PROMPT=0`
  + auth extraheader if configured). A non-git caller passes `env: [...]` (or `env: []`).

  ## Deliberately NOT split

  The config-hardening vocabulary shares no helper with the execution machinery, yet both are faces
  of THE SAME boundary — "invoke git system-side without executing the pod's code". The bound closes
  the TIME vector, the config args close the CONFIG vector, and every consumer composes the two.
  Splitting would scatter the authority of one boundary across two files without decoupling anything.

  ## TYPED result (non-ignorable)

      {:ok, {output, exit_code}}        # the process returned within the deadline (exit_code may be ≠ 0)
      {:error, {:timeout, timeout_ms}}  # deadline exceeded → OS process-GROUP KILLED (SIGKILL) + port closed
      {:error, {:exit, reason}}         # binary not found / impossible to launch ({:enoent, cmd})

  The caller MUST match: an `{:error, {:timeout, _}}` is not a silent success.
  """

  @default_timeout_ms 30_000
  # F-04 — the wall deadline bounds TIME, not MEMORY: a 20 MB output is accepted whole (repro'd),
  # and a hostile/verbose producer has the full timeout window to
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

  Launched via `setsid` (new session) then `Port.open` to hold the `os_pid`. At the WALL
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
        case {System.find_executable(cmd), System.find_executable("setsid")} do
          {nil, _} ->
            {:error, {:exit, {:enoent, cmd}}}

          {_exe, nil} ->
            # `setsid` est la precondition du groupe tue par construction (Linux : toujours present
            # via util-linux). Absent = on NE PEUT PAS garantir l'invariant « tout le groupe meurt »
            # -> fail-closed, plutot qu'un faux sentiment de securite avec un `System.cmd` nu.
            {:error, {:exit, {:enoent, "setsid"}}}

          {exe, setsid} ->
            # ⚠ L'ENVELOPPE RESTE — les deux etats de `setsid` et pourquoi la retirer casse hors du
            # poste ou on l'a mesuree sont dans le `@moduledoc`.
            #
            # `-w` GARDE L'ENVELOPPE VIVANTE comme parent du vrai processus : sans lui elle
            # fork-and-die, et l'`os_pid` du port ne pointe plus sur rien d'utile.
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
                # dripping output never pushes the deadline back (wall, not idle-gap). The group to kill is
                # resolved at KILL time by `kill_scope/1`, which covers both `setsid` states (6-031) — nothing
                # here depends on when the wrapper forks.
                deadline = System.monotonic_time(:millisecond) + timeout_ms
                collect(port, os_pid, timeout_ms, deadline, [], 0, max_output_bytes)
            end
        end
    end
  end

  # THE ONLY OPTIONS THIS RUNNER HONOURS. Anything else is refused by name — see the scar below.
  @run_opts [:timeout_ms, :max_output_bytes, :env, :cd]

  # Parse-don't-validate at the boundary: `run/3` promises `result()` for ANY caller, so bad opts become a
  # typed `{:error, {:bad_opt, _}}`, never a raise (a non-integer `timeout_ms` would blow up on the
  # deadline `+`, a malformed `env`/`cd` in the charlist conversion). Prod callers (`git/2`) always pass
  # valid opts; this guards a direct/buggy caller so the contract holds.
  #
  # ⚠ VALIDATING THE KEYS IT KNOWS AND IGNORING THE REST GUARDED ONLY THE MISTAKES NOBODY MAKES.
  # Measured on `MCP.PodTools.ProjectPublish`: it declared a 15-minute wall for a rail that re-clones
  # a repository and rewrites its whole history, then passed it as `timeout:`. This function reads
  # `:timeout_ms`. The option was absorbed without a word, the rail ran on the 30 s default — thirty
  # times less than the intent written two lines above the call — and the failure surfaced as a
  # generic `:timeout`, under a constant announcing fifteen minutes to whoever came to diagnose.
  # A typed refusal on an unknown key is what turns that class of typo into a caller that cannot
  # start, instead of one that silently runs on a default.
  defp parse_run(args, opts) do
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    max_output_bytes = Keyword.get(opts, :max_output_bytes, @default_max_output_bytes)
    env = Keyword.get(opts, :env, [])
    cd = Keyword.get(opts, :cd)

    cond do
      # FIRST, and the order is the point: an unknown key means the caller's intent was never
      # applied at all. Reporting a value problem before a key problem would send the reader to
      # inspect a setting that was never read.
      (unknown = Enum.uniq(Keyword.keys(opts)) -- @run_opts) != [] ->
        {:error, {:bad_opt, {:unknown, unknown}}}

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

  # PGID du groupe a tuer quand `setsid` A FORKE : celui de son unique enfant (le vrai processus).
  # `-w` garde l'enveloppe vivante, donc le lien PPID est stable le temps de la recherche. On
  # balaie `/proc` a la recherche du processus dont le PPID vaut l'os_pid de l'enveloppe, puis on
  # lit son `pgrp`. `nil` = pas d'enfant, ce qui est le cas NORMAL quand `setsid` ne forke pas
  # (`os_pid` est alors lui-meme le chef de groupe) et le cas degrade quand `/proc` est illisible.
  # Les deux sont couverts par le tir sur `-os_pid` de `kill_scope/1` — voir son commentaire.
  # `nil` en ENTREE est impossible ici : `kill_scope/1` l'absorbe avant d'appeler (clause prouvee
  # inatteignable par le type checker).
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

  # ppid = champ 4 et pgrp = champ 5 de /proc/<pid>/stat. Le format est `pid (comm) state ppid pgrp
  # …` et `comm` peut contenir espaces et parentheses -> on coupe APRES le DERNIER `)` puis on
  # decoupe sur l'espace : [state, ppid, pgrp, …]. Linux seul, qui est la cible documentee de tout
  # ce qui lit `/proc` ici.
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

  # Kill at the deadline: the whole process-GROUP, so the top-level AND every descendant (git
  # transport helpers, filters) die together. `kill`'s result is discarded — its expected failure is
  # ESRCH, the target died in the meantime, which IS the state we are driving toward. Then port
  # close. `nil` os_pid = the port closed before we could read it = nothing to kill.
  defp terminate(port, os_pid) do
    _ = kill_scope(os_pid)
    safe_close(port)
  end

  # 6-031 — LES DEUX ETATS DE `setsid` SONT COUVERTS SANS AVOIR A LES DISTINGUER, et c'est ce qui
  # ferme le defaut de la fiche : plus aucune branche ne rend la main en laissant la descendance
  # en vie.
  #
  #   * `setsid` A FORKE (poste de dev) : le vrai processus est son unique enfant. `child_pgid/1`
  #     le trouve via `/proc` et on tue SON groupe ; l'enveloppe, elle, est dans une autre session
  #     et se tue separement.
  #   * `setsid` N'A PAS FORKE (conteneur de CI) : il s'est execute en place, donc `os_pid` EST le
  #     chef du groupe — et `child_pgid/1` ne trouve rien, puisqu'il n'y a pas d'enfant. C'est
  #     exactement ce cas que l'ancien code traitait en ne tuant QUE `os_pid`, laissant la
  #     descendance orpheline.
  #
  # Le tir sur `-os_pid` est donc AJOUTE inconditionnellement, et il est sur dans les deux etats :
  # `setsid` garantit que `os_pid` est chef de session (donc de groupe) OU que son enfant l'est.
  # Jamais `os_pid` ne partage le groupe du BEAM apres `setsid` — sans quoi `-os_pid` ne designerait
  # aucun groupe (ESRCH) plutot que le mauvais.
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
  # homogeneous (a positive PID is not ambiguous, but we keep the same defensive form). A `nil`
  # never reaches here: `kill_scope/1` absorbs it first (clause proven unreachable by the type checker).
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
