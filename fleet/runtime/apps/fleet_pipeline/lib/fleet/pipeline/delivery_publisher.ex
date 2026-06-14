defmodule Fleet.Pipeline.DeliveryPublisher do
  @moduledoc """
  Publie DURABLEMENT sur la forge les livrables d'un engineer délégué (Rail « au bout »,
  run e2e 2026-06-14).

  **Doctrine forge-aveugle** (DN forge-state-machine §4) : le POD ne pousse jamais. C'est le
  SYSTÈME — ce consumer — qui grave le livrable. Le pod rend son code (contenu) via
  `submit_result` (MCP), le système l'écrit sur la forge via `ForgeClient.put_file`.

  Subscribe `fleet.events` ; sur un `%Fleet.Event{source: :task_queue, type: :task_completed}`
  dont le `result` porte des `deliverables` avec un champ `content` (string), `put_file` chacun
  sur le repo de délégation (`:fleet_mcp, :delegation_repo`, défaut `fleet/fleet-test`) sous
  `deliverables/<task_id>/<path>` (branche `main`). Best-effort, fail-soft : une publication
  ratée ne casse rien (un livrable sans `content` est simplement ignoré — dette si l'engineer
  n'inclut pas encore le contenu).

  Dispatch `ForgeClient` en runtime (module-en-variable) — pas de dep compile-time
  `fleet_pipeline → fleet_pilot`.
  """
  use GenServer
  require Logger
  alias Fleet.EventRouter.Bus

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    Bus.subscribe()
    {:ok, %{}}
  end

  @impl true
  def handle_info(
        %Fleet.Event{source: :task_queue, type: :task_completed, payload: payload},
        state
      ) do
    publish(payload)
    {:noreply, state}
  end

  def handle_info(%Fleet.Event{}, state), do: {:noreply, state}
  def handle_info(_other, state), do: {:noreply, state}

  defp publish(payload) when is_map(payload) do
    role = payload[:role] || payload["role"]

    ticket =
      payload[:ticket_id] || payload["ticket_id"] || to_string(payload[:task_id] || "unknown")

    result = payload[:result] || payload["result"] || %{}
    deliverables = extract_deliverables(result)
    publishable = Enum.filter(deliverables, fn d -> is_map(d) and is_binary(d["content"]) end)

    if publishable != [] do
      repo = Application.get_env(:fleet_mcp, :delegation_repo, "fleet/fleet-test")
      ns = "deliverables/" <> sanitize(ticket)
      forge = Fleet.Pilot.ForgeClient

      # Traça 2 NIVEAUX (git-natif) : `author` = le WORKER (qui a écrit), `committer` = l'HUMAIN
      # commanditaire (qui a fait bosser la fleet — git config du runtime). Le système fait l'I/O,
      # le commit attribue les deux niveaux. forge-aveugle préservé (le pod ne pousse jamais).
      author = author_for(role)
      committer = committer_human()

      published =
        Enum.reduce(publishable, 0, fn d, acc ->
          path = ns <> "/" <> sanitize_path(d["path"] || "file")

          opts =
            [message: "feat(fleet): livrable #{path} (delegation #{ticket})"] ++
              author ++ committer

          case apply(forge, :put_file, [repo, path, d["content"], opts]) do
            {:ok, _} ->
              Logger.info(
                "DeliveryPublisher: publié #{repo}/#{path} (author=#{author_label(role)}, committer=#{committer_label(committer)})"
              )

              acc + 1

            {:error, reason} ->
              Logger.warning("DeliveryPublisher: échec publication #{path} — #{inspect(reason)}")
              acc
          end
        end)

      Logger.info(
        "DeliveryPublisher: #{published}/#{length(publishable)} livrable(s) gravé(s) sur #{repo} " <>
          "(ticket #{ticket}, author #{author_label(role)}, committer #{committer_label(committer)})"
      )
    end
  rescue
    e -> Logger.warning("DeliveryPublisher: exception #{inspect(e)}")
  end

  defp publish(_), do: :ok

  # author Keyword pour put_file : identité du RÔLE d'origine (forge-aveugle = le système écrit, mais
  # AU NOM de l'agent). [] si rôle inconnu → put_file commit avec le compte système (fallback).
  defp author_for(role) when is_binary(role) and role != "",
    do: [author: %{name: "LCARS-#{role}", email: "#{role}@lcars.local"}]

  defp author_for(_), do: []

  defp author_label(role) when is_binary(role) and role != "", do: "LCARS-#{role}"
  defp author_label(_), do: "système"

  # committer Keyword : l'HUMAIN commanditaire (git config du runtime via ForgeIdentity ; role-indépendant).
  # [] si irrésoluble → put_file commit avec le compte du token (système, fallback fail-soft).
  defp committer_human do
    case Fleet.Credentials.ForgeIdentity.for_role("engineer") do
      {:ok, %{committer_name: name, committer_email: email}}
      when is_binary(name) and is_binary(email) ->
        [committer: %{name: name, email: email}]

      _ ->
        []
    end
  rescue
    _ -> []
  end

  defp committer_label(committer: %{name: name}), do: name
  defp committer_label(_), do: "système"

  # deliverables au top-level OU enveloppés sous "result" (l'engineer enveloppe parfois).
  defp extract_deliverables(%{"deliverables" => d}) when is_list(d), do: d
  defp extract_deliverables(%{"result" => %{"deliverables" => d}}) when is_list(d), do: d
  defp extract_deliverables(_), do: []

  defp sanitize(s), do: String.replace(s, ~r{[^a-zA-Z0-9_.\-]}, "_")

  defp sanitize_path(s) do
    s
    |> to_string()
    |> String.replace(~r{\.\.+}, "_")
    |> String.replace(~r{[^a-zA-Z0-9_.\-/]}, "_")
    |> String.trim_leading("/")
  end
end
