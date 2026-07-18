defmodule Fleet.Observation.Deck do
  @moduledoc """
  Plug.Router of the observation deck on the observation port (per-human).

  ## Routes

    * `GET /` — LCARS shell: BRIDGE header (health LED + clock) + the 7 decks
      (PODS live, the others fed by the read-model projection).
    * `GET /health` — deck liveness probe.
    * `GET /api/pods` — JSON of live pods (`Fleet.Spawner.list_pods/0`,
      projected into a JSON-safe view). Read-only, no-auth, intra-release.
    * `GET /api/projection` — JSON of the read-model projection
      (`Fleet.Observation.ReadModel`: pods + the `%Fleet.Event{}` stream).
    * `GET /table` — role-by-role table (one row per role, "absent" if no
      live pod carries it).
    * `GET /static/*` — assets (`priv/observation/static/lcars-tva.css`, `assets/*.svg`).

  ## Read frontier

  `/api/pods` reads `Fleet.Spawner.list_pods/0` (direct spawner read, live snapshot).
  `/api/projection` reads `Fleet.Observation.ReadModel` (projection of the
  `%Fleet.Event{}` stream); the deck reads **the projection**, never
  the internal GenServer state of a third party.

  ## View frontier

  The TEMPLATE (inline HTML/CSS/JS) lives in `Fleet.Observation.Deck.View`
  (pure rendering): this module remains the CONTROLLER
  (routing + role-catalogue derivation + live snapshots) and passes the
  data to the view as an argument. The view reads no source itself.

  **Last revised**: 2026-07-18
  """

  use Plug.Router

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

  # Basic table: one fixed block per role (`dashboard_roles/0`), state of the
  # matching pod(s) rendered SERVER-SIDE (no JS). Reuses the same live snapshot
  # as `/api/pods` (`Fleet.Spawner.list_pods/0`); rendering is delegated to the pure view
  # (`View.table_page/2`), the controller only collects roles + grouped pods.
  get "/table" do
    case dashboard_roles() do
      {:ok, roles} ->
        by_role = Enum.group_by(Fleet.Spawner.list_pods(), &Map.get(&1, :role))

        conn
        |> put_resp_content_type("text/html")
        |> send_resp(200, View.table_page(roles, by_role))

      {:error, reason} ->
        # F-C125 — surface the swallowed catalogue-error instead of a silent-empty table lying "no roles".
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

  # Event-derived projection (read-model): feeds FLOW/GATEKEEPER/
  # STREAM/COORDINATION/DIAGNOSTICS/BRIDGE. Direct ETS read (bypass GenServer).
  get "/api/projection" do
    # F-C124 — include the read-model HEALTH so a DOWN read-model (whose projection reads empty) is not
    # indistinguishable from a quiet-healthy fleet. `_status` = :live | :deaf | :unavailable (additive field).
    proj = Fleet.Observation.ReadModel.projection()
    body = Jason.encode!(Map.put(proj, :_status, Fleet.Observation.ReadModel.projection_status()))

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, body)
  end

  match _ do
    json(conn, 404, %{error: "deck route not found"})
  end

  # JSON-safe view of a pod: subset of `:info`. The runtime may put
  # non-encodable terms (`last_error`/`last_result`) → excluded. `phase`
  # (atom) + lists/strings/nil encode fine. `role` added for the icon.
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

  # The role lives ONLY under `:role` (engraved at spawn = cap-profile name, the single source). Outside
  # the DISPLAY catalogue → nil: the client renders the generic icon. This is NOT a masking of the pod
  # (the pod stays listed) nor a runtime role authority — just the icon choice.
  defp role_of(info, known) do
    role = Map.get(info, :role)
    if is_binary(role) and role in known, do: role, else: nil
  end

  # DISPLAY catalogue (role → dedicated SVG icon) DERIVED from the assets actually present in
  # `priv/observation/static/assets`: any `<role>.svg` dropped there is recognized automatically — never a
  # hard-coded list to keep in sync with the files (the asset is the authority).
  # Exclusions: the `favicon*.svg` (chrome, not a role) and `starfleet` (out-of-band system domain,
  # the asset exists but no panel instruments it). `File.ls` KO (dir absent) → `[]`: safe degradation
  # (all pods on the generic icon, never a crash). Resolved via `app_dir` = same priv as `Plug.Static`.
  defp display_roles do
    case File.ls(Application.app_dir(:lcars_fleet, "priv/observation/static/assets")) do
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

  # Temporary HARD-CODED guard (user-validated): `CapProfile.list/0` also picks up the Memory-X profiles
  # from the `monks/` / `archivistes/` subfolders — these are not agent roles to display. Absent
  # from THIS repo today (so inert here) but `list/0` really scans these subfolders, so this
  # is not a guard over emptiness: it bites as soon as one of these profiles exists. Clean in the long run = a
  # semantic field (non-null `monk_registry`/`monk_instance`), not a name prefix.
  defp memory_x_role?(name),
    do: String.starts_with?(name, "monk") or String.starts_with?(name, "archivist")

  # Role that runs as a fleet POD (so it can carry a pod state): `host_native != true`.
  # Same semantic discriminator as `Fleet.Spawner.PermanentBoot.boot_at_start?/1` — excludes `starfleet`
  # (host-native, containment: none, "has NO pod") without hard-coding its name. Unreadable profile → excluded.
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
