defmodule Fleet.API.SpawnAdmission do
  @moduledoc """
  Pipeline d'ADMISSION de `POST /api/admin/spawn` — la POLICY de la seule
  écriture de l'API, séparée du routing HTTP (éclatement C4 2026-07-05) :
  `Fleet.API.Rest` mappe chaque verdict rendu ici sur son statut HTTP, ce
  module décide QUI passe. Fonctions pures + lectures catalogue (aucun process).

  ## Pourquoi une admission stricte sur une surface no-auth

  `/api/admin/spawn` est no-auth (frontière = isolation réseau, cf. moduledoc
  `Fleet.API.Rest` § Auth). Le `PublishConsumer` convertit ENSUITE
  `payload["opts"]` en opts internes du spawner via `to_keyword/1` — sans
  filtre, des opts privilégiés (`pod_dir_root`, `state_fs_root`, `human`,
  `project` → clone d'un repo attaquant dans le pod, `recall_seed_jsonl`,
  `resume`, `session_id`, `rc_name`, `allow_no_brief`, seams module/fun…)
  deviendraient pilotables depuis l'API. Le pipeline (ordre fixe) :

    1. **Allowlist DTO** (`@admin_spawn_public_fields`) — seul un DTO public
       PLAT est admis ; toute clé inconnue (y compris un `opts` brut) →
       `{:error, {:forbidden_fields, …}}` AVANT le moindre broadcast. Le
       payload canonique reconstruit ici est la SEULE chose diffusée — l'API
       construit elle-même l'`opts` interne.
    2. **`pod_id` path-safe** — un pod_id est interpolé dans des paths FS
       (`~/pods/pod_<id>`) : seul le charset `[A-Za-z0-9._-]` sans `..` passe
       (autorité `Fleet.Spawner.valid_pod_id?/1`, pas une regex recopiée).
    3. **Cap-profile chargeable** — validé AVANT l'ACK : si le 202 partait dès
       le broadcast, un `cap_profile_name` inexistant ne serait détecté QUE
       dans `PublishConsumer` (simple warning, ZÉRO pod) → 202 menteur. Même
       loader que le consumer (source unique `Fleet.CapProfile.load/1`).
    4. **Host-native refusé** — un cap-profile `containment: none` lancerait
       un pod HORS-SANDBOX sur l'hôte *as* l'humain (le pouvoir le plus fort
       de la fleet) via cette porte générique no-auth. Rendu IRREPRÉSENTABLE
       par ce chemin : refus à l'admission, le host-native garde sa voie
       dédiée hors-bande (starfleet / `bin/host_launch.sh`). Fail-closed.
    5. **Brief requis pour un one-shot** — MIROIR de R18
       (`Fleet.Spawner.brief_guard`) : un one-shot sans `brief` partirait sans
       travail → le spawner le refuserait (ZÉRO pod), donc le 202 mentirait.
       `Fleet.Spawner.brief_required?/1` EST l'autorité partagée (pas de règle
       recopiée, pas de divergence possible).

  `broadcast/1` (l'étape post-admission) émet le schema canon
  `%Fleet.Event{source: :api}` — un event hors registry ou malformé devient
  `{:error, _}` (surface HTTP 400 côté Rest), jamais un crash du handler.
  """

  alias Fleet.EventRouter.Bus

  @typedoc """
  Verdicts de refus d'admission — chacun mappé sur UN statut HTTP par
  `Fleet.API.Rest` (400 pour `:missing_cap_profile`, 422 pour le reste).
  """
  @type refusal ::
          {:forbidden_fields, [String.t()]}
          | {:invalid_pod_id, term()}
          | :missing_cap_profile
          | {:cap_profile, String.t(), term()}
          | {:host_native_forbidden, String.t()}
          | :brief_required

  # Champs publics admis au top-level du DTO `/api/admin/spawn`. Tout le reste est REFUSÉ.
  #   * `cap_profile_name` / `role` — le profil de capacités (l'un des deux, requis ; validé plus bas)
  #   * `issue_id` — corrélation forge/event (string libre)
  #   * `brief` — le travail du pod (string) ; replacé dans l'`opts` interne construit par l'API
  #   * `pod_id` — identifiant de pod imposé (rare, admin) ; n'est accepté QUE s'il est path-safe
  #     (même règle que `Fleet.Spawner` : `[A-Za-z0-9._-]`, pas de `..`), sinon refus
  @admin_spawn_public_fields ~w(cap_profile_name role issue_id brief pod_id)

  @doc """
  Admission complète d'un body `POST /api/admin/spawn` (les 5 étapes du
  moduledoc, ordre fixe, premier refus rendu). `{:ok, payload}` = le payload
  CANONIQUE prêt à broadcaster (seule chose qui atteindra le consumer/spawner) ;
  `{:error, refusal}` = rien ne part, `Fleet.API.Rest` traduit en HTTP.

  Un body non-map (parseur JSON rendant autre chose) est traité comme un DTO
  vide → `{:error, :missing_cap_profile}` (le champ requis manque).
  """
  @spec admit(term()) :: {:ok, map()} | {:error, refusal()}
  def admit(raw) do
    with {:ok, payload} <- parse_admin_spawn_dto(raw),
         {:ok, cap} <- validate_cap_profile(payload),
         :ok <- check_brief_required(payload, cap) do
      {:ok, payload}
    end
  end

  @doc """
  Broadcast du payload ADMIS : schema canon `%Fleet.Event{source: :api}`
  construit + broadcasté via `Bus.emit` (source validée contre l'enum,
  timestamp DateTime garanti). La construction ET le broadcast sont DANS le
  rescue : la POLITIQUE de l'API est de faire surface HTTP — un event hors
  registry (`UnregisteredError`) ou malformé (`ArgumentError`/
  `FunctionClauseError` du constructeur) devient `{:error, _}` (→ 400 côté
  Rest), jamais un crash du handler.
  """
  @spec broadcast(map()) :: :ok | {:error, term()}
  def broadcast(payload) do
    Bus.emit(:api, :"admin.spawn.request", payload: payload)
  rescue
    e in Fleet.Event.UnregisteredError -> {:error, e.message}
    e in [ArgumentError, FunctionClauseError] -> {:error, inspect(e)}
  end

  # Parse le payload entrant vers un DTO public allowlisté. Le `opts` interne du spawner n'est JAMAIS pris
  # du client : l'API le (re)construit à partir des seuls champs publics (`brief`, `pod_id`). Toute clé
  # top-level inconnue ou interdite (y compris un `opts` brut) → `{:error, {:forbidden_fields, ...}}`.
  defp parse_admin_spawn_dto(raw) when is_map(raw) do
    extraneous = Map.keys(raw) -- @admin_spawn_public_fields

    cond do
      extraneous != [] ->
        {:error, {:forbidden_fields, extraneous}}

      true ->
        with {:ok, opts} <- build_admin_opts(raw) do
          payload =
            raw
            |> Map.take(["cap_profile_name", "role", "issue_id"])
            |> maybe_put_opts(opts)

          {:ok, payload}
        end
    end
  end

  defp parse_admin_spawn_dto(_), do: {:ok, %{}}

  # Construit l'`opts` du spawn à partir des seuls champs publics. `pod_id` n'est retenu que path-safe.
  defp build_admin_opts(raw) do
    opts = if is_binary(raw["brief"]), do: %{"brief" => raw["brief"]}, else: %{}

    case Map.fetch(raw, "pod_id") do
      :error ->
        {:ok, opts}

      {:ok, pod_id} when is_binary(pod_id) ->
        if valid_pod_id?(pod_id),
          do: {:ok, Map.put(opts, "pod_id", pod_id)},
          else: {:error, {:invalid_pod_id, pod_id}}

      {:ok, other} ->
        {:error, {:invalid_pod_id, other}}
    end
  end

  defp maybe_put_opts(payload, opts) when map_size(opts) == 0, do: payload
  defp maybe_put_opts(payload, opts), do: Map.put(payload, "opts", opts)

  # Même contrat que `Fleet.Spawner` : un pod_id est interpolé dans des paths FS (`~/pods/pod_<id>`),
  # donc seul un charset path-safe sans remontée `..` est admis. L'autorité de cette règle vit côté
  # spawner, qui possède les chemins et sockets dérivés du pod_id ; l'API ne recopie pas la regex.
  defp valid_pod_id?(id), do: Fleet.Spawner.valid_pod_id?(id)

  # Résout le cap-profile demandé (`cap_profile_name` ou `role`, mêmes clés que
  # `PublishConsumer.handle_spawn_request`). Absent → `{:error, :missing_cap_profile}` ; load KO →
  # `{:error, {:cap_profile, name, reason}}` ; HOST-NATIVE (`containment != bwrap`) →
  # `{:error, {:host_native_forbidden, name}}` ; chargé + sandboxé → `{:ok, cap}` (l'admission
  # continue ; le cap chargé alimente la garde brief one-shot R18, sans re-load). Même loader +
  # même lecture de containment que le spawner (source unique `Fleet.CapProfile`) → pas de
  # divergence de verdict entre l'API et le lancement réel.
  defp validate_cap_profile(payload) do
    case Map.get(payload, "cap_profile_name") || Map.get(payload, "role") do
      name when is_binary(name) and name != "" ->
        case Fleet.CapProfile.load(name) do
          {:ok, cap} ->
            if Fleet.CapProfile.bwrap?(cap),
              do: {:ok, cap},
              else: {:error, {:host_native_forbidden, name}}

          {:error, reason} ->
            {:error, {:cap_profile, name, reason}}
        end

      _ ->
        {:error, :missing_cap_profile}
    end
  end

  # MIROIR de R18 (Fleet.Spawner.brief_guard) à l'ADMISSION : un cap-profile one-shot
  # (reviewer/qualifier/consultant) lancé SANS `brief` partirait sans travail → le spawner
  # le refuse (`brief_required`, ZÉRO pod). Sans cette garde, le 202 « mis en file » serait un
  # 202 menteur (jumeau exact du cap-profile menteur). `Fleet.Spawner.brief_required?/1` EST
  # l'autorité partagée (même lecture `get_in` nil-aware que `brief_guard`) → on n'a PAS recopié
  # la règle (pas de divergence possible). Un one-shot LÉGITIME porte son `brief` dans le DTO
  # (allowlist) → `has_brief?` vrai → il passe.
  defp check_brief_required(payload, cap) do
    brief = get_in(payload, ["opts", "brief"])
    has_brief? = is_binary(brief) and brief != ""

    if Fleet.Spawner.brief_required?(cap) and not has_brief?,
      do: {:error, :brief_required},
      else: :ok
  end
end
