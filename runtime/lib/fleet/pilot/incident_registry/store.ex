defmodule Fleet.Pilot.IncidentRegistry.Store do
  @moduledoc """
  Incident persistence through a local WAL and a forge file on the system repository's
  `incidents` branch. Both use
  one encoder and merge rule; recurrence policy belongs to IncidentRegistry.

  WAL writes replace a temporary file by rename, without fsync. Failed or corrupt
  WAL reads log and return empty; corrupt content is quarantined when possible.
  Forge reads distinguish absent from unreadable/corrupt and refuse writes over
  the latter. Non-map entries are dropped with a log; map fields are not validated.

  Forge sync reads, merges, prunes and writes with the observed SHA. It is not an
  atomic cross-machine transaction, and pruning may discard older signatures.
  """

  require Logger

  alias Fleet.Forge.Client, as: ForgeClient

  # Bound signature growth on upsert and forge merge; boot loading alone does not prune.
  @doc "Keeps up to :pilot_incident_registry_max_entries (default 500), ordered by last_seen text."
  @spec prune(map()) :: map()
  def prune(registry) do
    max = Application.get_env(:lcars_fleet, :pilot_incident_registry_max_entries, 500)

    if map_size(registry) <= max do
      registry
    else
      registry
      |> Enum.sort_by(fn {_sig, e} -> e["last_seen"] || "" end, :desc)
      |> Enum.take(max)
      |> Map.new()
    end
  end

  # A failed read must not turn into an empty merge that overwrites remote incidents.
  @doc "Read-modify-write MERGE of the registry into the ops file; `{:ok, merged}` (no PUT when the merge equals what the forge holds), or `{:error, _}` without a PUT when the forge could not be read (fail-closed)."
  @spec sync_forge(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def sync_forge(registry, opts) do
    getter = Keyword.get(opts, :get_file_fun, &ForgeClient.Files.get_file/3)
    putter = Keyword.get(opts, :put_file_fun, &ForgeClient.Files.put_file/4)

    case getter.(repo(opts), path(opts), ref: branch(opts)) do
      {:ok, %{content: content, sha: sha}} ->
        case decode(content) do
          {:ok, forge_reg} ->
            put_merged(registry, forge_reg, content, sha, putter, opts)

          # Corrupt content is unreadable backing, not permission to overwrite it.
          :corrupt ->
            {:error, {:forge_unreadable, :corrupt_file}}
        end

      {:error, :not_found} ->
        put_merged(registry, %{}, nil, nil, putter, opts)

      {:error, reason} ->
        Logger.error(
          "IncidentRegistry: sync_forge — forge registry UNREADABLE (#{inspect(reason)}) — NOT pushing " <>
            "(a push over an unread forge could overwrite cross-machine incidents); the sync will retry"
        )

        {:error, {:forge_unreadable, reason}}

      other ->
        {:error, {:forge_unexpected_shape, other}}
    end
  end

  defp put_merged(registry, forge_reg, forge_content, sha, putter, opts) do
    merged = registry |> merge(forge_reg) |> prune()
    encoded = encode_registry(merged)

    # Skip byte-identical PUTs and creating an empty registry. Equivalent hand-edited
    # JSON is normalized once because comparison uses encoded bytes.
    cond do
      encoded == forge_content -> {:ok, merged}
      forge_content == nil and merged == %{} -> {:ok, merged}
      true -> put(merged, encoded, sha, putter, opts)
    end
  end

  defp put(merged, encoded, sha, putter, opts) do
    ident = author(opts)

    put_opts = [
      branch: branch(opts),
      message: "ops(incident): sync registre",
      sha: sha,
      author: ident,
      committer: ident
    ]

    case putter.(repo(opts), path(opts), encoded, put_opts) do
      {:ok, _} -> {:ok, merged}
      # The branch does not exist: the recipe lays it, the runtime never does. Named, so the
      # registry does not count it as "forge unreachable" for hours (380 times on the beta bench).
      {:error, {:http, 404, _}} -> {:error, {:registry_branch_missing, repo(opts), branch(opts)}}
      {:error, _} = err -> err
    end
  end

  @doc "Reads the WAL; missing returns empty, unreadable/corrupt logs and returns empty. Corrupt content is quarantined when possible."
  @spec read_wal(Path.t()) :: map()
  def read_wal(path) do
    # Missing is normal; unreadable or corrupt WAL loses local recurrence memory
    # for this boot and must be logged.
    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, reg} when is_map(reg) ->
            drop_non_map_entries(reg, "WAL #{path}")

          other ->
            # Try to preserve forensic evidence before subsequent notes replace the WAL.
            quarantined = quarantine_corrupt_wal(path)

            Logger.error(
              "IncidentRegistry: WAL #{path} present but UNPARSEABLE (#{inspect(other)}) — cross-session " <>
                "incident memory LOST (recurrences won't be detected until it is rebuilt). Corrupt file " <>
                "quarantined at #{inspect(quarantined)}; starting from empty."
            )

            %{}
        end

      {:error, :enoent} ->
        %{}

      {:error, reason} ->
        Logger.error(
          "IncidentRegistry: WAL #{path} unreadable (#{inspect(reason)}) — cross-session incident " <>
            "memory unavailable this boot (recurrences won't be detected). Starting from empty."
        )

        %{}
    end
  end

  # Quarantine uses second-resolution names, so collisions are possible.
  # Failed rename logs and returns nil; later writes can then overwrite evidence.
  defp quarantine_corrupt_wal(path) do
    dest = "#{path}.corrupt-#{System.os_time(:second)}"

    case File.rename(path, dest) do
      :ok ->
        dest

      {:error, reason} ->
        Logger.error(
          "IncidentRegistry: could not quarantine corrupt WAL #{path} (#{inspect(reason)}) — " <>
            "the next write may overwrite it; move it aside by hand before it is lost"
        )

        nil
    end
  end

  @doc "Atomic write (tmp + rename) of the registry to the WAL; the typed error is the caller's to surface."
  @spec write_wal(Path.t(), map()) :: :ok | {:error, term()}
  def write_wal(path, registry) do
    tmp = path <> ".tmp"

    with :ok <- File.write(tmp, encode_registry(registry)), :ok <- File.rename(tmp, path) do
      :ok
    else
      {:error, reason} ->
        Logger.error("IncidentRegistry: WAL write failed (#{path}): #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc "The ops file as a registry: `{:ok, map}`, `:absent` on a genuine 404, `{:error, _}` on an unreadable or corrupt forge — never a silent empty."
  @spec load_forge(keyword()) :: {:ok, map()} | :absent | {:error, term()}
  def load_forge(opts) do
    getter = Keyword.get(opts, :get_file_fun, &ForgeClient.Files.get_file/3)

    case getter.(repo(opts), path(opts), ref: branch(opts)) do
      {:ok, %{content: content}} ->
        case decode(content) do
          {:ok, reg} -> {:ok, reg}
          # Refuse a corrupt forge at boot as well as during synchronization.
          :corrupt -> {:error, :corrupt_file}
        end

      {:error, :not_found} ->
        :absent

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Refuse an undecodable root. Drop individual non-map values with a log so
  # one damaged entry does not block all synchronization.
  defp decode(content) do
    case Jason.decode(content) do
      {:ok, reg} when is_map(reg) ->
        {:ok, drop_non_map_entries(reg, "forge file")}

      _ ->
        Logger.error(
          "IncidentRegistry: forge registry file CORRUPT (not a JSON map) — REFUSED as a read. " <>
            "We do not know what the forge holds, so we do not push over it: same fail-closed " <>
            "posture as an unreadable forge. Repair the file; the sync retries."
        )

        :corrupt
    end
  end

  # Both files are hand-editable. Drop non-map values before merge to avoid
  # repeatable startup failures; this does not validate fields inside valid maps.
  defp drop_non_map_entries(reg, origin) do
    {maps, bad} = Map.split_with(reg, fn {_sig, v} -> is_map(v) end)

    if map_size(bad) > 0 do
      Logger.error(
        "IncidentRegistry: #{map_size(bad)} non-map entrie(s) dropped from #{origin} " <>
          "(sigs: #{inspect(Map.keys(bad))}) — repair the file; the incident memory of these " <>
          "signatures is lost (their recurrences will look like first occurrences)."
      )
    end

    maps
  end

  # Sorted signatures, one per line, keep ops diffs readable and stable.
  defp encode_registry(registry) when map_size(registry) == 0, do: "{}\n"

  defp encode_registry(registry) do
    body =
      registry
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map_join(",\n", fn {k, v} -> "  #{Jason.encode!(k)}: #{Jason.encode!(v)}" end)

    "{\n" <> body <> "\n}\n"
  end

  @doc "Union of two registries: per signature, the max count, the earliest first_seen, the latest last_seen and escalation stamp."
  @spec merge(map(), map()) :: map()
  def merge(a, b), do: Map.merge(a, b, fn _sig, ea, eb -> merge_entry(ea, eb) end)

  defp merge_entry(a, b) do
    # Defend overlapping entries passed directly to merge as well as decoded input.
    a = if is_map(a), do: a, else: %{}
    b = if is_map(b), do: b, else: %{}

    # Keep the latest escalation's timestamp and issue as a pair; independent maxima
    # could associate a timestamp with the wrong issue. Old entries have neither.
    {esc_at, esc_issue} =
      if (a["last_escalated_at"] || "") >= (b["last_escalated_at"] || "") do
        {a["last_escalated_at"], a["escalated_issue"]}
      else
        {b["last_escalated_at"], b["escalated_issue"]}
      end

    base = %{
      "count" => max(a["count"] || 0, b["count"] || 0),
      "first_seen" => min_iso(a["first_seen"], b["first_seen"]),
      "last_seen" => max_iso(a["last_seen"], b["last_seen"]),
      "last_reason" => later_reason(a, b)
    }

    if is_nil(esc_at) do
      base
    else
      Map.merge(base, %{"last_escalated_at" => esc_at, "escalated_issue" => esc_issue})
    end
  end

  defp min_iso(nil, b), do: b
  defp min_iso(a, nil), do: a
  defp min_iso(a, b), do: min(a, b)

  defp max_iso(nil, b), do: b
  defp max_iso(a, nil), do: a
  defp max_iso(a, b), do: max(a, b)

  defp later_reason(a, b),
    do:
      if((a["last_seen"] || "") >= (b["last_seen"] || ""),
        do: a["last_reason"],
        else: b["last_reason"]
      )

  # Share Escalation's default ops repository; allow an explicit backing override.
  defp repo(opts),
    do:
      opts[:repo] || Application.get_env(:lcars_fleet, :pilot_incident_registry_repo) ||
        Fleet.Pilot.IncidentRegistry.Escalation.ops_repo()

  defp branch(opts),
    do:
      opts[:branch] ||
        Application.get_env(:lcars_fleet, :pilot_incident_registry_branch, "incidents")

  defp path(opts),
    do:
      opts[:path] ||
        Application.get_env(
          :lcars_fleet,
          :pilot_incident_registry_path,
          "work/system-incidents.json"
        )

  @doc "The WAL path: opts, then `:pilot_incident_registry_wal_path`, else `<state_dir>/system-incidents.json`."
  @spec wal_path(keyword()) :: Path.t()
  def wal_path(opts),
    do:
      opts[:wal_path] || Application.get_env(:lcars_fleet, :pilot_incident_registry_wal_path) ||
        Path.join(Fleet.Layout.state_dir(), "system-incidents.json")

  # Background registry commits use system identity for both author and committer.
  # A role belongs in a verified trailer, not as the author of this system action.
  defp author(opts),
    do:
      opts[:author] ||
        Application.get_env(
          :lcars_fleet,
          :pilot_incident_registry_author,
          Fleet.Credentials.ForgeIdentity.system_identity()
        )
end
