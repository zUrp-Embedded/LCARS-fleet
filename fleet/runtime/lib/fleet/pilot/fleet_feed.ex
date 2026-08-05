defmodule Fleet.Pilot.FleetFeed do
  @moduledoc """
  The front-desk's INCIDENT feed — Bus consumer appending one FR line per ESCALATED incident into
  the permanent starfleet pod (`<pod_dir>/fleet.feed`, in-pod `~/fleet.feed`), plus the typed flag
  notify.

  ## What was missing, and it was not a channel

  The runtime already establishes the fact and already writes it durably: `IncidentConsumer` routes
  `pod.failed` / `wake.failed` / `spawn.failed` / the Cat-5 rail into `IncidentRegistry`, which
  opens an `error_system` (or `error_cat5`) forge issue ASSIGNED TO STARFLEET. The escalation is
  complete, correct, and addressed to the right role.

  It just never arrived. Starfleet's tool surface is the portfolio head — create / import / open /
  revise / close a project — and carries NO forge read. The one role with a human in front of it
  cannot open the issue that names it as assignee. The fact was discovered by a probe, or not at
  all.

  ## Why ESCALATIONS and not failures

  Starfleet's fleet-blindness is deliberate and stays intact: it does not work on the projects and
  has no business knowing there are agents around it. Mirroring every `pod.failed` here would build
  a roster out of failures — the wrong answer, and the one this feed refuses.

  What it carries is the SUBSET the registry already decided deserves a human: an incident that
  passed the recurrence gate (or, for Cat-5, arrived at max severity). The throttling is therefore
  not this module's problem — it is the registry's cooldown, upstream, and the volume here is
  whatever that gate let through.

  ## Two axioms opposite to `ArchFeed`, and both follow from scope

  `ArchFeed` never names the repo (an architect has "the project", nothing else). Starfleet is
  fleet-scoped, so a line that does not say WHICH project is unactionable — the repo and the issue
  number ARE the line. And where `ArchFeed` pushes only on the terminal `:delivered` milestone,
  every line here pushes: an escalated incident is precisely the thing that must not wait for the
  agent to read a file on its next turn. The notify is the typed flag (no kick net, no send-keys) —
  it costs the human nothing.

  Lossy by doctrine, like its twin: no front desk, feed unwritable → the line is dropped. The truth
  is the forge issue; this is a courtesy mirror that makes it REACH someone. But a front desk that
  is UP and merely unreachable is a different fact from one that does not exist, and it is logged:
  a channel whose breakage is indistinguishable from its idle state is the defect this module was
  built to remove, and it would be absurd to rebuild it here.

  Test seams: `:subscribe` (default true), `:pod_info` (default `Fleet.Spawner.pod_info/1`),
  `:notify` (default `Fleet.Spawner.notify_pod/2`).

  **Last revised**: 2026-08-05
  """

  use GenServer
  require Logger

  alias Fleet.EventRouter.Bus
  alias Fleet.Pilot.PodFeed
  alias Fleet.Spawner.PermanentBoot

  # The front desk is a PERMANENT pod, so its id is derivable rather than looked up — one per
  # fleet, `boot_at_start`, the same identity for its whole life.
  @front_desk_role "starfleet"

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    if Keyword.get(opts, :subscribe, true), do: :ok = Bus.subscribe()

    {:ok,
     %{
       pod_info: Keyword.get(opts, :pod_info, &Fleet.Spawner.pod_info/1),
       notify: Keyword.get(opts, :notify, &Fleet.Spawner.notify_pod/2)
     }}
  end

  @impl true
  def handle_info(%Fleet.Event{type: :"incident.escalated", payload: payload}, state) do
    line = render_line(payload)
    pod_id = PermanentBoot.pod_id_for(@front_desk_role)

    deliver(state, pod_id, line)

    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # The two failures of `pod_info/1` are NOT the same fact, and collapsing them is what makes a
  # broken channel look like an idle one — the exact shape this module exists to end.
  #
  #   * `:not_found` — no front desk. Nothing to deliver to, nothing to say.
  #   * `:unreachable` — the front desk EXISTS and did not answer in time (`pod_info`'s own contract:
  #     a timeout is not a death proof). An alarm was not delivered to a LIVE reader, and that is
  #     worth a line in the log even though the feed itself stays lossy.
  defp deliver(state, pod_id, line) do
    case state.pod_info.(pod_id) do
      {:ok, %{pod_dir: pod_dir}} when is_binary(pod_dir) ->
        write_and_push(state, pod_id, pod_dir, line)

      {:error, :unreachable} ->
        Logger.warning(
          "FleetFeed: front desk #{pod_id} UNREACHABLE (alive, no answer) — escalation line dropped. " <>
            "The forge issue stands; the front desk was simply not told."
        )

      _ ->
        :ok
    end
  end

  defp write_and_push(state, pod_id, pod_dir, line) do
    case PodFeed.append(pod_dir, line) do
      :ok ->
        # EVERY escalation pushes. The gate that decides "does a human need this" already ran in the
        # registry; a feed line nobody is told about would re-introduce the polling this module
        # exists to remove.
        _ = state.notify.(pod_id, "info : " <> line)
        :ok

      {:error, reason} ->
        Logger.warning(
          "FleetFeed: feed write failed (#{inspect(reason)}) — line dropped (lossy by doctrine)"
        )
    end
  end

  # One line, self-sufficient for RELAYING: starfleet cannot open the issue (no forge tool), so the
  # line must be sayable to a human as-is. It names the kind, the subject and the address; the
  # diagnosis is not the front desk's job.
  defp render_line(payload) when is_map(payload) do
    "⚠ incident système ESCALADÉ (#{kind_fr(payload["kind"])}) sur `#{payload["subject"] || "?"}` " <>
      "— issue #{payload["repo"] || "?"}##{payload["number"] || "?"} " <>
      "[#{payload["label"] || "?"}]. À relayer à l'humain : le détail est dans l'issue."
  end

  defp render_line(_), do: "⚠ incident système ESCALADÉ — payload illisible, va voir la forge."

  # The registry's kinds, said in the operator's language. An unknown kind is PASSED THROUGH rather
  # than mapped to a default: a new escalation class must read as itself, not as a recurrence.
  defp kind_fr("recurrence"), do: "récurrence"
  defp kind_fr("reroll_failed"), do: "re-roll échoué"
  defp kind_fr("pod_failed"), do: "pod en échec répété"
  defp kind_fr("sp_suspect"), do: "SP suspect"
  defp kind_fr("cat5"), do: "CAT-5, sévérité max"
  defp kind_fr(other) when is_binary(other) and other != "", do: other
  defp kind_fr(_), do: "type inconnu"
end
