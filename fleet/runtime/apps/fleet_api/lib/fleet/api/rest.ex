defmodule Fleet.API.Rest do
  @moduledoc """
  Plug.Router HTTP `:8080` endpoints REST.

  ## Routes MVP

    * `GET /api/health` — readiness probe (200 dès Cowboy bind ; consommé par `lcars-readiness`)
    * `GET /api/readiness/deep` — état opérationnel LIVE via
      `Fleet.API.Readiness.deep/0` — anti-vert-creux
    * `GET /api/workflow_runs` / `issues` / `pods` — lecture état (stubs MVP)
    * `POST /api/admin/spawn` — filtre le payload par allowlist DTO (422 si un champ interne du
      spawner / une clé inconnue est présent), valide le cap-profile (400 si absent, 422 si
      inconnu / host-native), exige un `brief` pour un cap-profile one-shot (422 sinon — miroir
      R18, évite le 202 menteur) PUIS broadcast `admin.spawn.request` event + 202

  ## Auth — lecture no-auth, écriture gardée (pas de blanket no-auth)

  Pas d'auth applicative *pour la lecture*. Le HMAC `X-Auth-Token` (bearer statique sur la
  constante `"fleet-api-v1"` — pas une signature de requête) a été RETIRÉ : intra-container
  non-exposé = zéro surface, et une auth bricolée donne un faux sentiment de sécurité (pire
  que rien). **La frontière est l'isolation réseau** : ne PAS publier `:8080` hors du
  container (bind loopback / `docker exec`) ; tunnel (WireGuard/Tailscale) pour un accès
  distant. Threat-model assumé = LAN / humains de confiance.

  La lecture (dashboard GET, observation) reste no-auth — légitime, inchangé. **L'écriture de
  config a été retirée** : il n'existe plus de porte d'écriture générique sur le repo de config.
  Une directive active (cap-profiles, coord-policies, workflow_maps) ne se modifie QUE par git/forge
  (la source de vérité tracée), jamais par un POST no-auth. La SEULE écriture restante est
  `POST /api/admin/spawn`, qui n'est PAS couverte par un blanket no-auth : elle garde ses gardes
  propres (allowlist DTO + host-native refusé à l'admission).
  """

  use Plug.Router

  alias Fleet.EventRouter.Bus

  plug(:match)
  plug(Plug.Parsers, parsers: [:json], json_decoder: Jason)
  plug(:dispatch)

  # Public health probe (200 dès Cowboy bind, consommé par `lcars-readiness`)
  get "/api/health" do
    send_json(conn, %{status: "ok", ts: DateTime.utc_now() |> DateTime.to_iso8601()})
  end

  # Readiness deep : état opérationnel LIVE (anti-vert-creux). Vue de câblage
  # interne (pas un probe public comme /api/health). 200 même si `status: degraded`
  # — la dégradation est une donnée, pas une erreur HTTP.
  get "/api/readiness/deep" do
    send_json(conn, Fleet.API.Readiness.deep())
  end

  get "/api/workflow_runs" do
    send_json(conn, %{workflow_runs: []})
  end

  get "/api/issues" do
    send_json(conn, %{issues: []})
  end

  get "/api/pods" do
    send_json(conn, %{pods: []})
  end

  # Version du build servi — SHA git court + dirty + ref + source (cf.
  # `Fleet.API.BuildInfo`). Rend la version CONSTATABLE (e2e, debug) sans la
  # déduire. LECTURE → no-auth légitime, cohérent avec le § Auth ci-dessus.
  get "/api/version" do
    send_json(conn, Fleet.API.BuildInfo.current())
  end

  post "/api/admin/spawn" do
    # Chokepoint « nouveau pod opérateur » : refusé pendant un drain de
    # shutdown (Fleet.Shutdown.Quiesce). 503 = indisponible temporairement.
    # REST est l'UNIQUE producteur de l'event `admin.spawn.request` (vérifié) —
    # gater ici couvre donc intégralement l'admission de pods top-level.
    if Fleet.Shutdown.Quiesce.quiescing?() do
      send_resp(conn, 503, ~s|{"error":"quiescing — shutdown drain in progress"}|)
    else
      do_admin_spawn(conn)
    end
  end

  defp do_admin_spawn(conn) do
    raw = conn.body_params || %{}

    # ALLOWLIST D'ADMISSION (AVANT tout) : `/api/admin/spawn` est une surface no-auth. Le PublishConsumer
    # convertit ENSUITE `payload["opts"]` en opts internes du spawner via `to_keyword/1` — sans filtre, des
    # opts privilégiés (`pod_dir_root`, `state_fs_root`, `human`, `project` → clone d'un repo attaquant dans
    # le pod, `recall_seed_jsonl`, `resume`, `session_id`, `rc_name`, `allow_no_brief`, seams module/fun…)
    # deviendraient pilotables depuis l'API. On n'accepte donc qu'un DTO public PLAT et explicite ; toute
    # clé hors allowlist → 422 AVANT le moindre broadcast (rien n'atteint le consumer/spawner). Le payload
    # canonique reconstruit ici est la SEULE chose diffusée — l'API construit elle-même l'`opts` interne,
    # un `opts` brut fourni par le client est rejeté comme clé inconnue.
    case parse_admin_spawn_dto(raw) do
      {:ok, payload} ->
        validate_and_broadcast_spawn(conn, payload)

      {:error, {:forbidden_fields, fields}} ->
        # 422 Unprocessable — la requête porte des champs non publics (opts internes du spawner / seams /
        # racines disque). On REFUSE à la frontière plutôt que de laisser le consumer les interpréter.
        send_resp(
          conn,
          422,
          Jason.encode!(%{
            error: "champs non autorisés sur /api/admin/spawn",
            forbidden: Enum.sort(fields)
          })
        )

      {:error, {:invalid_pod_id, value}} ->
        send_resp(
          conn,
          422,
          Jason.encode!(%{
            error: "pod_id invalide (attendu [A-Za-z0-9._-], sans '..')",
            value: inspect(value)
          })
        )
    end
  end

  defp validate_and_broadcast_spawn(conn, payload) do
    # VALIDER le cap-profile AVANT l'ACK. Si le 202 partait dès le broadcast, un
    # `cap_profile_name` inexistant ne serait détecté QUE plus tard dans `PublishConsumer`, où
    # `CapProfile.load` KO = un simple warning, ZÉRO pod spawné. L'appelant (`lcars spawn <rôle>`)
    # verrait « mis en file (202) » pour un rôle qui ne produira jamais de pod → 202 menteur. Le
    # contrat HTTP doit être honnête : le cap-profile fait partie de l'admission, pas d'un best-effort
    # async. On le résout ICI (même loader que le consumer, source unique `Fleet.CapProfile.load/1`).
    case validate_cap_profile(payload) do
      {:ok, cap} ->
        # MIROIR de R18 (Fleet.Spawner.brief_guard) à l'ADMISSION : un cap-profile one-shot
        # (reviewer/qualifier/consultant) lancé SANS `brief` partirait sans travail → le spawner
        # le refuse (`brief_required`, ZÉRO pod). Sans cette garde, le 202 « mis en file » serait un
        # 202 menteur (jumeau exact du cap-profile menteur). On vérifie ICI, avant l'ACK.
        # `Fleet.Spawner.brief_required?/1` EST l'autorité partagée (même lecture `get_in` nil-aware
        # que `brief_guard`) → on n'a PAS recopié la règle (pas de divergence possible). Un one-shot
        # LÉGITIME porte son `brief` dans le DTO (allowlist) → `has_brief?` vrai → il passe.
        brief = get_in(payload, ["opts", "brief"])
        has_brief? = is_binary(brief) and brief != ""

        if Fleet.Spawner.brief_required?(cap) and not has_brief? do
          send_resp(
            conn,
            422,
            Jason.encode!(%{
              error: "brief requis (cap-profile one-shot)",
              reason:
                "lifetime_scope one-shot sans `brief` : le pod partirait sans travail (R18). Fournir `brief`."
            })
          )
        else
          do_broadcast_spawn(conn, payload)
        end

      {:error, :missing} ->
        send_resp(
          conn,
          400,
          ~s|{"error":"cap_profile_name (ou role) requis"}|
        )

      {:error, {:cap_profile, name, reason}} ->
        # 422 Unprocessable — la requête est bien formée mais le cap-profile nommé n'est pas chargeable
        # (absent / schema invalide) → AUCUN pod ne peut naître. Plus de 202 qui ment.
        send_resp(
          conn,
          422,
          Jason.encode!(%{error: "cap_profile inconnu : #{name}", reason: inspect(reason)})
        )

      {:error, {:host_native_forbidden, name}} ->
        # 422 Unprocessable — le cap-profile existe mais il est HOST-NATIVE (`containment: none`) : un pod
        # lancé hors-sandbox, SUR L'HÔTE *as* l'humain — le pouvoir le plus fort de la fleet (starfleet,
        # architecte-interactif). Cette porte spawn GÉNÉRIQUE no-auth ne doit JAMAIS l'atteindre : le host-
        # native a sa voie dédiée hors-bande (starfleet / `bin/host_launch.sh`). On REFUSE à l'admission,
        # AVANT le moindre broadcast → aucun pod hôte ne peut naître via l'API. Fail-closed par construction.
        send_resp(
          conn,
          422,
          Jason.encode!(%{
            error: "cap_profile host-native interdit via /api/admin/spawn : #{name}",
            reason:
              "containment != bwrap — le host-native passe par sa voie dédiée, pas l'API spawn"
          })
        )
    end
  end

  # Champs publics admis au top-level du DTO `/api/admin/spawn`. Tout le reste est REFUSÉ.
  #   * `cap_profile_name` / `role` — le profil de capacités (l'un des deux, requis ; validé plus bas)
  #   * `issue_id` — corrélation forge/event (string libre)
  #   * `brief` — le travail du pod (string) ; replacé dans l'`opts` interne construit par l'API
  #   * `pod_id` — identifiant de pod imposé (rare, admin) ; n'est accepté QUE s'il est path-safe
  #     (même règle que `Fleet.Spawner` : `[A-Za-z0-9._-]`, pas de `..`), sinon 422
  @admin_spawn_public_fields ~w(cap_profile_name role issue_id brief pod_id)

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
  # `PublishConsumer.handle_spawn_request`). Absent → `{:error, :missing}` (400) ; load KO →
  # `{:error, {:cap_profile, name, reason}}` (422) ; HOST-NATIVE (`containment != bwrap`) →
  # `{:error, {:host_native_forbidden, name}}` (422) ; chargé + sandboxé → `{:ok, cap}` (l'admission
  # continue ; le cap chargé est rendu pour la garde brief one-shot R18 du call-site, sans re-load).
  #
  # La garde host-native est ICI, à l'admission : un cap-profile `containment: none` (starfleet,
  # architecte-interactif) lancerait un pod HORS-SANDBOX sur l'hôte *as* l'humain via cette porte spawn
  # générique no-auth — le pouvoir le plus fort de la fleet, atteignable sans rien prouver. On le rend
  # IRREPRÉSENTABLE par ce chemin : refus AVANT broadcast (rien n'atteint le consumer/spawner). Le host-
  # native garde sa voie dédiée hors-bande. Même loader + même lecture de containment que le spawner
  # (source unique `Fleet.CapProfile`) → pas de divergence de verdict entre l'API et le lancement réel.
  defp validate_cap_profile(payload) do
    case Map.get(payload, "cap_profile_name") || Map.get(payload, "role") do
      name when is_binary(name) and name != "" ->
        case Fleet.CapProfile.load(name) do
          {:ok, cap} ->
            if Fleet.CapProfile.containment(cap) == "bwrap",
              do: {:ok, cap},
              else: {:error, {:host_native_forbidden, name}}

          {:error, reason} ->
            {:error, {:cap_profile, name, reason}}
        end

      _ ->
        {:error, :missing}
    end
  end

  defp do_broadcast_spawn(conn, payload) do
    # Schéma canon %Fleet.Event{source: :api} construit via le constructeur canonique
    # (source validée contre l'enum, timestamp DateTime garanti), pas un struct littéral.
    event = Fleet.Event.new(:api, :"admin.spawn.request", payload: payload)

    case safe_broadcast(event) do
      :ok -> send_resp(conn, 202, ~s|{"status":"queued"}|)
      {:error, reason} -> send_resp(conn, 400, Jason.encode!(%{error: inspect(reason)}))
    end
  end

  defp safe_broadcast(%Fleet.Event{} = event) do
    Bus.broadcast("fleet.events", event)
  rescue
    e in Fleet.Event.UnregisteredError -> {:error, e.message}
    e in [ArgumentError, FunctionClauseError] -> {:error, inspect(e)}
  end

  # Dashboard V2 Elixir natif. Mount Fleet.API.Dashboard sous
  # /dashboard (UI GET-only). Pas d'auth — comme toute l'API (cf. moduledoc § Auth).
  forward("/dashboard", to: Fleet.API.Dashboard)

  match _ do
    send_resp(conn, 404, ~s|{"error":"not found"}|)
  end

  defp send_json(conn, payload) do
    send_resp(conn, 200, Jason.encode!(payload))
  end
end
