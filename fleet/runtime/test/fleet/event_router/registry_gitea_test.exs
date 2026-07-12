defmodule Fleet.EventRouter.RegistryGiteaTest do
  @moduledoc """
  Z5 #9 — garde de cohérence producteur↔registry. `WebhooksGitea` émet `gitea.<action>`
  (actions pré-enregistrées `Application.gitea_event_types/0`). CHAQUE action DOIT être une
  clé d'`events.yaml`, sinon `Bus.broadcast` fail-loud `UnregisteredError` → drop muet du
  webhook (HTTP 200 mais event jamais routé — le bug #9, prod-only). Verrouille la régression.
  """
  use ExUnit.Case, async: true

  test "toutes les actions gitea pré-enregistrées sont des clés events.yaml (pas de drop muet #9)" do
    registry =
      :fleet_event_router
      |> :code.priv_dir()
      |> Path.join("events.yaml")
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
           "actions gitea émises par WebhooksGitea mais ABSENTES du registry events.yaml " <>
             "→ drop muet en prod (#9) : #{inspect(missing)}"
  end
end
