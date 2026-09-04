defmodule Fleet.Observation.Deck do
  @moduledoc """
  Read-only observation router. It exposes health, live JSON-safe pod snapshots,
  event projections, role tables, and static assets. Routing and catalogue
  selection stay here; pure HTML rendering lives in `Deck.View`.
  """

  use Plug.Router

  require Logger

  alias Fleet.Observation.Deck.View

  # `priv/` ne porte que la feuille de style : elle EST du runtime, versionnee avec le code qui la
  # genere. Les medias de marque vivent sous `media_root/0`, pose par l'installation.
  plug(Plug.Static,
    at: "/static",
    from: {:lcars_fleet, "priv/observation/static"},
    gzip: false,
    only: ~w(lcars-tva.css)
  )

  plug(:match)
  plug(:dispatch)

  get "/" do
    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, View.page())
  end

  # ─── LES MEDIAS DE MARQUE ───────────────────────────────────────────────────────────────────────
  # Servis A LA MAIN plutot que par `Plug.Static`, et ce n'est pas un gout : `Plug.Static` resout son
  # `from:` a la COMPILATION (Plug.Builder appelle `init/1` la), donc il ne peut pas viser un chemin
  # que la config pose au boot. Une racine de medias figee dans le BEAM ne peut plus etre deplacee
  # par l'installation, qui est justement celle qui la pose.
  #
  # ⚠ LE CHEMIN EST RESOLU PUIS VERIFIE CONTRE SA RACINE. `..` dans une URL est la faute la plus
  # vieille du web ; `Path.expand` + prefixe, sinon 404 — jamais un filtrage de la CHAINE, qui se
  # contourne par encodage. Meme forme que la route `/doc/` du deck de console, pour la meme raison.
  # DEUX ARBRES, ENUMERES : `avatars` (les roles) et `favicon` (le produit). Ils sont freres sous la
  # racine et servis par la meme route, mais le nom de l'arbre ne vient PAS de l'URL librement — il
  # est valide contre cette liste, sinon `/media/../../etc/` serait une question ouverte.
  get "/media/:tree/:file" do
    if tree in ~w(avatars favicon) do
      root = Path.join(media_root(), tree)
      full = Path.expand(Path.join(root, file))

      with true <- String.starts_with?(full, Path.expand(root) <> "/"),
           {:ok, type} <- media_type(full),
           {:ok, raw} <- File.read(full) do
        conn |> put_resp_content_type(type) |> send_resp(200, raw)
      else
        _ -> send_resp(conn, 404, "not found")
      end
    else
      send_resp(conn, 404, "not found")
    end
  end

  # ENUMEREE, pas devinee : ce qui n'est pas dans cette liste ne sort pas. Un dossier statique servi
  # par extension inconnue rend `application/octet-stream` ou pire, et la liste EST la surface.
  defp media_type(path) do
    case Path.extname(path) do
      ".svg" -> {:ok, "image/svg+xml"}
      ".png" -> {:ok, "image/png"}
      ".ico" -> {:ok, "image/x-icon"}
      _ -> :error
    end
  end

  get "/table" do
    case dashboard_roles() do
      {:ok, roles} ->
        by_role = Enum.group_by(Fleet.Spawner.list_pods(), &Map.get(&1, :role))

        conn
        |> put_resp_content_type("text/html")
        |> send_resp(200, View.table_page(roles, by_role))

      {:error, reason} ->
        # F-C125
        conn
        |> put_resp_content_type("text/html")
        |> send_resp(200, View.error_page(reason))
    end
  end

  # `socket`, not `port` (6-072/6-098): this deck has no address. Reporting a port here would be the
  # most convincing lie of the lot — a health endpoint answering `200` while naming a number nothing
  # binds. Whoever probes health is looking for where to reach this thing; the answer is a
  # path, and the caller reaching it over that very socket is what makes the field honest.
  get "/health" do
    conn
    |> json(200, %{
      status: "ok",
      deck: "fleet_observation",
      socket: Fleet.Observation.Application.deck_socket()
    })
  end

  # ⚠ UNE SEULE ENTRÉE MALFORMÉE EMPORTERAIT TOUT LE LISTING, ET C'EST UN ENDPOINT DE LECTURE.
  #
  # `pod_view/2` fait `info.pod_id` — un accès STRICT, qui lève `KeyError` si la clé manque : un seul
  # pod sans elle fait tomber `/api/pods` ENTIER, avec un message qui parle d'une clé, pas d'un pod.
  # Or ce seam écarte DÉJÀ ce qu'il ne peut pas afficher, et un pod sans `pod_id` est exactement
  # aussi inaffichable — on ne peut pas l'adresser. Il rejoint donc la même famille au lieu
  # d'emporter ses voisins : une vue read-only qui meurt sur une donnée punit le lecteur pour l'état
  # de ce qu'il regarde.
  #
  # ⚠ ET PAS `Map.get` → `pod_id: nil` : ce fichier interdit lui-même cette forme pour `role` —
  # « indiscernable de : ce pod n'a pas de rôle ». Un pod servi avec un id nul s'afficherait comme un
  # pod réel qu'on ne peut plus joindre. On écarte, et on le DIT.
  #
  # ⚖ ICI ET PAS DANS `Fleet.Spawner.list_pods/0` : le seam d'affichage décide ce qui s'affiche.
  # `list_pods` sert aussi le groupage plus haut dans ce fichier, qui lit par `Map.get` et tolère
  # l'absence — lui imposer le besoin de CETTE vue ferait décider une couche pour l'autre.
  get "/api/pods" do
    known = display_roles()

    {affichables, ecartes} =
      Fleet.Spawner.list_pods()
      |> Enum.split_with(&is_binary(Map.get(&1, :pod_id)))

    if ecartes != [] do
      Logger.warning(
        "Deck /api/pods: #{length(ecartes)} pod(s) SANS pod_id ecarte(s) du listing — " <>
          "inaffichables (rien ne permet de les adresser), pas invisibles : les autres sont servis. " <>
          "Une entree sans identifiant vient du substrat, pas de cette vue."
      )
    end

    pods = Enum.map(affichables, &pod_view(&1, known))
    body = Jason.encode!(%{pods: pods, count: length(pods)})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, body)
  end

  get "/api/projection" do
    # F-C124
    proj = Fleet.Observation.ReadModel.projection()
    body = Jason.encode!(Map.put(proj, :_status, Fleet.Observation.ReadModel.projection_status()))

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, body)
  end

  # THE READ-DIAGNOSTIC PLANE LIVES ON THE READ SOCKET. The aggregator modules stay in `Fleet.API`
  # (they already hold the cross-domain deps); the read plane serves them, because an operator
  # gating on `readiness/deep` ("red -> do not undertake work") curls THIS socket, the only one a
  # reader has. Serving them anywhere else leaves that reader blind.
  get "/api/readiness/deep" do
    json(conn, 200, Fleet.API.Readiness.deep())
  end

  get "/api/version" do
    json(conn, 200, Fleet.API.BuildInfo.current())
  end

  match _ do
    json(conn, 404, %{error: "deck route not found"})
  end

  # Exclude arbitrary runtime terms from the JSON view.
  #
  # Public `@doc false` for the same reason as `roles_for_display/1` below: the whitelist is what
  # `/api/pods` promises, and proving it through the route alone would need live pods. Same testable
  # split, same file.
  @doc false
  @spec pod_view(map(), term()) :: map()
  def pod_view(info, known) do
    %{
      pod_id: info.pod_id,
      # 6-057 — LE ROLE EST LA VERITE, L'ICONE EST UNE QUESTION D'AFFICHAGE. Les confondre — ne
      # sortir `role` que si un `.svg` du meme nom existe — sert `role: null` pour tout role sans
      # asset, indiscernable de « ce pod n'a pas de role ». Le repli generique est cote vue.
      role: role_of(info),
      # Ce que la vue doit savoir, dit separement : quel asset utiliser, `nil` = le generique.
      role_icon: role_icon(Map.get(info, :role), known),
      issue_id: Map.get(info, :issue_id),
      # THE LAST LINK OF THE CHAIN: publishing a key in `pod_info` is not enough, because this view
      # whitelists what `/api/pods` serves and the landing deck reads THIS endpoint. A key that
      # stops short of here exists everywhere except where its only consumer can see it.
      #
      # `nil` is a real answer, not a gap: a fleet-level pod belongs to no project. It reads as
      # "no project" ONLY because the runtime STATES it — a nil inferred from an absent mount would
      # mean "I could not tell", and the two are indistinguishable to the page.
      project_slug: Map.get(info, :project_slug),
      phase: info.phase,
      conditions: Map.get(info, :conditions, []),
      session_id: Map.get(info, :session_id),
      tmux_session: Map.get(info, :tmux_session)
    }
  end

  # The `is_binary` guard stays, and it is NOT the icon check: this view whitelists its keys to keep
  # arbitrary runtime terms out of the JSON, so a role that is not a string is not a role we can
  # serve. Absent or malformed -> `nil`, which here really does mean "no role".
  defp role_of(info) do
    role = Map.get(info, :role)
    if is_binary(role), do: role, else: nil
  end

  # `nil` = no asset of that name, render the generic icon. The DISPLAY degrades; the datum does not.
  defp role_icon(role, known) when is_binary(role) do
    if role in known, do: role, else: nil
  end

  defp role_icon(_role, _known), do: nil

  # LA RACINE DES MEDIAS INSTALLES — UNE source, posee par l'installation, lue par tout le monde.
  # `assets/` est la source ; l'installation la pose en `/opt/lcars/share/{avatars,favicon}`, a cote
  # de la doc, et le rail de deploiement lit le meme endroit. Un deuxieme exemplaire derive en
  # silence : une mise a jour touche un dossier et pas l'autre, et le deck affiche alors une
  # generation d'avatars pendant que la forge en pose une autre.
  defp media_root, do: Application.get_env(:lcars_fleet, :media_root, "/opt/lcars/share")

  # ⚠ AUCUN REPLI SUR `priv/`, ET C'EST UNE DECISION. Une installation qui n'a pas pose ses medias
  # est RATEE, pas degradee : un repli servirait une generation d'avatars perimee et rendrait vert
  # un deploiement a moitie fait. Ici
  # l'absence reste bruyante et l'affichage tombe sur l'icone generique, ce qui SE VOIT.
  @doc false
  # Public comme `roles_for_display/1` et pour la meme raison : c'est le point ou la source des
  # icones se mesure, et un temoin doit pouvoir constater qu'elle est bien la marque installee.
  #
  # `[]` fait partie du contrat, pas d'un cas d'erreur : racine absente ou illisible => aucune icone,
  # dit fort (cf. le `Logger.warning` ci-dessous) et l'affichage tombe sur le generique.
  @spec display_roles() :: [String.t()]
  def display_roles do
    dir = Path.join(media_root(), "avatars")

    case File.ls(dir) do
      {:ok, files} ->
        for f <- files, String.ends_with?(f, ".svg"), do: Path.rootname(f)

      {:error, reason} ->
        # `[]` reste la reponse — chaque pod tombe sur l'icone generique, degradation d'AFFICHAGE
        # legitime puisque le role ne passe plus par ici — mais elle n'est pas MUETTE. Meme regle que
        # `roles_for_display/1` (F-C125, « un catalogue illisible n'est PAS `[]` »), a la severite
        # pres : une icone n'est pas une donnee.
        Logger.warning(
          "Deck: role icons unreadable (#{dir} : #{inspect(reason)}) — every pod falls back to the " <>
            "generic icon. Roles themselves are UNAFFECTED (served from the runtime, not from assets)."
        )

        []
    end
  end

  # Roles to display = cap-profiles catalogue (`Fleet.CapProfile.list/0`, single source of the domain)
  # filtered to roles that run as a fleet POD (so they can have a state). Sorted for a stable order.
  # F-C125 — an UNREADABLE catalogue is NOT `[]`: `CapProfile.list/0` is DELIBERATELY fail-loud (unreadable/
  # corrupt ≠ empty), so we PROPAGATE the error (the `/table` route surfaces it) instead of a silent-empty
  # table that would lie "no roles" during a broken cap-profile deploy.
  defp dashboard_roles, do: roles_for_display(Fleet.CapProfile.list())

  @doc false
  # Testable split of the catalogue result: `{:ok, names}` → display-filtered roles ; `{:error, reason}` →
  # propagated (the /table route renders `View.error_page/1`, not a silent-empty table).
  @spec roles_for_display({:ok, [String.t()]} | {:error, term()}) ::
          {:ok, [String.t()]} | {:error, term()}
  def roles_for_display({:ok, names}) do
    {:ok,
     names
     |> Enum.reject(&memory_x_role?/1)
     |> Enum.filter(&pod_role?/1)
     |> Enum.sort()}
  end

  def roles_for_display({:error, _reason} = err), do: err

  # Temporary HARD-CODED guard (user-validated): the Memory-X profiles are not agent roles to display.
  # The two halves are NOT in the same state, and the guard must not read as "the catalogue yields
  # monks today": `archivist*` is reachable by construction (`Catalog.name_index/1` globs
  # `<dir>/archivistes/*.yaml`), while nothing scans the frozen monks, so that half is a cheap hole
  # closed in advance of a thaw. Clean in the long run = a semantic field (non-null
  # `monk_registry`/`monk_instance`), not a name prefix.
  defp memory_x_role?(name),
    do: String.starts_with?(name, "monk") or String.starts_with?(name, "archivist")

  # Role that runs as a fleet POD (so it can carry a pod state): `host_native != true`.
  #
  # ⚠ THIS FILTER BITES TODAY, it is not waiting for a future role. A canon profile IS host-native:
  # `admiral`, the machine seat (`containment: none`, `host_native: true`). Reading it as a guard
  # held in reserve would suggest it never removes anything — when it removes exactly the seat,
  # which does not run as a pod and therefore has no pod state to show. Unreadable profile → excluded.
  defp pod_role?(name) do
    case Fleet.CapProfile.load(name) do
      {:ok, %Fleet.CapProfile{spec: spec}} -> get_in(spec, ["invocation", "host_native"]) != true
      _ -> false
    end
  end

  # The JSON send (content-type + encode + send) typed ONCE — inline sends would diverge
  # (content-type forgotten on the 404).
  defp json(conn, status, payload) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(payload))
  end
end
