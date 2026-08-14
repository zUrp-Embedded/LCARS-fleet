defmodule Fleet.Observation.Deck do
  @moduledoc """
  Read-only observation router. It exposes health, live JSON-safe pod snapshots,
  event projections, role tables, and static assets. Routing and catalogue
  selection stay here; pure HTML rendering lives in `Deck.View`.
  """

  use Plug.Router

  require Logger

  alias Fleet.Observation.Deck.View

  plug(Plug.Static,
    at: "/static",
    from: {:lcars_fleet, "priv/observation/static"},
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

  get "/health" do
    conn
    |> json(200, %{
      status: "ok",
      deck: "fleet_observation",
      port: Application.get_env(:lcars_fleet, :observation_http_port)
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

  # Role icons are derived from assets; missing assets degrade to the generic icon.
  defp display_roles do
    dir = Application.app_dir(:lcars_fleet, "priv/observation/static/assets")

    case File.ls(dir) do
      {:ok, files} ->
        for f <- files,
            String.ends_with?(f, ".svg"),
            role = Path.rootname(f),
            not String.starts_with?(role, "favicon"),
            do: role

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
