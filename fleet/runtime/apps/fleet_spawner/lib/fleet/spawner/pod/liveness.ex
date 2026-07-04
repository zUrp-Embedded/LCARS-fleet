defmodule Fleet.Spawner.Pod.Liveness do
  @moduledoc """
  Watchdog d'ACTIVITÉ + calcul du timeout de RÉPONSE — cluster extrait de `Fleet.Spawner.Pod`.

  Deux rôles jumeaux, tous deux PURS (aucun timer armé ici — l'armement reste au cœur du Pod).
  SPLIT REFUSÉ (passe modules 2026-07-05) : ces deux rôles sont les deux MOITIÉS d'un même
  watchdog — `arm_result_deadline_actions` (Pod) arme ENSEMBLE le deadline (`monitor_timeout_ms`)
  et le tick (`liveness_tick_ms`), et le tick RÉ-ARME le deadline quand la sonde bouge. Les
  séparer donnerait un module de ~30 lignes (le calcul du timeout) dont l'unique consommateur
  co-arme systématiquement avec la sortie de l'autre : deux modules pour UN mécanisme, frontière
  artificielle. Ils restent co-localisés, sections distinctes ci-dessous :

  - **Sonde de liveness** : à chaque tick du generic timeout `:liveness`, échantillonner deux signaux complémentaires
    d'activité du pod — taille cumulée des `<session_id>.jsonl` (« a produit une sortie ») et jiffies
    CPU du process claude via `/proc/<os_pid>/stat` (« moud sans sortie encore ») — et décider si le
    pod a BOUGÉ depuis le tick précédent. Un mouvement → le `Pod` ré-arme le deadline (repousse le
    kill) ; un silence total → le deadline court jusqu'au timeout.
  - **Timeout de réponse** : dériver le délai (ms) du watchdog `:result_deadline` depuis le cap-profile
    (override `spec.timeouts.response_sec`, sinon défaut codé par scope) et la cadence du tick.

  Le module ne tient AUCUN state propre, n'arme AUCUN timer, n'écrit RIEN : le `Pod` lui passe son
  `state` (map) en argument ; les fonctions lisent `state.pod_dir`/`.session_id`/`.port`/`.cap_profile`/
  `.opts` + la config `:fleet_spawner` + `File`/`Port`. Les opts per-pod (`:liveness_tick_ms`,
  `:liveness_probe_fun`) sont lues via `keyword_opt/2` → un test injecte sonde et cadence SANS config
  globale (async-safe). Dépend de `Fleet.CapProfile` (le pattern `%Fleet.CapProfile{spec: spec}` de
  `default_response_timeout_sec`), déjà une dep de l'app, et de `Pod.SessionFiles` (glob partagé des
  jsonl de session) ; aucune dépendance vers `Fleet.Spawner.Pod` (pas de cycle).

  ## Contrat (appelé par `Pod`)

  - `liveness_sample/1` (PUBLIC) — échantillonne `{taille_jsonl, jiffies_cpu}` (appelé par le handler
    de tick liveness `handle_event({:timeout, :liveness}, :tick, :monitoring, ...)`).
  - `liveness_moved?/2` (PUBLIC) — compare l'échantillon précédent au nouveau (appelé par le même
    handler).
  - `liveness_tick_ms/1` (PUBLIC) — cadence du tick (appelé par `liveness_tick_action`, qui RESTE
    dans `Pod` car il fabrique l'ACTION de generic timeout `{:timeout, :liveness}`).
  - `monitor_timeout_ms/1` (PUBLIC) — délai (ms) du `:result_deadline` (appelé par
    `arm_result_deadline_actions`).

  `keyword_opt/2`, `grew?/2`, `jsonl_size/1`, `proc_cpu_jiffies/1`, `to_int/1` et
  `default_response_timeout_sec/1` sont internes (appelés UNIQUEMENT par les fonctions ci-dessus).
  """

  # ============================================================
  # Rôle 1 — sonde de liveness (le pod a-t-il BOUGÉ ?) + cadence du tick
  # ============================================================

  @doc """
  Cadence (ms) du tick de liveness : opt per-pod `:liveness_tick_ms` (async-safe test) sinon
  config `:fleet_spawner, :liveness_tick_ms`, défaut 30 000. Appelé par `liveness_tick_action`
  (qui RESTE dans `Pod` : il fabrique l'ACTION de generic timeout `{:timeout, :liveness}`).
  """
  @spec liveness_tick_ms(map()) :: non_neg_integer()
  def liveness_tick_ms(state) do
    keyword_opt(state, :liveness_tick_ms) ||
      Application.get_env(:fleet_spawner, :liveness_tick_ms, 30_000)
  end

  # Lit une option per-pod depuis `state.opts` (keyword passé au spawn) → `nil` si absente/illisible. Permet
  # d'injecter en test SANS config globale (async-safe) : `:liveness_probe_fun`, `:liveness_tick_ms`.
  defp keyword_opt(state, key) do
    case Map.get(state, :opts) do
      opts when is_list(opts) -> Keyword.get(opts, key)
      _ -> nil
    end
  end

  @doc """
  Sonde de liveness : `{taille_jsonl, jiffies_cpu}` — deux signaux complémentaires (le jsonl
  couvre « a produit une sortie », le CPU couvre « moud sans sortie encore »). Injectable (test)
  via l'opt per-pod `:liveness_probe_fun` (fun/1) ou la config. `nil` sur un signal = indisponible
  (pas de fichier / pas de port) → ne compte pas comme mouvement (biais anti-kill : on ne tue pas
  sur un nil). Forme par défaut `{taille | nil, jiffies | nil}` ; une sonde injectée rend sa
  propre forme opaque (comparée par `liveness_moved?/2` seulement) — d'où le retour `term()`.
  Appelé par le handler de tick (`handle_event({:timeout, :liveness}, :tick, …)`).
  """
  @spec liveness_sample(map()) :: term()
  def liveness_sample(state) do
    case keyword_opt(state, :liveness_probe_fun) ||
           Application.get_env(:fleet_spawner, :liveness_probe_fun) do
      fun when is_function(fun, 1) -> fun.(state)
      _ -> {jsonl_size(state), proc_cpu_jiffies(state)}
    end
  end

  @doc """
  Le pod a-t-il BOUGÉ depuis l'échantillon précédent ? Mouvement = au moins UN des deux signaux a
  crû. Pas de baseline (1er tick, `prev = nil`) → vivant (bénéfice du doute). Appelé par le même
  handler de tick que `liveness_sample/1`.
  """
  @spec liveness_moved?(term(), term()) :: boolean()
  def liveness_moved?(nil, _now), do: true
  def liveness_moved?({pj, pc}, {nj, nc}), do: grew?(pj, nj) or grew?(pc, nc)

  defp grew?(prev, now) when is_integer(prev) and is_integer(now), do: now > prev
  defp grew?(_, _), do: false

  # Taille cumulée des `<session_id>.jsonl` du pod (append-only → croît à chaque message/tool-result ;
  # glob partagé `SessionFiles.jsonl_paths/2`). `nil` si aucun jsonl (session pas encore écrite).
  defp jsonl_size(state) do
    state.pod_dir
    |> Fleet.Spawner.Pod.SessionFiles.jsonl_paths(state.session_id)
    |> Enum.map(fn f ->
      case File.stat(f) do
        {:ok, %{size: s}} -> s
        _ -> 0
      end
    end)
    |> case do
      [] -> nil
      sizes -> Enum.sum(sizes)
    end
  end

  # utime+stime (jiffies) du process claude via `/proc/<os_pid>/stat`. Robuste au `comm` (champ 2, entre
  # parenthèses, peut contenir espaces/`)`) : on découpe après le DERNIER `)` (champ 3 = index 0 du reste →
  # utime = index 11, stime = index 12). `nil` si pas de port / process parti / proc illisible. NB : mesure
  # le process PARENT (un tool enfant CPU-lourd n'y figure pas — couvert par le OU-jsonl + la fenêtre de
  # silence).
  defp proc_cpu_jiffies(state) do
    with port when is_port(port) <- Map.get(state, :port),
         {:os_pid, pid} <- Port.info(port, :os_pid),
         {:ok, raw} <- File.read("/proc/#{pid}/stat") do
      fields =
        raw |> String.split(")") |> List.last() |> String.trim() |> String.split(~r/\s+/)

      case {to_int(Enum.at(fields, 11)), to_int(Enum.at(fields, 12))} do
        {u, s} when is_integer(u) and is_integer(s) -> u + s
        _ -> nil
      end
    else
      _ -> nil
    end
  end

  defp to_int(nil), do: nil

  defp to_int(str) when is_binary(str) do
    case Integer.parse(str) do
      {n, _} -> n
      :error -> nil
    end
  end

  # ============================================================
  # Rôle 2 — calcul du timeout de RÉPONSE (le deadline que le rôle 1 ré-arme)
  # ============================================================

  @doc """
  Délai (ms) du watchdog `:result_deadline` — timeout de RÉPONSE (pas budget de durée de vie) au
  tool MCP submit_result. Si pas de réponse dans le délai → `:result_deadline` →
  `transition_failed` → le pod MEURT (tous `:temporary`) : PAS de relaunch OTP. Conséquence
  (couplage) : la task active est à libérer (`TaskQueue.clear_for_pod`) sinon elle reste orpheline
  (assigned/pending sans pod), et le re-dispatch est délibéré (recovery boot-orchestrator).

  Override par cap-profile optionnel : `spec.timeouts.response_sec`. Sinon défaut codé par scope
  (one-shot = 300 s ; `forever` = 60 s, inerte — `arm_result_deadline_actions` n'arme pas pour un
  permanent). Appelé par `arm_result_deadline_actions` (`Pod`).
  """
  @spec monitor_timeout_ms(map()) :: non_neg_integer()
  def monitor_timeout_ms(state) do
    override = get_in(state.cap_profile.spec, ["timeouts", "response_sec"])

    sec =
      cond do
        is_number(override) and override > 0 ->
          override

        true ->
          default_response_timeout_sec(state.cap_profile)
      end

    # Le state_timeout natif `:result_deadline` exige un entier non-négatif (ms). `is_number(override)`
    # accepte les FLOATS (un cap-profile `timeouts.response_sec: 1.5` passe la validation) → `sec * 1000` =
    # float → ArgumentError dans `arm_result_deadline_actions` qui CRASHERAIT le Pod sans transition_failed.
    # `round/1` coerce → entier (ms), quel que soit l'override.
    round(sec * 1000)
  end

  defp default_response_timeout_sec(%Fleet.CapProfile{spec: spec}) do
    # Pas de band-aid `forever -> 60_000` : arm_result_deadline_actions n'arme PAS pour `forever`
    # (un permanent n'a pas de timeout de réponse), et le fire ne tue que si une task est
    # réellement active. La valeur `forever` ci-dessous est donc inerte (forever n'arme
    # jamais) ; conservée par cohérence si un override `spec.timeouts.response_sec` la
    # réactivait un jour.
    case get_in(spec, ["invocation", "lifetime_scope"]) do
      "forever" -> 60
      _other -> 300
    end
  end
end
