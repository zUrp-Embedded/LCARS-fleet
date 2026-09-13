defmodule Fleet.Observation.Deck do
  @moduledoc """
  Read-only routes for pod snapshots, event projections, diagnostics, role tables
  and assets. Catalogue selection stays here; HTML rendering is in Deck.View.
  Field selection limits exposed data but does not validate every value for JSON.
  """

  use Plug.Router

  require Logger

  alias Fleet.Observation.Deck.View

  # Runtime CSS stays in priv; installed brand media use media_root.
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

  # Resolve the configured media root at request time. Allow only avatars/favicon
  # and listed extensions. The expanded-path prefix check is lexical: it does not
  # resolve symlinks or validate image content.
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
        conn
        |> put_resp_content_type("text/html")
        |> send_resp(200, View.error_page(reason))
    end
  end

  # Report the configured socket path; this handler does not check listener liveness.
  get "/health" do
    conn
    |> json(200, %{
      status: "ok",
      deck: "fleet_observation",
      socket: Fleet.Observation.Application.deck_socket()
    })
  end

  # Skip and log nonbinary/missing pod IDs here, without imposing a view requirement
  # on list_pods used elsewhere. Other missing fields (notably phase) can still raise.
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
    proj = Fleet.Observation.ReadModel.projection()
    body = Jason.encode!(Map.put(proj, :_status, Fleet.Observation.ReadModel.projection_status()))

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, body)
  end

  # Diagnostics share the observation socket; API owns their cross-domain aggregation.
  get "/api/readiness/deep" do
    json(conn, 200, Fleet.API.Readiness.deep())
  end

  get "/api/version" do
    json(conn, 200, Fleet.API.BuildInfo.current())
  end

  match _ do
    json(conn, 404, %{error: "deck route not found"})
  end

  # Select public fields for the JSON endpoint; values still depend on the pod-info contract.
  @doc false
  @spec pod_view(map(), term()) :: map()
  def pod_view(info, known) do
    %{
      pod_id: info.pod_id,
      # Preserve the role even when its icon is absent.
      role: role_of(info),
      role_icon: role_icon(Map.get(info, :role), known),
      issue_id: Map.get(info, :issue_id),
      # Forward project association to the landing; Map.get conflates missing and explicit nil.
      project_slug: Map.get(info, :project_slug),
      phase: info.phase,
      conditions: Map.get(info, :conditions, []),
      session_id: Map.get(info, :session_id),
      tmux_session: Map.get(info, :tmux_session)
    }
  end

  # Malformed or absent role becomes nil; icon availability does not determine the role.
  defp role_of(info) do
    role = Map.get(info, :role)
    if is_binary(role), do: role, else: nil
  end

  defp role_icon(role, known) when is_binary(role) do
    if role in known, do: role, else: nil
  end

  defp role_icon(_role, _known), do: nil

  # Installed media are shared with other consumers to avoid diverging brand copies.
  defp media_root, do: Application.get_env(:lcars_fleet, :media_root, "/opt/lcars/share")

  # No priv fallback: missing installed icons warn and use generic rendering.
  @doc false

  @spec display_roles() :: [String.t()]
  def display_roles do
    dir = Path.join(media_root(), "avatars")

    case File.ls(dir) do
      {:ok, files} ->
        for f <- files, String.ends_with?(f, ".svg"), do: Path.rootname(f)

      {:error, reason} ->
        Logger.warning(
          "Deck: role icons unreadable (#{dir} : #{inspect(reason)}) — every pod falls back to the " <>
            "generic icon. Roles themselves are UNAFFECTED (served from the runtime, not from assets)."
        )

        []
    end
  end

  # Catalogue enumeration errors reach /table as an error page; individual load
  # failures are excluded by pod_role? instead.
  defp dashboard_roles, do: roles_for_display(Fleet.CapProfile.list())

  @doc false

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

  # Temporary Memory-X name-prefix exclusion: archivist profiles are enumerated by
  # the catalogue; monk profiles are frozen. A semantic catalogue field should replace it.
  defp memory_x_role?(name),
    do: String.starts_with?(name, "monk") or String.starts_with?(name, "archivist")

  # Exclude profiles declaring host_native:true (including admiral), and failed loads.
  defp pod_role?(name) do
    case Fleet.CapProfile.load(name) do
      {:ok, %Fleet.CapProfile{spec: spec}} -> get_in(spec, ["invocation", "host_native"]) != true
      _ -> false
    end
  end

  defp json(conn, status, payload) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(payload))
  end
end
