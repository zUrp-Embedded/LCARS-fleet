defmodule Fleet.Pilot.ArchFeed do
  @moduledoc """
  Lossy per-project activity feed for step milestones. Route event repo through
  Project.Architect.pod_id_for and append via PodFeed to the architect's fleet.feed.
  Events without repo or resolvable pod_dir lose their line. A delivered step.unlocked
  also attempts notify_pod, even if append did not succeed; other events only append.

  Titles are read synchronously from the forge at render time, best effort, without
  a cache. The feed is not replayed as state. Formatting adds no explicit repo field,
  but embedded titles/pod ids are not redacted. PodFeed owns stamping and bounds.

  Options: subscribe (true), pod_info (Spawner.pod_info), notify (Spawner.notify_pod)
  and forge (Forge.Client). Title lookup catches failures; other injected callbacks
  can still raise. Started with the step rail because its vocabulary is Pilot's.
  """

  use GenServer
  require Logger

  alias Fleet.EventRouter.Bus
  alias Fleet.Pilot.PodFeed
  alias Fleet.Project.Architect, as: ProjectArchitect

  # Unlock milestones describe progress; other watched events add execution/failure context.
  @watched [
    :"step.unlocked",
    :"deliverable.published",
    :"work_item.completed",
    :"pod.spawned",
    :"pod.completed",
    :"pod.failed",
    :"spawn.failed"
  ]

  @spec start_link(keyword()) :: GenServer.on_start()
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
       forge: Keyword.get(opts, :forge, Fleet.Forge.Client)
     }}
  end

  @impl true
  def handle_info(%Fleet.Event{type: type, payload: payload}, state) when type in @watched do
    case payload["repo"] || payload[:repo] do
      repo when is_binary(repo) and repo != "" ->
        pod_id = ProjectArchitect.pod_id_for(repo)
        line = render_line(type, annotate_title(payload, repo, state))
        _ = append(pod_id, line, state)

        if type == :"step.unlocked" and payload["milestone"] == "delivered",
          do: _ = state.notify.(pod_id, "info : " <> line)

      _ ->
        :ok
    end

    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp render_line(:"step.unlocked", %{"milestone" => "delivered"} = p),
    do: "brique ##{p["number"]}#{title_part(p)} LIVRÉE — mergée, scellée, verrou levé"

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

  defp render_line(:"pod.spawned", p),
    do: "#{p["role"] || "?"} parti#{ctx(p)}"

  defp render_line(:"pod.completed", p),
    do: "pod #{p["pod_id"] || p[:pod_id] || "?"} a fini son run#{ctx(p)}"

  defp render_line(:"pod.failed", p),
    do: "⚠ pod #{p["pod_id"] || p[:pod_id] || "?"} en ÉCHEC#{ctx(p)}"

  defp render_line(:"spawn.failed", p),
    do: "⚠ spawn en ÉCHEC#{ctx(p)}"

  # Payload producers use different issue-number keys; include title when available.
  defp ctx(p) when is_map(p) do
    case ctx_number(p) do
      nil -> ""
      issue -> " (##{issue}#{title_part(p)})"
    end
  end

  defp ctx(_), do: ""

  defp ctx_number(p) when is_map(p),
    do: p["issue"] || p[:issue] || p["number"] || p[:number] || p["issue_id"] || p[:issue_id]

  defp ctx_number(_), do: nil

  defp title_part(%{"_title" => t}) when is_binary(t) and t != "", do: " « #{t} »"
  defp title_part(_), do: ""

  # Accept integer/digit-string issue numbers; failed lookup leaves the original payload.
  defp annotate_title(payload, repo, state) do
    with n when is_integer(n) <- normalize_number(ctx_number(payload)),
         {:ok, %{"title" => t}} when is_binary(t) and t != "" <-
           state.forge.get_issue(repo, n, []) do
      Map.put(payload, "_title", t)
    else
      _ -> payload
    end
  rescue
    _ -> payload
  catch
    _, _ -> payload
  end

  defp normalize_number(n) when is_integer(n), do: n

  defp normalize_number(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp normalize_number(_), do: nil

  # -- Feed file: the FORMAT belongs to `PodFeed`; the RAIL belongs here. --

  defp append(pod_id, line, state) do
    with {:ok, %{pod_dir: pod_dir}} when is_binary(pod_dir) <- state.pod_info.(pod_id),
         {:error, reason} <- PodFeed.append(pod_dir, line) do
      Logger.warning(
        "ArchFeed: feed write failed (#{inspect(reason)}) — line dropped (lossy by doctrine)"
      )
    else
      # A successful append or missing pod location needs no warning here.
      _ -> :ok
    end
  end
end
