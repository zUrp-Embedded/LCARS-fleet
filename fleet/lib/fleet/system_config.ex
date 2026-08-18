defmodule Fleet.SystemConfig do
  use Boundary, deps: [], exports: []

  @moduledoc """
  Reader of the box-wide, ADMIN-OWNED settings file (`/etc/lcars/fleet.json`) — a pure, testable
  primitive for `config/runtime.exs`, same family as `Fleet.EnvParse`.

  WHY A FILE AND NOT AN ENV VAR — the env passes through the HUMAN's hands: `fleet_v2` sources
  `~/.lcars/fleet_v2.env` and any worker can export a variable in their shell. A setting that
  belongs to the box's administrator (admiral) alone must come from a path only root writes —
  same idiom as `/etc/lcars/deck-oidc.json` (posed by provisioning, read by the deck at boot).
  `runtime.exs` runs ONCE at BEAM boot, so the value is frozen for the fleet's lifetime by
  construction: a fleet starts WITH or WITHOUT, never flips mid-flight.

  Failure directions, and both are deliberate:
    * file ABSENT → every default (a box never configured behaves like today, silently — absence
      is the nominal state of a fresh install, not an event worth a log line);
    * file PRESENT but unreadable/malformed → every default + a LOUD warning (an admin who wrote
      a file expects it to act; a typo must be visible, but must not kill the boot — same doctrine
      as `Fleet.EnvParse` boolean flags);
    * unknown keys → LOUD warning, ignored (a misspelled knob must not silently do nothing).

  One knob today: `conflict_engine` (boolean) — the GitWand kill-switch (tier-0 deterministic
  conflict resolution). Inherited from the engine's origin project: off by default at install,
  the admin opts in.
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
            "every box-wide setting falls back to its default"
        )

        defaults()

      {:ok, raw} ->
        case Jason.decode(raw) do
          {:ok, map} when is_map(map) ->
            warn_unknown_keys(path, map)
            %{conflict_engine: bool_key(path, map, "conflict_engine", false)}

          _ ->
            Logger.warning(
              "Fleet.SystemConfig: #{path} is not a JSON object — every box-wide setting " <>
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
