defmodule Fleet.EventRouter.RegistryGiteaTest do
  @moduledoc """
  Checks every declared Gitea preregistration against events.yaml keys. This is not a
  sweep of arbitrary webhook actions; unregistered types currently produce HTTP 422,
  rather than the historical silent 200 described in the test's failure message.
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
