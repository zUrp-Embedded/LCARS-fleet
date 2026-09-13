defmodule Fleet.Spawner.PermanentBoot do
  @moduledoc """
  Selects and starts fleet-level permanent pods declared by the catalogue.

  Called at startup by `Fleet.Admiral.BootOrchestrator` and on recovery by
  `PermanentWarden`. Host-native profiles are excluded because they use a separate
  launch path. Session recovery is delegated to `Fleet.Spawner.Pod`.
  """

  require Logger

  alias Fleet.CapProfile

  # The ID carries the role so pod.failed events can be mapped back to a respawn.
  @permanent_prefix "permanent-"

  @doc """
  Parses `permanent-<role>` into `{:ok, role}`; returns `:not_permanent` otherwise.
  """
  @spec parse_permanent(String.t()) :: {:ok, String.t()} | :not_permanent
  def parse_permanent(@permanent_prefix <> role) when role != "", do: {:ok, role}
  def parse_permanent(_), do: :not_permanent

  @doc """
  Builds the stable `permanent-<role>` ID used to address and respawn a permanent.
  """
  @spec pod_id_for(String.t()) :: String.t()
  def pod_id_for(role) when is_binary(role) and role != "", do: @permanent_prefix <> role

  @doc """
  Accepts a profile or string-keyed spec when `boot_at_start` is true,
  `lifetime_scope` is `"forever"`, and `host_native` is not true.
  """
  @spec boot_at_start?(CapProfile.t() | map()) :: boolean()
  def boot_at_start?(%CapProfile{spec: spec}), do: boot_at_start?(spec)

  def boot_at_start?(%{} = spec) do
    inv = Map.get(spec, "invocation", %{})

    Map.get(inv, "boot_at_start") == true and
      Map.get(inv, "lifetime_scope") == "forever" and
      Map.get(inv, "host_native") != true
  end

  def boot_at_start?(_), do: false

  @doc "Filters profiles through `boot_at_start?/1`."
  @spec select_permanent([CapProfile.t()]) :: [CapProfile.t()]
  def select_permanent(cap_profiles) when is_list(cap_profiles) do
    Enum.filter(cap_profiles, &boot_at_start?/1)
  end

  @doc """
  Loads the catalogue, selects eligible profiles and attempts each selected spawn.

  A load failure returns `{:error, {:cap_profile_load_failed, role, reason}}`
  before any spawn. Otherwise returns results as `{:ok, pod_id}` or
  `{:error, {role, reason}}`; one spawn failure does not stop the others.
  Options inject `:cap_profiles_dir`, `:loader` and `:spawner`. A published
  catalogue takes precedence over the directory option.
  """
  @spec boot_permanent_pods(keyword()) ::
          [{:ok, String.t()} | {:error, {String.t(), term()}}] | {:error, term()}
  def boot_permanent_pods(opts \\ []) when is_list(opts) do
    dir = Keyword.get(opts, :cap_profiles_dir) || cap_profiles_dir()
    loader = Keyword.get(opts, :loader, &CapProfile.resolve(CapProfile, &1))
    spawner = Keyword.get(opts, :spawner, &Fleet.Spawner.spawn_pod/3)

    with {:ok, roles} <- list_roles(dir),
         {:ok, cps} <- load_all(roles, loader) do
      cps
      |> select_permanent()
      |> Enum.map(&spawn_one(&1, spawner))
    else
      {:error, {:cap_profile_load_failed, _role, _reason}} = err ->
        err

      {:error, reason} ->
        {:error, {:cap_profiles_dir_unreadable, reason}}
    end
  end

  defp permanent_if_boot_at_start(role, loader) do
    case loader.(role) do
      {:ok, %CapProfile{} = cp} ->
        if boot_at_start?(cp.spec), do: [role], else: []

      {:error, reason} ->
        Logger.warning(
          "PermanentBoot: role #{role} EXCLUDED from permanent reconciliation — its " <>
            "cap-profile no longer loads (#{inspect(reason)}); it will NOT be respawned " <>
            "until the artefact is repaired"
        )

        []
    end
  end

  @doc """
  Returns eligible permanent roles for reconciliation.

  Unloadable profiles are excluded with a warning; enumeration failure returns
  an empty list. Accepts `:cap_profiles_dir` and `:loader` as in `boot_permanent_pods/1`.
  """
  @spec expected_permanent_roles(keyword()) :: [String.t()]
  def expected_permanent_roles(opts \\ []) when is_list(opts) do
    dir = Keyword.get(opts, :cap_profiles_dir) || cap_profiles_dir()
    loader = Keyword.get(opts, :loader, &CapProfile.resolve(CapProfile, &1))

    case list_roles(dir) do
      {:ok, roles} ->
        Enum.flat_map(roles, &permanent_if_boot_at_start(&1, loader))

      {:error, _} ->
        []
    end
  end

  @doc """
  Respawns one eligible permanent through the normal boot path. Already-running pods are
  idempotent successes; non-permanent and unloadable roles return named errors.
  """
  @spec respawn(String.t(), keyword()) :: {:ok, String.t()} | {:error, {String.t(), term()}}
  def respawn(role, opts \\ []) when is_binary(role) and is_list(opts) do
    loader = Keyword.get(opts, :loader, &CapProfile.resolve(CapProfile, &1))
    spawner = Keyword.get(opts, :spawner, &Fleet.Spawner.spawn_pod/3)

    case loader.(role) do
      {:ok, %CapProfile{} = cp} ->
        if boot_at_start?(cp.spec),
          do: spawn_one(cp, spawner),
          else: {:error, {role, :not_a_permanent}}

      {:error, reason} ->
        {:error, {role, {:cap_profile_load_failed, reason}}}
    end
  end

  @doc "Returns `:lcars_fleet, :spawner_boot_permanent_at_start`, defaulting to `true`."
  @spec auto_boot_enabled?() :: boolean()
  def auto_boot_enabled? do
    Application.get_env(:lcars_fleet, :spawner_boot_permanent_at_start, true) == true
  end

  defp cap_profiles_dir do
    Application.get_env(:lcars_fleet, :spawner_cap_profiles_dir) || CapProfile.root_dir()
  end

  defp list_roles(dir) do
    case CapProfile.list_from_published() do
      {:ok, roles} -> {:ok, roles}
      {:error, :not_published} -> CapProfile.list(dir)
    end
  end

  defp load_all(roles, loader) do
    case Enum.reduce_while(roles, {:ok, []}, &load_one(&1, &2, loader)) do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      {:error, _} = err -> err
    end
  end

  defp load_one(role, {:ok, acc}, loader) do
    case loader.(role) do
      {:ok, %CapProfile{} = cp} ->
        {:cont, {:ok, [cp | acc]}}

      {:error, reason} ->
        Logger.error(
          "PermanentBoot: cap-profile #{role} not loadable (#{inspect(reason)}) — boot fail-loud"
        )

        {:halt, {:error, {:cap_profile_load_failed, role, reason}}}
    end
  end

  defp spawn_one(%CapProfile{} = cp, spawner) do
    name = CapProfile.name(cp)

    pod_id = pod_id_for(name)

    # Stable IDs make repeated starts idempotent; rc_name is the separate Desktop label.
    case spawner.(cp, pod_id, pod_id: pod_id, rc_name: Fleet.Layout.pod_label(nil, name, nil)) do
      {:ok, _pid} ->
        {:ok, pod_id}

      {:error, {:already_started, _pid}} ->
        Logger.info(
          "PermanentBoot: permanent #{name} already alive (#{pod_id}) — idempotent no-op"
        )

        {:ok, pod_id}

      {:error, reason} ->
        Logger.error("PermanentBoot: spawn of permanent #{name} failed (#{inspect(reason)})")
        {:error, {name, reason}}
    end
  end
end
