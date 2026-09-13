defmodule Fleet.ReleaseDoorTest do
  @moduledoc """
  Relocate the logger to stderr while retaining diagnostics and configuration for release doors.
  """
  # The default logger handler is node-global; mutation requires synchronous tests and restoration.
  use ExUnit.Case, async: false

  setup do
    {:ok, before} = :logger.get_handler_config(:default)

    on_exit(fn ->
      :logger.remove_handler(:default)
      :logger.add_handler(:default, before.module, before)
    end)

    {:ok, before: before}
  end

  test "le handler passe sur stderr — deplace, pas supprime", %{before: before} do
    assert before.config.type == :standard_io

    assert :ok = Fleet.ReleaseDoor.claim_stdout!()

    assert {:ok, after_} = :logger.get_handler_config(:default)
    assert after_.config.type == :standard_error

    # Removing the handler alone would free stdout but discard failure diagnostics.
    assert :default in :logger.get_handler_ids()
  end

  test "tout le reste de la configuration survit — meme module, meme niveau, meme format", %{
    before: before
  } do
    :ok = Fleet.ReleaseDoor.claim_stdout!()
    {:ok, after_} = :logger.get_handler_config(:default)

    # Formatter is at the handler root; type is nested under config. Preserve both levels.
    assert after_.module == before.module
    assert after_.level == before.level
    assert after_.formatter == before.formatter
    assert Map.delete(after_.config, :type) == Map.delete(before.config, :type)
  end
end
