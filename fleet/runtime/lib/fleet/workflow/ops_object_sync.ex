defmodule Fleet.Workflow.OpsObjectSync do
  @moduledoc """
  Per-node SERIALIZER in front of `Fleet.Workflow.OpsObject` — the work/ops worktree gate.

  `OpsObject.commit_object/4` is the single parametric engine (write → `git add`/commit → best-effort
  push) but it runs DIRECTLY on the shared work/ops worktree. Its writers are concurrent and span
  domains:

    * BRIEFS — materialized from several MCP connections (`Delegation.physicalize`, a pod creating an
      issue) AND from the poller dispatch (`StepDispatcher.Spawn`);
    * PROVENANCE — from up to 16 concurrent completion `Task`s (`StepRunConsumer` offload pool).

  Two operations on the SAME project's work_dir can collide on `.git/index.lock`, or observe a HEAD
  that moved between OpsObject's idempotency probe (`File.read == content` / `last_commit_sha`) and
  the commit. `OpsObject`'s own comment only covers the "identical content → nothing_to_commit" race,
  not concurrent git. This GenServer closes it by construction — same move as `Fleet.Pilot.WorktreeSync`
  for the post-merge `reset --hard`: it handles one message at a time → ONE git transaction at a time,
  whatever the number of triggers. `OpsObject` stays the untouched engine; this is only the gate.

  The gate is deliberately WIDER than the hazard it closes, and that widening is the thing to know
  before touching it: the collision is per-`work_dir` (one worktree per project → one `.git/index.lock`
  per project), but the serializer is ONE node-global process — `work_dir` travels as payload, never as
  a routing key. So a commit for project B queues behind project A's even though they share no lock. It
  is a chosen simplicity (no Registry, no per-project process lifecycle); its price is cross-project
  head-of-line blocking, bounded by the caller's call budget and widened by the push staying inside
  the transaction. A queue whose composed budget exceeds that call timeout no longer loses its
  result: on a caller timeout `commit_object/5` does a READ-ONLY readback (`OpsObject.committed_sha`,
  no lock) and returns the sha if the transaction landed — a false-negative timeout can no longer make
  a landed brief look unmaterialized. Sharding per `work_dir` (`:via` a Registry) is the exit if the
  head-of-line blocking ever bites. The node-wide scope IS pinned since 2026-08-03 (BL-6-43.4,
  `ops_object_sync_test.exs`): two different `work_dir`s committed through one explicitly-named
  instance, both landing, neither cross-writing. What that test holds is the ROUTING KEY — the
  server is the only address, `work_dir` is payload — which is the first thing a sharding refactor
  changes. It deliberately does NOT pin mutual exclusion across `work_dir`s by timing: proving
  "these two never overlapped" takes a clock, and a clock in a test buys flakiness rather than
  truth.

  ## SYNCHRONOUS (unlike WorktreeSync)

  WorktreeSync is a cast (the merge does not wait, the clone is a mirror). Here the return — the
  introducing COMMIT sha — IS the committed object's IDENTITY, consumed by `BriefArtifact`/`Provenance`.
  So `commit_object/4` is a `call`: it serializes AND returns the sha. The best-effort push stays inside
  the transaction (as WorktreeSync's `fetch` is inside its handler); if work/ops push throughput ever
  proves a bottleneck, moving the push out of the critical section is safe (it touches refs, not
  `.git/index.lock`, and is already race-tolerant) — noted, not needed.

  ## Always-on in prod + `Process.whereis` fallback (hermetic in test)

  Supervised by `Fleet.Pilot.Application` (next to the ForgeFinch pool, for the SAME reason: MCP
  `create_issue` materializes briefs OUTSIDE the step rail, so the gate must exist as soon as the node
  boots, not only in `:step_dispatch?` mode). When the process is up, every writer funnels through it.
  When it is NOT registered, `commit_object/4` falls back to a DIRECT `OpsObject` call: the LOCAL
  transaction is identical, only the cross-writer serialization is skipped. Not a masked failure — an
  optional serialization layer, exactly like WorktreeSync's cast being dropped when it is not started.

  **In `:test` the singleton is NOT started** (`start_ops_object_sync: false`): the whole suite takes
  the direct fallback, so `OpsObject`'s logs stay in the CALLER's process (pre-CI-11 behavior) — routing
  every async test's write through one shared process would serialize + relocate those logs and worsen
  `capture_log` bleed. The serialization itself is proven in isolation by `OpsObjectSyncTest`, which
  starts its OWN instance (custom name) and drives the explicit-server `commit_object/5`.

  **Last revised**: 2026-08-03
  """

  use GenServer
  require Logger

  alias Fleet.Workflow.OpsObject

  # Generous: a single transaction is write + local commit + a best-effort push (network to the forge);
  # under a burst, callers queue behind it. Mirrors WorktreeSync's 60s call budget.
  @default_call_timeout 60_000

  # Configurable for tests (a tiny value + a non-responding server exercises the timeout readback);
  # prod keeps the 60s budget. A LONGER budget would only defer, not remove, the composed-budget
  # overrun the readback now handles safely.
  defp call_timeout,
    do: Application.get_env(:fleet_workflow, :ops_sync_call_timeout, @default_call_timeout)

  # The drain-confirm budget: how long the post-timeout ping may wait for the queue (ours included)
  # to finish. Default = one more full call budget; its own knob so tests drive the wedged-vs-drained
  # branches deterministically.
  defp drain_timeout,
    do: Application.get_env(:fleet_workflow, :ops_sync_drain_timeout, call_timeout())

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Serialized `OpsObject.commit_object/4` on the global singleton — same signature (arity 4), same
  return. Routes through the process when it is up (one git transaction at a time per node); falls back
  to a direct `OpsObject` call otherwise (cf. moduledoc).
  """
  @spec commit_object(Path.t(), String.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def commit_object(work_dir, ref, content, opts),
    do: commit_object(__MODULE__, work_dir, ref, content, opts)

  @doc """
  Explicit-server variant: routes through `server` (name or pid) when it is alive, else the direct
  `OpsObject` fallback. Lets a test drive an ISOLATED instance (custom name) without touching the
  global singleton that the rest of the suite resolves.
  """
  @spec commit_object(GenServer.server(), Path.t(), String.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def commit_object(server, work_dir, ref, content, opts)
      when is_binary(work_dir) and is_binary(ref) and is_binary(content) do
    case resolve(server) do
      nil ->
        # The direct path is the DOCUMENTED optional-layer posture (moduledoc) — but in a
        # booted daemon whose config STARTS the serializer, reaching it means the gate is
        # DOWN (supervised restart window, crash loop): said loud, per call — bypassing a
        # serialization gate must never be silent. The deliberate no-serializer modes
        # (:test hermeticity, standalone tooling) configure it off and stay quiet.
        if Application.get_env(:fleet_pilot, :start_ops_object_sync, true) do
          Logger.warning(
            "OpsObjectSync: serializer NOT registered — direct OpsObject write " <>
              "(cross-writer serialization skipped; restart window or crash loop)"
          )
        end

        OpsObject.commit_object(work_dir, ref, content, opts)

      pid ->
        try do
          GenServer.call(pid, {:commit, work_dir, ref, content, opts}, call_timeout())
        catch
          # A caller TIMEOUT does not undo the server's work: our transaction may be mid-flight (or
          # queued behind others whose composed budget exceeds @call_timeout), and the server keeps
          # going after our exit. A blind retry would either duplicate or — worse — race the live
          # server on the same work_dir (the very `.git/index.lock` collision this serializer
          # prevents). The verdict is sought in TWO steps (`confirm_after_timeout`): an immediate
          # read-only readback (already landed?), then — because a NEGATIVE immediate readback proves
          # nothing while our commit may still be queued or mid-flight — a DRAIN-CONFIRM: a sync ping
          # that the server answers only AFTER every message ahead of it (ours included), making the
          # second readback DEFINITIVE. Only a ping that itself times out (server wedged) leaves the
          # verdict genuinely ambiguous.
          :exit, {:timeout, _} = reason ->
            confirm_after_timeout(pid, work_dir, ref, content, reason)

          # NON-timeout exit (:noproc — server died between resolve and call —, :shutdown, a crash
          # mid-call): this path is reached from best-effort provenance callers, and an uncaught exit
          # crashed THEM for a serializer hiccup. Classify instead: the work may have landed just
          # before the death (readback), otherwise a typed unavailability — never a caller crash.
          :exit, reason ->
            case OpsObject.committed_sha(work_dir, ref, content) do
              {:ok, sha} ->
                Logger.warning(
                  "OpsObjectSync: serializer exited (#{inspect(reason)}) but #{ref} is committed " <>
                    "(#{String.slice(sha, 0, 12)}) — transaction LANDED before the exit"
                )

                {:ok, sha}

              :not_committed ->
                {:error, {:ops_sync_unavailable, reason}}
            end
        end
    end
  end

  # The two-step post-timeout verdict. Step 1: immediate readback — landed? Step 2 (the step whose
  # absence made a negative verdict a LIE): drain-confirm. The server processes its mailbox in
  # order, so a sync ping enqueued NOW returns only after our original {:commit, …} has fully run —
  # the readback after it is DEFINITIVE: landed-late ({:ok, sha}, the caller never wrongly told
  # failure while the effect lands behind its back) or genuinely not-landed (the commit RAN and
  # failed server-side; its error reply was lost with our abandoned call — surfaced as the same
  # `:ops_sync_timeout` shape, logged as definitive). A ping that itself times out = server wedged →
  # the only remaining honestly-ambiguous case.
  defp confirm_after_timeout(pid, work_dir, ref, content, reason) do
    case OpsObject.committed_sha(work_dir, ref, content) do
      {:ok, sha} ->
        Logger.warning(
          "OpsObjectSync: call timed out but #{ref} is already committed (#{String.slice(sha, 0, 12)}) " <>
            "— transaction LANDED, confirmed by read-only readback (no retry, no race)"
        )

        {:ok, sha}

      :not_committed ->
        try do
          :drained = GenServer.call(pid, :drain_confirm, drain_timeout())

          case OpsObject.committed_sha(work_dir, ref, content) do
            {:ok, sha} ->
              Logger.warning(
                "OpsObjectSync: call timed out, #{ref} LANDED during drain-confirm " <>
                  "(#{String.slice(sha, 0, 12)}) — late but definitive, no false failure"
              )

              {:ok, sha}

            :not_committed ->
              Logger.warning(
                "OpsObjectSync: drain-confirm complete and #{ref} NOT committed — the transaction " <>
                  "ran and failed server-side (definitive, not ambiguous)"
              )

              {:error, {:ops_sync_timeout, reason}}
          end
        catch
          :exit, _drain_exit ->
            # The ping itself timed out / died: the server is wedged or the queue exceeds a second
            # full budget — genuinely ambiguous, the one case the caller must treat as unknown.
            {:error, {:ops_sync_timeout, reason}}
        end
    end
  end

  defp resolve(pid) when is_pid(pid), do: pid
  defp resolve(name) when is_atom(name), do: Process.whereis(name)

  @impl GenServer
  def init(opts) do
    # `commit_fun` — test seam ONLY (a hermetic test injects a slow/failing engine to drive the
    # timeout + drain-confirm paths deterministically); prod = the real `OpsObject` engine.
    {:ok, %{commit_fun: Keyword.get(opts, :commit_fun, &OpsObject.commit_object/4)}}
  end

  # One message at a time → the git transactions of ALL concurrent writers are serialized, never two
  # `git` on the same work/ops worktree (the `.git/index.lock` + moving-HEAD race). The engine is
  # `OpsObject` verbatim (via the seam): no logic here, only the ordering.
  @impl GenServer
  def handle_call({:commit, work_dir, ref, content, opts}, _from, state) do
    {:reply, state.commit_fun.(work_dir, ref, content, opts), state}
  end

  # Drain-confirm ping (cf. `confirm_after_timeout/5`): answered only once every message ahead of
  # it has been processed — the mailbox IS the proof, this clause carries no logic.
  def handle_call(:drain_confirm, _from, state), do: {:reply, :drained, state}
end
