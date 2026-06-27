defmodule Fleet.Pilot.IncidentRegistry do
  @moduledoc """
  Mémoire PERSISTANTE cross-session des incidents système — **owner résilient**.

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

  @doc """
  Enregistre un échec, OU escalade s'il est récurrent (déjà vu). Pour les chemins SANS re-roll (ex.
  `pod.failed` / `result_timeout`) : 1er = `note` (toléré, possiblement random) ; récurrence = escalade
  (pattern → root-cause).

  Retour HONNÊTE — il porte ce qui s'est VRAIMENT passé, jamais un succès par optimisme :

    - `:recorded` — 1re fois, incident gravé en mémoire + WAL local.
    - `{:escalated, ticket_number}` — récurrence, ticket sysadmin RÉELLEMENT ouvert (le numéro le PROUVE).
    - `{:escalation_failed, reason}` — récurrence détectée mais l'ouverture du ticket a échoué (forge down ?) :
      AUCUN ticket n'existe. L'incident reste en mémoire/WAL local (gravé au 1er passage), mais l'alarme
      sysadmin N'est PAS passée → l'appelant doit le CRIER, pas rassurer.
    - `{:record_failed, reason}` — 1re fois mais l'owner (GenServer) est indisponible : l'incident n'a PAS
      été gravé du tout (ni mémoire ni WAL) → une récurrence ne pourra pas être détectée.
  """
  @spec record_or_escalate(String.t(), String.t(), term(), keyword()) ::
          :recorded
          | {:escalated, integer()}
          | {:escalation_failed, term()}
          | {:record_failed, term()}
  def record_or_escalate(op, subject, reason, opts \\ [])
      when is_binary(op) and is_binary(subject) do
    sig = signature(op, subject, reason)

    if seen_before?(sig, opts) do
      # `escalate_kind` (défaut `:recurrence`) : le wake passe `:sp_suspect` (récurrence = SP, pas l'agent).
      # On PROPAGE le résultat de l'escalade : `{:escalated, num}` ne sort QUE si le ticket a vraiment été
      # ouvert (le numéro le prouve). Forge down → `{:escalation_failed, _}` ; l'incident reste dans le WAL
      # local (gravé au 1er passage, ce qui a rendu `seen_before?` vrai), seul le TICKET manque.
      case escalate(Keyword.get(opts, :escalate_kind, :recurrence), subject, reason, sig, opts) do
        {:ok, num} -> {:escalated, num}
        {:error, e} -> {:escalation_failed, e}
      end
    else
      # `note` grave en mémoire + WAL local. `{:error, _}` = owner indisponible → RIEN n'est gravé : on le
      # signale (`{:record_failed, _}`), on ne ment pas un `:recorded`.
      case note(sig, reason, opts) do
        :ok -> :recorded
        {:error, e} -> {:record_failed, e}
      end
    end
  end

  @doc """
  Ouvre un ticket système (`fleet/lcars`, label `error_system`, assignee `starfleet`=sysadmin) pour un
  incident. `kind` : `:recurrence` | `:reroll_failed` | `:pod_failed`. Label = signal DURABLE (toujours) ;
  assignee best-effort (fallback label-only si le compte n'existe pas). **Partagé** par WakeRecovery et les
  consumers d'échec (DRY). Returns `{:ok, number}` | `{:error, term}`.
  """
  @spec escalate(atom(), String.t(), term(), String.t(), keyword()) ::
          {:ok, integer()} | {:error, term()}
  def escalate(kind, subject, reason, sig, opts \\ []) do
    create_fun = Keyword.get(opts, :create_issue_fun, &Fleet.Pilot.ForgeClient.create_issue/4)
    repo = opts[:repo] || Application.get_env(:fleet_pilot, :system_ticket_repo, "fleet/lcars")

    label =
      opts[:label] || Application.get_env(:fleet_pilot, :system_ticket_label, "error_system")

    assignee =
      opts[:assignee] || Application.get_env(:fleet_pilot, :system_ticket_assignee, "starfleet")

    {kind_label, kind_note} = kind_describe(kind)
    title = "[#{label}] #{kind_label} : #{subject}"

    body = """
    Incident `#{sig}` sur `#{subject}`.
    Raison : `#{inspect(reason)}`.

    #{kind_note}

    Domaine SYSADMIN (substrat : tmux / bwrap / launch / REPL) — PAS un problème de projet.
    (Ticket auto — durcissement #5.2.)
    #{pane_block(opts[:pane])}
    """

    case create_fun.(repo, title, body, labels: [label], assignees: [assignee]) do
      {:ok, _} = ok -> ok
      {:error, _} -> create_fun.(repo, title, body, labels: [label])
    end
  end

  # Bloc « écran capturé » (fallback-ACK déporté) attaché au ticket — vide si pas de pane.
  defp pane_block(pane) when is_binary(pane) and pane != "" do
    "\n## Écran capturé (ce que l'agent affichait au moment de l'échec)\n```\n#{pane}\n```\n"
  end

  defp pane_block(_), do: ""

  defp kind_describe(:recurrence),
    do: {"récurrence", "Déjà vu (registre `work/ops`) — pattern, pas random → ROOT-CAUSE requis."}

  defp kind_describe(:reroll_failed),
    do:
      {"re-roll échoué",
       "Le re-roll (re-spawn + re-wake) n'a PAS réparé → problème actif, ici et maintenant."}

  defp kind_describe(:pod_failed),
    do:
      {"pod en échec récurrent",
       "Pod déjà tombé sur la même cause (registre `work/ops`) → pattern → ROOT-CAUSE requis."}

  defp kind_describe(:sp_suspect),
    do:
      {"SP suspect (wake récurrent)",
       "Le wake-fallback de ce rôle a déjà raté (registre `work/ops`). Avec de l'inférence, 1× = random ; " <>
         "récurrent = ce n'est PAS « l'agent est con » → le **SP est mauvais / a dérivé / le modèle réagit " <>
         "autrement**. ROOT-CAUSE = le PROMPT du rôle, pas l'agent."}

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

    case putter.(repo(opts), path(opts), encode_registry(merged), put_opts) do
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

    with :ok <- File.write(tmp, encode_registry(registry)), :ok <- File.rename(tmp, path) do
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

  # Encode le registre avec UN incident par ligne, clés triées. Le diff git du fichier (commité sur
  # work/ops ET le WAL local) montre alors un incident ajouté = une ligne ajoutée, au lieu d'un blob
  # JSON mono-ligne où le moindre ajout réécrit tout. Reste un JSON valide — `decode/1` le relit tel
  # quel ; le tri par clé garantit un ordre stable (sinon l'ordre map ferait du bruit dans le diff).
  defp encode_registry(registry) when map_size(registry) == 0, do: "{}\n"

  defp encode_registry(registry) do
    body =
      registry
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map_join(",\n", fn {k, v} -> "  #{JSON.encode!(k)}: #{JSON.encode!(v)}" end)

    "{\n" <> body <> "\n}\n"
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

  # HOME irrésoluble = runtime cassé → fail-loud (`System.user_home!()` raise), jamais un chemin
  # fabriqué : l'état .lcars ne doit pas se disperser en silence (p.ex. orphelin sous /tmp).
  defp wal_path(opts),
    do:
      opts[:wal_path] || Application.get_env(:fleet_pilot, :incident_registry_wal_path) ||
        Path.join([System.user_home!(), ".lcars", "system-incidents.json"])

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

  defp reason_category(reason) when is_binary(reason), do: reason

  defp reason_category(reason), do: inspect(reason)
end
