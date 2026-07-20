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

  **Last revised**: 2026-07-20
  """

  use GenServer

  alias Fleet.Workflow.OpsObject

  # Generous: a single transaction is write + local commit + a best-effort push (network to the forge);
  # under a burst, callers queue behind it. Mirrors WorktreeSync's 60s call budget.
  @call_timeout 60_000

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
        OpsObject.commit_object(work_dir, ref, content, opts)

      pid ->
        GenServer.call(pid, {:commit, work_dir, ref, content, opts}, @call_timeout)
    end
  end

  defp resolve(pid) when is_pid(pid), do: pid
  defp resolve(name) when is_atom(name), do: Process.whereis(name)

  @impl GenServer
  def init(_opts), do: {:ok, %{}}

  # One message at a time → the git transactions of ALL concurrent writers are serialized, never two
  # `git` on the same work/ops worktree (the `.git/index.lock` + moving-HEAD race). The engine is
  # `OpsObject` verbatim: no logic here, only the ordering.
  @impl GenServer
  def handle_call({:commit, work_dir, ref, content, opts}, _from, state) do
    {:reply, OpsObject.commit_object(work_dir, ref, content, opts), state}
  end
end
