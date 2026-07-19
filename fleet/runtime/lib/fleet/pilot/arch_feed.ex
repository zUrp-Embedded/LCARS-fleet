defmodule Fleet.Pilot.ArchFeed do
  @moduledoc """
  The architects' LOCAL activity feed — Bus consumer appending ONE short FR line per fleet
  milestone into the PROJECT's architect pod (`<arch pod_dir>/fleet.feed`, next to `turn.flag`,
  in-pod visibility `~/fleet.feed`). PER-PROJECT since the 2026-07-19 reorg: each event routes
  to the architect of ITS repo (`payload["repo"]` → `ProjectArchitect.pod_id_for/1`); an event
  with no repo, or a project whose arch is not up, drops the line — LOSSY by doctrine (the Bus
  is the lossy fast-path): the feed is a courtesy mirror, the truth is the forge.

  Lives in the PILOT domain (moved from spawner, reorg 2026-07-19): the lines are pilot
  vocabulary (bricks, verdicts, reworks) and the pod-id derivation is `ProjectArchitect`'s
  authority — spawner cannot depend upward on it. Started by the step rail
  (`Fleet.Pilot.Application.step_children!`): the feed renders step milestones, same lifecycle.

  The single PUSH: a DELIVERED brick (`step.unlocked` milestone `delivered`) also notifies the
  arch via `Fleet.Spawner.notify_pod/2` (typed flag message, NO kick net, zero send-keys — it
  must never cost the human a turn). Everything else is pull-only (the file).

  Axiom (reorg): a line NEVER names the repo — the arch has "the project", nothing else
  (issue numbers only).

  Test seams: `:subscribe` (default true), `:pod_info` (default `Fleet.Spawner.pod_info/1`),
  `:notify` (default `Fleet.Spawner.notify_pod/2`).

  **Last revised**: 2026-07-19
  """

  use GenServer
  require Logger

  alias Fleet.EventRouter.Bus
  alias Fleet.Pilot.ProjectArchitect

  @max_lines 200
  @feed_file "fleet.feed"

  # `step.unlocked` = the PROGRESS rail (user design 2026-07-18): every lock release IS a
  # step crossed, emitted at the gesture itself (after the forge reflects it — no announce
  # can run ahead of reality). The rest are the HYBRID ⚠/context events the lock mechanic
  # does not carry (failures, deliverable push, run ends).
  @watched [
    :"step.unlocked",
    :"deliverable.published",
    :"work_item.completed",
    :"pod.completed",
    :"pod.failed",
    :"spawn.failed",
    :"audit.verdict"
  ]

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
  def handle_info(%Fleet.Event{type: type, payload: payload}, state) when type in @watched do
    # PER-PROJECT routing: the event's repo names the architect. No repo → no route → drop
    # (courtesy feed; failures reach the arch via the escalation rail regardless).
    case payload["repo"] || payload[:repo] do
      repo when is_binary(repo) and repo != "" ->
        pod_id = ProjectArchitect.pod_id_for(repo)
        line = render_line(type, payload)
        _ = append(pod_id, line, state)

        # The ONLY push: a DELIVERED brick (the `:delivered` unlock — terminal milestone).
        if type == :"step.unlocked" and payload["milestone"] == "delivered",
          do: _ = state.notify.(pod_id, "info : " <> line)

      _ ->
        :ok
    end

    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # ── Rendering — one short FR line per milestone (the arch relays it to the human). ──
  # Axiom: the repo is NEVER named (the arch has "the project") — issue numbers only.

  defp render_line(:"step.unlocked", %{"milestone" => "delivered"} = p),
    do: "brique ##{p["number"]} LIVRÉE — mergée, scellée, verrou levé"

  defp render_line(:"step.unlocked", %{"milestone" => "verdict"} = p),
    do: "verdict rendu par #{p["role"]}#{ctx(p)}"

  defp render_line(:"step.unlocked", %{"milestone" => "rework"} = p),
    do: "retour au producteur (rework)#{ctx(p)}"

  defp render_line(:"step.unlocked", %{"milestone" => "handoff"} = p),
    do: "livraison remise aux juges#{ctx(p)}"

  defp render_line(:"step.unlocked", p),
    do: "étape franchie par #{p["role"] || "?"}#{ctx(p)}"

  defp render_line(:"deliverable.published", p),
    do: "livrable poussé#{ctx(p)} — PR en route"

  defp render_line(:"work_item.completed", p),
    do: "work-item terminé#{ctx(p)}"

  defp render_line(:"pod.completed", p),
    do: "pod #{p["pod_id"] || p[:pod_id] || "?"} a fini son run#{ctx(p)}"

  defp render_line(:"pod.failed", p),
    do: "⚠ pod #{p["pod_id"] || p[:pod_id] || "?"} en ÉCHEC#{ctx(p)}"

  defp render_line(:"spawn.failed", p),
    do: "⚠ spawn en ÉCHEC#{ctx(p)}"

  defp render_line(:"audit.verdict", p),
    do: "verdict de juge#{ctx(p)}"

  # Best-effort context suffix — ISSUE NUMBER only (payload shapes vary per producer; the feed is
  # a courtesy line, not a schema consumer). The repo never appears (axiom above).
  defp ctx(p) when is_map(p) do
    case p["issue"] || p[:issue] || p["number"] || p[:number] || p["issue_id"] || p[:issue_id] do
      nil -> ""
      issue -> " (##{issue})"
    end
  end

  defp ctx(_), do: ""

  # ── Feed file: append + bound (never a growing log) ──

  defp append(pod_id, line, state) do
    with {:ok, %{pod_dir: pod_dir}} when is_binary(pod_dir) <- state.pod_info.(pod_id) do
      path = Path.join(pod_dir, @feed_file)
      {{_y, _m, _d}, {h, mi, _s}} = :calendar.local_time()
      stamp = :io_lib.format("~2..0B:~2..0B", [h, mi]) |> IO.iodata_to_binary()

      existing =
        case File.read(path) do
          {:ok, content} -> String.split(content, "\n", trim: true)
          _ -> []
        end

      lines = Enum.take(existing ++ ["#{stamp} #{line}"], -@max_lines)

      case File.write(path, Enum.join(lines, "\n") <> "\n") do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning("ArchFeed: feed write failed (#{inspect(reason)}) — line dropped (lossy by doctrine)")
      end
    else
      # This project's arch is not up (not opened yet / test) → drop, lossy by doctrine.
      _ -> :ok
    end
  rescue
    e ->
      Logger.warning("ArchFeed: append raised (#{Exception.message(e)}) — line dropped (lossy by doctrine)")
      :ok
  end
end
