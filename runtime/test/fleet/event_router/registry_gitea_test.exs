defmodule Fleet.EventRouter.RegistryGiteaTest do
  @moduledoc """
  Z5 #9 — producer↔registry consistency guard. `WebhooksGitea` emits `gitea.<action>`
  (actions preregistered by `Application.gitea_event_types/0`). EVERY action MUST be a
  key of `events.yaml`, otherwise `Bus.broadcast` fail-louds `UnregisteredError` → silent
  drop of the webhook (HTTP 200 but event never routed — bug #9, prod-only). Locks the
  regression.
  """
  use ExUnit.Case, async: true

  test "every preregistered gitea action is an events.yaml key (no silent drop #9)" do
    registry =
      :lcars_fleet
      |> :code.priv_dir()
      |> Path.join("event_router/events.yaml")
      |> YamlElixir.read_from_file!()
      |> Map.fetch!("events")
      |> Map.keys()
      |> MapSet.new()

    missing =
      Enum.reject(
        Fleet.EventRouter.Application.gitea_event_types(),
        &MapSet.member?(registry, &1)
      )

    assert missing == [],
           "gitea actions emitted by WebhooksGitea but ABSENT from the events.yaml registry " <>
             "→ silent drop in prod (#9): #{inspect(missing)}"
  end
end
