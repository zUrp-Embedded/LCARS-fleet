defmodule Fleet.Pilot.IncidentRegistry do
  @moduledoc """
  Mémoire PERSISTANTE cross-session des incidents système (#5.2) — **owner résilient**.

  Un gestionnaire d'erreurs doit être PLUS fiable que ce qu'il surveille : sa mémoire ne peut pas dépendre
  (synchrone, copie unique, race-prone) du substrat qu'elle surveille. D'où ce GenServer — l'Iron Law est
  ici SATISFAIT (état mutable à bufferiser + accès sérialisé + isolation de la panne forge) :

    - **check récurrence** (`seen_before?`) = lookup MÉMOIRE → 0 I/O par fail → tient un **burst** (N pods
      qui tombent ensemble = la signature même du métier d'un error-handler) ;
    - **écriture** (`note`) = upsert sérialisé + **WAL local** (JSON, écriture atomique tmp+rename →
      crash-survivable) PUIS déclenche un **sync forge ASYNC** → le dispatcher ne bloque JAMAIS sur la forge ;
    - **forge = backing-store durable cross-machine** (branche `work/ops`), sync async débouncé + retried,
      **merge bidirectionnel** (incidents d'autres machines absorbés) ; forge injoignable = log **fail-LOUD**,
      jamais de perte (le WAL tient, re-sync au retour) ni de re-roll silencieux.

  Au boot : `merge(WAL local, forge)`. `signature/3` reste une fonction pure. L'historique git du fichier
  forge = la timeline des incidents.
  """
  use GenServer
  require Logger

  alias Fleet.Pilot.ForgeClient

  @forge_fail_threshold 3
  @sync_debounce_ms 2_000
  @retry_ms 30_000

  # ============================================================
  # API (signature inchangée pour WakeRecovery)
  # ============================================================

  @spec signature(String.t(), String.t(), term()) :: String.t()
  def signature(op, subject, reason) when is_binary(op) and is_binary(subject) do
    "#{op}:#{normalize(subject)}:#{reason_category(reason)}"
  end

  @doc "Récurrence ? Lookup MÉMOIRE (0 I/O → burst-proof). fail-LOUD si l'owner est indisponible (log + first-time)."
  @spec seen_before?(String.t(), keyword()) :: boolean()
  def seen_before?(sig, opts \\ []) when is_binary(sig) do
    GenServer.call(server(opts), {:seen_before?, sig})
  catch
    :exit, why ->
      Logger.error(
        "IncidentRegistry indisponible (seen_before? #{sig}): #{inspect(why)} — fail-loud"
      )

      false
  end

  @doc "Grave l'incident : upsert mémoire + WAL local PUIS sync forge async. fail-LOUD si owner indisponible."
  @spec note(String.t(), term(), keyword()) :: :ok | {:error, term()}
  def note(sig, reason, opts \\ []) when is_binary(sig) do
    GenServer.call(server(opts), {:note, sig, reason, now(opts)})
  catch
    :exit, why ->
      Logger.error("IncidentRegistry indisponible (note #{sig}): #{inspect(why)} — fail-loud")
      {:error, :registry_unavailable}
  end

  # ============================================================
  # GenServer
  # ============================================================

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    wal = wal_path(opts)
    _ = File.mkdir_p(Path.dirname(wal))

    state = %{registry: %{}, wal_path: wal, forge_fails: 0, sync_pending: false, opts: opts}
    {:ok, state, {:continue, :load}}
  end

  @impl true
  def handle_continue(:load, state) do
    registry = merge(read_wal(state.wal_path), load_forge(state.opts))
    Logger.info("IncidentRegistry: chargé #{map_size(registry)} signature(s) (WAL ∪ forge)")
    {:noreply, %{state | registry: registry}}
  end

  @impl true
  def handle_call({:seen_before?, sig}, _from, state) do
    {:reply, Map.has_key?(state.registry, sig), state}
  end

  def handle_call({:note, sig, reason, now}, _from, state) do
    registry = upsert(state.registry, sig, reason, now)

    # WAL local crash-survivable AVANT la forge ; la forge est async (jamais sur le chemin du dispatcher).
    _ = write_wal(state.wal_path, registry)
    {:reply, :ok, schedule_sync(%{state | registry: registry})}
  end

  @impl true
  def handle_info(:sync_forge, state) do
    state = %{state | sync_pending: false}

    case sync_forge(state.registry, state.opts) do
      {:ok, merged} ->
        _ = write_wal(state.wal_path, merged)
        {:noreply, %{state | registry: merged, forge_fails: 0}}

      {:error, reason} ->
        fails = state.forge_fails + 1

        if fails >= @forge_fail_threshold do
          Logger.error(
            "IncidentRegistry: backing-store forge injoignable depuis #{fails} essais (#{inspect(reason)}) " <>
              "— fail-LOUD. Données SAINES dans le WAL local (#{state.wal_path}) ; re-sync au retour forge."
          )
        end

        Process.send_after(self(), :sync_forge, retry_ms(state.opts))
        {:noreply, %{state | forge_fails: fails, sync_pending: true}}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  # ============================================================
  # Interne
  # ============================================================

  defp schedule_sync(%{sync_pending: true} = state), do: state

  defp schedule_sync(state) do
    Process.send_after(self(), :sync_forge, debounce_ms(state.opts))
    %{state | sync_pending: true}
  end

  defp upsert(registry, sig, reason, now) do
    entry =
      registry
      |> Map.get(sig, %{"count" => 0, "first_seen" => now})
      |> Map.update("count", 1, &(&1 + 1))
      |> Map.put("last_seen", now)
      |> Map.put("last_reason", inspect(reason))

    Map.put(registry, sig, entry)
  end

  # Read-modify-write avec MERGE : absorbe les incidents posés par d'autres machines depuis le dernier sync
  # (au lieu d'écraser). Renvoie le merge pour que l'owner adopte la vérité cross-machine.
  defp sync_forge(registry, opts) do
    getter = Keyword.get(opts, :get_file_fun, &ForgeClient.get_file/3)
    putter = Keyword.get(opts, :put_file_fun, &ForgeClient.put_file/4)

    {forge_reg, sha} =
      case getter.(repo(opts), path(opts), ref: branch(opts)) do
        {:ok, %{content: content, sha: sha}} -> {decode(content), sha}
        _ -> {%{}, nil}
      end

    merged = merge(registry, forge_reg)
    ident = author(opts)

    put_opts = [
      branch: branch(opts),
      message: "ops(incident): sync registre",
      sha: sha,
      author: ident,
      committer: ident
    ]

    case putter.(repo(opts), path(opts), JSON.encode!(merged), put_opts) do
      {:ok, _} -> {:ok, merged}
      {:error, _} = err -> err
    end
  end

  defp read_wal(path) do
    with {:ok, content} <- File.read(path), reg when is_map(reg) <- decode(content) do
      reg
    else
      _ -> %{}
    end
  end

  defp write_wal(path, registry) do
    tmp = path <> ".tmp"

    with :ok <- File.write(tmp, JSON.encode!(registry)), :ok <- File.rename(tmp, path) do
      :ok
    else
      {:error, reason} ->
        Logger.error("IncidentRegistry: WAL write échoué (#{path}): #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp load_forge(opts) do
    getter = Keyword.get(opts, :get_file_fun, &ForgeClient.get_file/3)

    case getter.(repo(opts), path(opts), ref: branch(opts)) do
      {:ok, %{content: content}} -> decode(content)
      _ -> %{}
    end
  end

  defp decode(content) do
    case JSON.decode(content) do
      {:ok, reg} when is_map(reg) -> reg
      _ -> %{}
    end
  end

  defp merge(a, b), do: Map.merge(a, b, fn _sig, ea, eb -> merge_entry(ea, eb) end)

  defp merge_entry(a, b) do
    %{
      "count" => max(a["count"] || 0, b["count"] || 0),
      "first_seen" => min_iso(a["first_seen"], b["first_seen"]),
      "last_seen" => max_iso(a["last_seen"], b["last_seen"]),
      "last_reason" => later_reason(a, b)
    }
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

  # --- config (opts > app env > défaut) ---
  defp server(opts), do: Keyword.get(opts, :server, __MODULE__)
  defp now(opts), do: opts[:now] || DateTime.to_iso8601(DateTime.utc_now())
  defp debounce_ms(opts), do: opts[:sync_debounce_ms] || @sync_debounce_ms
  defp retry_ms(opts), do: opts[:retry_ms] || @retry_ms

  defp repo(opts),
    do: opts[:repo] || Application.get_env(:fleet_pilot, :incident_registry_repo, "fleet/lcars")

  defp branch(opts),
    do: opts[:branch] || Application.get_env(:fleet_pilot, :incident_registry_branch, "work/ops")

  defp path(opts),
    do:
      opts[:path] ||
        Application.get_env(:fleet_pilot, :incident_registry_path, "work/system-incidents.json")

  defp wal_path(opts),
    do:
      opts[:wal_path] || Application.get_env(:fleet_pilot, :incident_registry_wal_path) ||
        Path.join([System.user_home() || System.tmp_dir!(), ".lcars", "system-incidents.json"])

  defp author(opts),
    do:
      opts[:author] ||
        Application.get_env(:fleet_pilot, :incident_registry_author, %{
          name: "LCARS-starfleet",
          email: "starfleet@lcars.local"
        })

  defp normalize(subject), do: Regex.replace(~r/\d+/, subject, "N")
  defp reason_category(reason) when is_atom(reason), do: Atom.to_string(reason)

  defp reason_category(reason) when is_tuple(reason) and tuple_size(reason) > 0,
    do: reason_category(elem(reason, 0))

  defp reason_category(reason), do: inspect(reason)
end
