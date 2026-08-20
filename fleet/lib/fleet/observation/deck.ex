defmodule Fleet.Observation.Deck do
  @moduledoc """
  Read-only observation router. It exposes health, live JSON-safe pod snapshots,
  event projections, role tables, and static assets. Routing and catalogue
  selection stay here; pure HTML rendering lives in `Deck.View`.
  """

  use Plug.Router

  require Logger

  alias Fleet.Observation.Deck.View

  # `priv/` ne porte plus que la feuille de style : elle EST du runtime, versionnee avec le code qui
  # la genere. Les medias de marque, eux, ont quitte cet arbre — cf. `media_root/0` plus bas.
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
  # que la config pose au boot. Une racine de medias figee dans le BEAM serait exactement le contraire
  # de ce que ce chantier retire.
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

  # `socket`, not `port` (6-072/6-098): this deck has no address. Reporting a port here would have
  # been the most convincing lie of the lot — a health endpoint answering `200` while naming a number
  # nothing binds. Whoever probes health is looking for where to reach this thing; the answer is a
  # path, and the caller reaching it over that very socket is what makes the field honest.
  get "/health" do
    conn
    |> json(200, %{
      status: "ok",
      deck: "fleet_observation",
      socket: Fleet.Observation.Application.deck_socket()
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

  get "/api/projection" do
    # F-C124
    proj = Fleet.Observation.ReadModel.projection()
    body = Jason.encode!(Map.put(proj, :_status, Fleet.Observation.ReadModel.projection_status()))

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, body)
  end

  # THE READ-DIAGNOSTIC PLANE LIVES ON THE READ SOCKET. `fleet_api` used to serve these two over a
  # TCP listener that is gone (socket-only fleet); the aggregator modules stay in `Fleet.API` (they
  # already hold the cross-domain deps), and the read plane — `Fleet.Observation`, already an
  # AF_UNIX plug the operator's `state_of_the_fleet` skill curls at `$OBS/api/pods` — reads them.
  # Deleting the endpoints without re-homing them left that skill blind on `readiness/deep`
  # ("red -> do not undertake work"), which is why they are back here and not gone.
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
  def pod_view(info, known) do
    %{
      pod_id: info.pod_id,
      # 6-057 — LE ROLE EST LA VERITE, L'ICONE EST UNE QUESTION D'AFFICHAGE, et les deux etaient
      # confondues : `role` ne sortait que si un `.svg` du meme nom existait. Un pod `chief` (le seul
      # role du catalogue sans asset, mesure) etait donc servi `role: null` — indiscernable de « ce
      # pod n'a pas de role », et c'est exactement ce que le commentaire de `project_slug` douze
      # lignes plus bas interdit. Le repli generique existait DEJA cote vue
      # (`favicon-minimal.svg`) : masquer le role etait le MOYEN d'y arriver, pas l'intention.
      role: role_of(info),
      # Ce que la vue doit savoir, dit separement : quel asset utiliser, `nil` = le generique.
      role_icon: role_icon(Map.get(info, :role), known),
      issue_id: Map.get(info, :issue_id),
      # THE LAST LINK OF THE CHAIN, and publishing it in `pod_info` was not enough: this view is
      # what `/api/pods` serves, and it whitelists its keys. The landing deck reads THIS endpoint —
      # so as long as the key stopped here, the slug existed everywhere except where its only
      # consumer could see it, and that consumer went on scanning `/proc` for a mount that was
      # deliberately removed.
      #
      # `nil` is a real answer, not a gap: a fleet-level pod belongs to no project. It reads as
      # "no project" ONLY because the runtime now states it — the same nil inferred from an absent
      # mount meant "I could not tell", and the two were indistinguishable to the page.
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

  # LA RACINE DES MEDIAS INSTALLES — une source, posee par l'installation, lue par tout le monde.
  #
  # ⚠ IL Y EN AVAIT TROIS EXEMPLAIRES, ET ILS AVAIENT DERIVE. Les memes avatars vivaient sous
  # `assets/avatars/` (la marque), `fleet/deploy/deps/avatars/` (les png de la charte forge) et
  # `priv/observation/static/assets/` (les svg de ce deck). Mesure du 2026-08-20 : SEPT des neuf
  # roles communs differaient entre la marque et ce deck — pas par decision, mais parce qu'une mise a
  # jour touchait un dossier et pas les autres. Le deck affichait donc une generation d'avatars
  # pendant que la forge en posait une autre.
  #
  # `assets/` est la source ; l'installation la pose en `/usr/share/lcars/{avatars,favicon}`, a cote
  # de la doc, et le rail de deploiement (`provision-forge-charte.sh`) lit le meme endroit.
  defp media_root, do: Application.get_env(:lcars_fleet, :media_root, "/usr/share/lcars")

  # ⚠ AUCUN REPLI SUR `priv/`, ET C'EST UNE DECISION. Une installation qui n'a pas pose ses medias
  # est RATEE, pas degradee : un repli servirait l'ancienne generation d'avatars — c'est-a-dire
  # exactement la panne qu'on vient de retirer — et rendrait vert un deploiement a moitie fait. Ici
  # l'absence reste bruyante et l'affichage tombe sur l'icone generique, ce qui SE VOIT.
  @doc false
  # Public comme `roles_for_display/1` et pour la meme raison : c'est le point ou la source des
  # icones se mesure, et un temoin doit pouvoir constater qu'elle est bien la marque installee.
  def display_roles do
    dir = Path.join(media_root(), "avatars")

    case File.ls(dir) do
      {:ok, files} ->
        # Le filtre `favicon` qui vivait ici est parti AVEC le fait qu'il decrivait : les deux
        # favicons partageaient ce dossier, ils ont maintenant le leur. Une condition qui protege
        # d'un cas devenu impossible enseigne un modele faux au prochain lecteur.
        for f <- files, String.ends_with?(f, ".svg"), do: Path.rootname(f)

      {:error, reason} ->
        # `[]` reste la reponse — chaque pod tombera sur l'icone generique, ce qui est une
        # degradation d'AFFICHAGE legitime depuis que le role ne passe plus par ici. Mais elle cesse
        # d'etre muette : c'est la meme regle que `roles_for_display/1` plus bas (F-C125, « un
        # catalogue illisible n'est PAS `[]` »), a la severite pres — une icone n'est pas une donnee.
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
  def roles_for_display({:ok, names}) do
    {:ok,
     names
     |> Enum.reject(&memory_x_role?/1)
     |> Enum.filter(&pod_role?/1)
     |> Enum.sort()}
  end

  def roles_for_display({:error, _reason} = err), do: err

  # Temporary HARD-CODED guard (user-validated): the Memory-X profiles are not agent roles to display.
  # What the catalogue actually scans (`Catalog.name_index/1`) is `<dir>/*.yaml` + `<dir>/archivistes/*.yaml`
  # — so the two halves of this guard are NOT in the same state:
  #   * `archivist*` — reachable by construction: the `archivistes/` glob exists. The directory does not
  #     exist on disk today, so the branch is inert for now, but it bites the day a profile lands there.
  #   * `monk*` — NOT reachable from the catalogue: there is no `monks/` scan, deliberately (the monks are
  #     frozen under `canon/_frozen-monks/`, out of the boot loop — `Catalog` says so at its glob). This
  #     half is kept for the thaw that re-adds the scan; until then nothing can produce such a name here.
  # Keeping it is cheap and closes the hole at thaw time; what it must NOT do is read as "the catalogue
  # yields monks today". Clean in the long run = a semantic field (non-null `monk_registry`/`monk_instance`),
  # not a name prefix.
  defp memory_x_role?(name),
    do: String.starts_with?(name, "monk") or String.starts_with?(name, "archivist")

  # Role that runs as a fleet POD (so it can carry a pod state): `host_native != true`.
  # Since the 2026-07-19 reorg NO canon role is host-native (starfleet became an ordinary bwrap pod
  # and is instrumented like the rest) — the guard stays for a future off-fleet role. Unreadable
  # profile → excluded.
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
