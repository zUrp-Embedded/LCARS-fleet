defmodule Fleet.Pilot.IncidentRegistry.Store do
  @moduledoc """
  The registry's durable MAGASIN, two backends of one shape: the local WAL (atomic tmp+rename,
  crash-survivable, the only durability of a first occurrence) and the ops file on the forge
  (read-modify-write MERGE, so incidents noted by other machines are absorbed and never
  overwritten). One encoder (an incident per line, sorted keys — a git diff of the file reads as
  a list), one merge, one prune, and the same three-state discipline on both reads: absent is not
  empty, and unreadable or corrupt is neither — fail-closed, nothing is pushed over what could not
  be read.

  No policy here: recurrence, cooldown and escalation are `Fleet.Pilot.IncidentRegistry`'s.
  """

  require Logger

  alias Fleet.Forge.Client, as: ForgeClient

  # PRUNE (E4): the registry would otherwise be the runtime's only structurally UNBOUNDED state (no eviction,
  # merge = monotone union, signatures with open cardinality via stringified reasons) — months
  # of varied incidents would mean endless growth of the WAL + of the forge file REWRITTEN IN FULL on each note.
  # Eviction by last_seen (ISO lexicographic = chronological) beyond `:max_entries`
  # (default 500 — well above nominal; the bound targets the anomaly). Applied to the upsert AND the
  # forge merge (both growth paths).
  @doc "Evicts the oldest entries past `:pilot_incident_registry_max_entries` (default 500) — the registry is otherwise the runtime's only unbounded state."
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

  # Read-modify-write with MERGE: absorbs incidents posted by other machines since the last sync
  # (instead of overwriting). Same 3-case DISCIPLINE as `read_wal/1` below — an unreadable forge is NOT an
  # empty one:
  #   * read OK           → merge the real forge content, update it (with its sha);
  #   * genuine 404       → no file yet → CREATE from the local view (empty merge, nil sha);
  #   * unreadable (5xx/  → we do NOT know the forge's real content → pushing our LOCAL view would
  #     network/timeout)    OVERWRITE cross-machine incidents we could not read (data loss). Fail-closed:
  #                         `{:error, _}`, no PUT — the handler retries (data stays safe in the WAL).
  @doc "Read-modify-write MERGE of the registry into the ops file; `{:ok, merged}`, or `{:error, _}` without a PUT when the forge could not be read (fail-closed)."
  @spec sync_forge(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def sync_forge(registry, opts) do
    getter = Keyword.get(opts, :get_file_fun, &ForgeClient.Files.get_file/3)
    putter = Keyword.get(opts, :put_file_fun, &ForgeClient.Files.put_file/4)

    case getter.(repo(opts), path(opts), ref: branch(opts)) do
      {:ok, %{content: content, sha: sha}} ->
        case decode(content) do
          {:ok, forge_reg} ->
            put_merged(registry, forge_reg, sha, putter, opts)

          # MEME BRANCHE QUE L'ILLISIBLE, ET POUR LA MEME RAISON : on ignore ce que la forge
          # contient. Pousser notre vue locale par-dessus effacerait les incidents des autres
          # machines — dont les recurrences redeviendraient des premieres occurrences.
          :corrupt ->
            {:error, {:forge_unreadable, :corrupt_file}}
        end

      {:error, :not_found} ->
        put_merged(registry, %{}, nil, putter, opts)

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

  defp put_merged(registry, forge_reg, sha, putter, opts) do
    merged = registry |> merge(forge_reg) |> prune()
    ident = author(opts)

    put_opts = [
      branch: branch(opts),
      message: "ops(incident): sync registre",
      sha: sha,
      author: ident,
      committer: ident
    ]

    case putter.(repo(opts), path(opts), encode_registry(merged), put_opts) do
      {:ok, _} -> {:ok, merged}
      {:error, _} = err -> err
    end
  end

  @doc "The local WAL as a registry: `%{}` on a missing file (fresh install), `%{}` LOUD on an unreadable or corrupt one (quarantined aside)."
  @spec read_wal(Path.t()) :: map()
  def read_wal(path) do
    # DISTINGUISH the 3 cases: a MISSING WAL (`:enoent`) is a fresh install → empty is normal & silent.
    # A PRESENT-but-unreadable or unparseable WAL is DATA LOSS: the cross-session incident memory is wiped
    # → recurrences stop being detected → escalations never fire, while boot would otherwise report
    # "0 signatures" as if nominal. We still return `%{}` (never crash boot) but LOUD, not silent.
    # NB: `Jason.decode` DIRECTLY, not the local `decode/1` — the latter swallows a parse error into `%{}`
    # (so a corrupt WAL would look like a valid-empty one). Here we MUST see the `{:error, _}` to log it.
    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, reg} when is_map(reg) ->
            drop_non_map_entries(reg, "WAL #{path}")

          other ->
            # A present-but-unparseable WAL is CORRUPTED CONTENT, and the next `write_wal` would
            # rename a fresh registry over it — erasing the only forensic trace of what corrupted the
            # cross-machine memory. QUARANTINE it aside first (never auto-replaced): the evidence is
            # kept, the fresh WAL lands on a clean path. Boot proceeds from empty, LOUD.
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

  # Moves a corrupt WAL aside to `<path>.corrupt-<unix>` so the fresh registry never overwrites it
  # (the evidence of the corruption is preserved for inspection). `os_time` collides only within the
  # same second — acceptable for a forensic artifact; a rename failure is itself logged and returns nil
  # (boot must not crash on a quarantine hiccup — the corruption is already the reported condition).
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

  # `{:ok, map}` on a readable file, `:absent` on a genuine 404 (never written yet — no memory to
  # lose), `{:error, reason}` on an UNREADABLE forge (down/transport). The caller must not turn an
  # unreadable backing into a silent empty registry: on a fresh node (no WAL) the forge IS the only
  # cross-machine memory, and `%{}` there would replay every past recurrence as a first occurrence.
  @doc "The ops file as a registry: `{:ok, map}`, `:absent` on a genuine 404, `{:error, _}` on an unreadable or corrupt forge — never a silent empty."
  @spec load_forge(keyword()) :: {:ok, map()} | :absent | {:error, term()}
  def load_forge(opts) do
    getter = Keyword.get(opts, :get_file_fun, &ForgeClient.Files.get_file/3)

    case getter.(repo(opts), path(opts), ref: branch(opts)) do
      {:ok, %{content: content}} ->
        case decode(content) do
          {:ok, reg} -> {:ok, reg}
          # Au BOOT aussi : un fichier corrompu n'est pas un registre vide. Le traiter comme vide
          # ferait rejouer chaque recurrence connue des autres machines en premiere occurrence.
          :corrupt -> {:error, :corrupt_file}
        end

      {:error, :not_found} ->
        :absent

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ⚠ UN FICHIER CORROMPU EST LE MEME FAIT QU'UN FICHIER ILLISIBLE : dans les deux cas on ignore ce
  # que la forge contient, donc rendre un vide et pousser notre vue LOCALE ECRASE des incidents
  # inter-machines qu'on n'a pas su lire — et le SHA du fichier corrompu fait REUSSIR l'ecrasement.
  # Fail-closed, comme la lecture d'une forge muette un peu plus haut.
  #
  # ⚠ DEUX CORRUPTIONS, DEUX POIDS, ET UNE SEULE EST FAIL-CLOSED. Racine indecodable : on ne sait
  # RIEN, refus. Entrees individuelles invalides : le reste du fichier est AUTHENTIQUE, et refuser
  # bloquerait TOUTE synchronisation jusqu'a ce qu'un humain repare un fichier que personne ne
  # regarde — la sync ne se repare pas toute seule, elle se coince. On trie donc, bruyamment.
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

  # The registry file lives on the SHARED forge (ops) and the WAL on local disk — both
  # hand-editable. A non-map VALUE under a signature ({"sig": "garbage"}) would enter RAM,
  # contaminate the WAL, then raise in merge_entry during handle_continue(:load) → boot-loop
  # REPRODUCIBLE at every reboot until the file is repaired by hand. Same doctrine as the
  # unparseable WAL above: visible memory loss (LOUD drop), never a boot crash.
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

  # Encode the registry with ONE incident per line, sorted keys. The git diff of the file (committed on
  # ops AND the local WAL) then shows an added incident = an added line, instead of a single-line
  # JSON blob where the slightest addition rewrites everything. Stays valid JSON — `decode/1` reads it as
  # is; sorting by key guarantees a stable order (otherwise map order would make noise in the diff).
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
    # Defensive net BEHIND drop_non_map_entries (decode/read_wal filter at both load points):
    # a non-map can only reach here through a NEW load path — coerce, never raise at boot.
    a = if is_map(a), do: a, else: %{}
    b = if is_map(b), do: b, else: %{}

    # Escalation memory: the LATEST escalation wins as a PAIR (stamp + its issue — a max on
    # each field separately could marry the new stamp with the old issue number). Old entries
    # (pre-cooldown WAL/forge) have neither field → nils, dropped below (back-compat).
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

  # --- config (opts > app env > default) ---
  # SINGLE ops-repo authority (`:pilot_ops_repo`): the incident REGISTRY (this file, ops branch)
  # and the sysadmin ISSUES it opens (`Escalation`) must land on the SAME repo — they are two faces
  # of one incident. Two separate keys with two inline defaults would sit one edit away from a
  # registry on repo A and its issues on repo B, with nothing to catch it.
  # `:pilot_incident_registry_repo` is an explicit override for the rare split.
  defp repo(opts),
    do:
      opts[:repo] || Application.get_env(:lcars_fleet, :pilot_incident_registry_repo) ||
        Fleet.Pilot.IncidentRegistry.Escalation.ops_repo()

  defp branch(opts),
    do: opts[:branch] || Application.get_env(:lcars_fleet, :pilot_incident_registry_branch, "ops")

  defp path(opts),
    do:
      opts[:path] ||
        Application.get_env(
          :lcars_fleet,
          :pilot_incident_registry_path,
          "work/system-incidents.json"
        )

  # HOME unresolvable = broken runtime → fail-loud (`System.user_home!()` raises), never a fabricated
  # path: the .lcars state must not silently scatter (e.g. orphaned under /tmp).
  @doc "The WAL path: opts, then `:pilot_incident_registry_wal_path`, else `<state_dir>/system-incidents.json`."
  @spec wal_path(keyword()) :: Path.t()
  def wal_path(opts),
    do:
      opts[:wal_path] || Application.get_env(:lcars_fleet, :pilot_incident_registry_wal_path) ||
        Path.join(Fleet.Layout.state_dir(), "system-incidents.json")

  # The registry sync is a commit the RUNTIME makes: no human initiated it, no pod produced it, and
  # no pod could — a pod never holds the forge token. Its identity is therefore the SYSTEM one, like
  # the other two runtime-generated commits (`Workflow.OpsObject`, `Fleet.Project.Onboard`), through
  # the single accessor rather than a literal retyped at the caller.
  #
  # Never a ROLE here: `ForgeIdentity` splits the three identities on purpose — author = the human,
  # role = a VERIFIED TRAILER, committer = the system. `role_email/1` builds that trailer (its only
  # other caller is `coauthor_trailer/1`); as an author email it would sign a system act under a pod
  # that does not touch the forge at all.
  defp author(opts),
    do:
      opts[:author] ||
        Application.get_env(
          :lcars_fleet,
          :pilot_incident_registry_author,
          Fleet.Credentials.ForgeIdentity.system_identity()
        )
end
