defmodule Fleet.Spawner.ArchFeed do
  @moduledoc """
  The architect's LOCAL activity feed — Bus consumer appending ONE short FR line per
  fleet milestone into `<arch pod_dir>/fleet.feed` (next to `turn.flag`, same in-pod
  visibility: `~/fleet.feed`).

  PULL side of the arch's situational awareness: the arch READS the file to answer the
  human's "où ça en est ?" instantly — no forge polling, no refresh. Writing a line NEVER
  wakes the arch. The single PUSH exception: the `:delivered` unlock (`step.unlocked`
  milestone — a DELIVERED brick, rare and meaningful) also sends an INFORMATIONAL wake via
  `Fleet.Spawner.notify_pod/2` (typed flag message, NO kick net, zero send-keys — it must
  never interfere with the human's typing; the arch relays "brique livrée" and does NOT
  `get_work_item`).

  LOSSY by doctrine (the Bus is the lossy fast-path): the feed is a courtesy mirror, the
  forge stays the truth. The file is BOUNDED (trimmed to the last #{200} lines on write).
  The arch pod id is read from the SAME config key as `Fleet.Pilot.Roles.architect_pod_id`
  (a module call would be a boundary cycle pilot→spawner→pilot; the config atom is the
  shared source, D-07).

  Test seams: `:subscribe` (default true), `:pod_info` (default `Fleet.Spawner.pod_info/1`),
  `:notify` (default `Fleet.Spawner.notify_pod/2`), `:arch_pod_id`.

  **Last revised**: 2026-07-18
  """

  use GenServer
  require Logger

  alias Fleet.EventRouter.Bus

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
       notify: Keyword.get(opts, :notify, &Fleet.Spawner.notify_pod/2),
       arch_pod_id:
         Keyword.get(opts, :arch_pod_id) ||
           Application.get_env(:fleet_pilot, :architect_pod_id, "permanent-architect")
     }}
  end

  @impl true
  def handle_info(%Fleet.Event{type: type, payload: payload}, state) when type in @watched do
    line = render_line(type, payload)
    _ = append(line, state)

    # The ONLY push: a DELIVERED brick (the `:delivered` unlock — terminal milestone).
    # Everything else stays pull-only (the feed).
    if type == :"step.unlocked" and payload["milestone"] == "delivered",
      do: _ = state.notify.(state.arch_pod_id, "info : " <> line)

    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # ── Rendering — one short FR line per milestone (the arch relays it to the human) ──

  defp render_line(:"step.unlocked", %{"milestone" => "delivered"} = p),
    do: "brique #{p["repo"]}##{p["number"]} LIVRÉE — mergée, scellée, verrou levé"

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

  # Best-effort context suffix from whatever the payload carries (payload shapes vary
  # per producer — the feed is a courtesy line, not a schema consumer).
  defp ctx(p) when is_map(p) do
    repo = p["repo"] || p[:repo]
    issue = p["issue"] || p[:issue] || p["number"] || p[:number] || p["issue_id"] || p[:issue_id]

    cond do
      repo && issue -> " (#{repo}##{issue})"
      issue -> " (#{issue})"
      repo -> " (#{repo})"
      true -> ""
    end
  end

  defp ctx(_), do: ""

  # ── Feed file: append + bound (never a growing log) ──

  defp append(line, state) do
    with {:ok, %{pod_dir: pod_dir}} when is_binary(pod_dir) <- state.pod_info.(state.arch_pod_id) do
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
      # No arch pod (not booted yet / test) → the line is dropped, lossy by doctrine.
      _ -> :ok
    end
  rescue
    e ->
      Logger.warning("ArchFeed: append raised (#{Exception.message(e)}) — line dropped (lossy by doctrine)")
      :ok
  end
end
