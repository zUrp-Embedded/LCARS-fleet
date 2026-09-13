defmodule Fleet.SystemConfig do
  use Boundary, deps: [], exports: []

  @moduledoc """
  Reads container-wide admin settings, normally /etc/lcars/fleet.json from runtime.exs at boot.
  Provisioning must restrict writes to root: a human-controlled environment variable would let
  workers override administrator policy. This reader neither checks ownership nor caches values;
  editing the deployed file requires restarting the fleet to reload runtime configuration.

  Missing files silently use defaults. Read/JSON errors warn and default; unknown keys warn and
  are ignored. Invalid boolean fields warn and default individually. conflict_engine opts into
  deterministic GitWand conflict resolution and defaults to false.
  """

  require Logger

  @known_keys ["conflict_engine"]

  @doc """
  Reads the settings file. Absent → defaults, silent. Malformed → defaults, loud.
  """
  @spec read(Path.t()) :: %{conflict_engine: boolean()}
  def read(path) do
    case File.read(path) do
      {:error, :enoent} ->
        defaults()

      {:error, reason} ->
        Logger.warning(
          "Fleet.SystemConfig: #{path} exists but cannot be read (#{inspect(reason)}) — " <>
            "every container-wide setting falls back to its default"
        )

        defaults()

      {:ok, raw} ->
        case Jason.decode(raw) do
          {:ok, map} when is_map(map) ->
            warn_unknown_keys(path, map)
            %{conflict_engine: bool_key(path, map, "conflict_engine", false)}

          _ ->
            Logger.warning(
              "Fleet.SystemConfig: #{path} is not a JSON object — every container-wide setting " <>
                "falls back to its default (fix the file, then restart the fleet)"
            )

            defaults()
        end
    end
  end

  defp defaults, do: %{conflict_engine: false}

  defp bool_key(path, map, key, default) do
    case Map.fetch(map, key) do
      :error ->
        default

      {:ok, v} when is_boolean(v) ->
        v

      {:ok, v} ->
        Logger.warning(
          "Fleet.SystemConfig: #{path} — #{key} must be true or false, got #{inspect(v)} — " <>
            "using the default (#{default})"
        )

        default
    end
  end

  defp warn_unknown_keys(path, map) do
    case Map.keys(map) -- @known_keys do
      [] ->
        :ok

      unknown ->
        Logger.warning(
          "Fleet.SystemConfig: #{path} carries unknown key(s) #{inspect(unknown)} — ignored. " <>
            "Known: #{inspect(@known_keys)}. A misspelled knob does nothing; this line is how " <>
            "you find out."
        )
    end
  end
end
