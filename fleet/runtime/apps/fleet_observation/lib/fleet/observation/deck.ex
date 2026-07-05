defmodule Fleet.Observation.Deck do
  @moduledoc """
  Plug.Router de l'observation deck le port observation (per-humain).

  ## Routes

    * `GET /` — shell LCARS : header BRIDGE (LED santé + horloge) + les 7 decks
      (PODS live, les autres alimentés par la projection du read-model).
    * `GET /health` — sonde de vivacité du deck.
    * `GET /api/pods` — JSON des pods vivants (`Fleet.Spawner.list_pods/0`,
      projetés en vue JSON-safe). Lecture seule, no-auth, intra-release.
    * `GET /static/*` — assets (`priv/static/lcars-tva.css`, `assets/*.svg`).

  ## Frontière read

  `/api/pods` lit `Fleet.Spawner.list_pods/0` (Ring 1 read direct, snapshot live).
  `/api/projection` lit `Fleet.Observation.ReadModel` (projection du stream
  `%Fleet.Event{}`) ; le deck lit **la projection**, jamais
  l'état GenServer interne d'un tiers.

  ## Frontière view

  Le GABARIT (HTML/CSS/JS inline) vit dans `Fleet.Observation.Deck.View`
  (rendu pur — éclatement C4 2026-07-05) : ce module reste le CONTRÔLEUR
  (routing + dérivation du catalogue de rôles + snapshots live) et passe la
  donnée à la vue en argument. La vue ne lit aucune source elle-même.
  """

  use Plug.Router

  alias Fleet.Observation.Deck.View

  plug(Plug.Static,
    at: "/static",
    from: {:fleet_observation, "priv/static"},
    gzip: false,
    only: ~w(lcars-tva.css assets)
  )

  plug(:match)
  plug(:dispatch)

  get "/" do
    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, View.page())
  end

  # Tableau basique : un bloc fixe par rôle (`dashboard_roles/0`), état du/des pod(s)
  # correspondant(s) rendu CÔTÉ SERVEUR (pas de JS). Réutilise le même snapshot live
  # que `/api/pods` (`Fleet.Spawner.list_pods/0`) ; le rendu est délégué à la vue pure
  # (`View.table_page/2`), le contrôleur ne fait que collecter roles + pods groupés.
  get "/table" do
    roles = dashboard_roles()
    by_role = Enum.group_by(Fleet.Spawner.list_pods(), &Map.get(&1, :role))

    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, View.table_page(roles, by_role))
  end

  get "/health" do
    conn
    |> json(200, %{
      status: "ok",
      deck: "fleet_observation",
      port: Application.get_env(:fleet_observation, :http_port)
    })
  end

  get "/api/pods" do
    known = display_roles()
    pods = Fleet.Spawner.list_pods() |> Enum.map(&pod_view(&1, known))
    body = Jason.encode!(%{pods: pods, count: length(pods)})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, body)
  end

  # Projection event-dérivée (read-model) : alimente FLOW/GATEKEEPER/
  # STREAM/COORDINATION/DIAGNOSTICS/BRIDGE. Read ETS direct (bypass GenServer).
  get "/api/projection" do
    body = Jason.encode!(Fleet.Observation.ReadModel.projection())

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, body)
  end

  match _ do
    json(conn, 404, %{error: "deck route not found"})
  end

  # Vue JSON-safe d'un pod : sous-ensemble du `:info`. Le runtime peut mettre
  # des termes non-encodables (`last_error`/`last_result`) → exclus. `phase`
  # (atom) + listes/strings/nil s'encodent. `role` ajouté pour l'icône.
  defp pod_view(info, known) do
    %{
      pod_id: info.pod_id,
      role: role_of(info, known),
      issue_id: Map.get(info, :issue_id),
      phase: info.phase,
      conditions: Map.get(info, :conditions, []),
      session_id: Map.get(info, :session_id),
      tmux_session: Map.get(info, :tmux_session)
    }
  end

  # Le rôle vit UNIQUEMENT sous `:role` (gravé au spawn = nom du cap-profile, la source unique). Hors
  # catalogue d'AFFICHAGE → nil : le client rend l'icône générique. Ce n'est PAS un masquage du pod
  # (le pod reste listé) ni une autorité de rôle runtime — juste le choix d'icône.
  defp role_of(info, known) do
    role = Map.get(info, :role)
    if is_binary(role) and role in known, do: role, else: nil
  end

  # Catalogue d'AFFICHAGE (rôle → icône SVG dédiée) DÉRIVÉ des assets réellement présents dans
  # `priv/static/assets` : tout `<role>.svg` déposé là est reconnu automatiquement → plus de liste codée
  # en dur à garder en sync avec les fichiers (la duplication liste↔assets disparaît, l'asset est l'autorité).
  # Exclusions : les `favicon*.svg` (chrome, pas un rôle) et `starfleet` (domaine système hors-bande,
  # l'asset existe mais aucun panel ne l'instrumente). `File.ls` KO (dir absent) → `[]` : dégradation sûre
  # (tous les pods en icône générique, jamais de crash). Résolu via `app_dir` = même priv que `Plug.Static`.
  defp display_roles do
    case File.ls(Application.app_dir(:fleet_observation, "priv/static/assets")) do
      {:ok, files} ->
        for f <- files,
            String.ends_with?(f, ".svg"),
            role = Path.rootname(f),
            not String.starts_with?(role, "favicon"),
            role != "starfleet",
            do: role

      _ ->
        []
    end
  end

  # Rôles à afficher = catalogue cap-profiles (`Fleet.CapProfile.list/0`, source unique du domaine)
  # filtré aux rôles qui tournent comme POD de fleet (donc peuvent avoir un état). Trié pour un ordre
  # stable. Catalogue illisible → `[]` (dégradation sûre, jamais de crash du deck).
  defp dashboard_roles do
    case Fleet.CapProfile.list() do
      {:ok, names} ->
        names
        |> Enum.reject(&memory_x_role?/1)
        |> Enum.filter(&pod_role?/1)
        |> Enum.sort()

      {:error, _} ->
        []
    end
  end

  # Garde EN DUR temporaire (validée user) : `CapProfile.list/0` ramasse aussi les profils Memory-X
  # des sous-dossiers `monks/` / `archivistes/` — ce ne sont pas des rôles d'agent à afficher. Absente
  # de CE repo aujourd'hui (donc inerte ici) mais `list/0` scanne réellement ces sous-dossiers, donc ce
  # n'est pas une garde sur du vide : elle mord dès qu'un de ces profils existe. Propre à terme = un champ
  # sémantique (`monk_registry`/`monk_instance` non-nul), pas un préfixe de nom.
  defp memory_x_role?(name),
    do: String.starts_with?(name, "monk") or String.starts_with?(name, "archivist")

  # Rôle qui tourne comme POD de fleet (peut donc porter un état pod) : `host_native != true`.
  # Même discriminateur sémantique que `Fleet.Spawner.PermanentBoot.boot_at_start?/1` — exclut `starfleet`
  # (host-natif, boote via systemd, « n'a PAS de pod ») sans coder son nom en dur. Profil illisible → exclu.
  defp pod_role?(name) do
    case Fleet.CapProfile.load(name) do
      {:ok, %Fleet.CapProfile{spec: spec}} -> get_in(spec, ["invocation", "host_native"]) != true
      _ -> false
    end
  end

  # R6 : l'envoi JSON (content-type + encode + send) tapé UNE fois — les sends inline divergeaient
  # (content-type oublié sur le 404).
  defp json(conn, status, payload) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(payload))
  end
end
