defmodule Fleet.Spawner.LaunchBackend.PortBackend do
  @moduledoc """
  Backend RÉEL (B5 #576) — lance la chaîne `bin/bwrap_launch.sh`
  → `bin/claude_launch.sh` via `Port.open/2` `:spawn_executable`,
  **non-privilégié** (aucun sudo : `bwrap_launch.sh` fait lui-même
  l'isolation userns/mountns). Parse le stdout NDJSON via
  `Fleet.PodRuntime.StreamParser` (réutilisé, pas réinventé),
  capture la frame `init` (discriminant = `StreamParser.validate_init/1`
  `:ok`), écrit le flux brut dans `<pod_dir>/pod-stream.ndjson`.

  Contrats canon vérifiés (anti-M1, pas inférés) :
    * `bwrap_launch.sh <role> <pod_id> <pod_dir> <command...>`
    * `claude_launch.sh <role> <pod_id> <pod_dir> <budget_sec> <budget_usd>`
      → `<command...>` = le vecteur claude_launch complet.

  Parser NDJSON **inliné** (anti-M1 : `Fleet.PodRuntime.StreamParser`
  est dans `fleet_pod_runtime` qui dépend DÉJÀ de `fleet_spawner` →
  réutiliser créerait un cycle Mix. Inliner ~20L résout le cycle, ce
  n'est pas de la duplication gratuite). Discriminant `init` =
  contrat F-INIT-VALIDATE identique (9 clés requises + `api_key_source
  == "oauth"`, clés string Jason).

  Retour : `{:ok, %{port:, init_message:, ndjson_log:}}` |
  `{:error, reason}`. Bloque (borné `:init_timeout_ms`, défaut 30s)
  jusqu'à capture de l'`init` (boot validation downstream via
  `InitValidator`). Tests : `build_spawn/1` pur + smoke fake-exe.
  """

  @behaviour Fleet.Spawner.LaunchBackend

  require Logger

  @default_init_timeout_ms 30_000

  # F-INIT-VALIDATE — clés requises de la frame `init` (string, Jason).
  @required_init_keys ~w(tools model permission_mode api_key_source cwd
                         claude_code_version mcp_servers slash_commands agents)

  @impl Fleet.Spawner.LaunchBackend
  def launch(args, env) when is_map(args) and is_map(env) do
    with {:ok, exe, argv} <- build_spawn(args),
         :ok <- ensure_executable(exe),
         {:ok, {log_path, log_io}} <- open_log(args) do
      env_list = Enum.map(env, fn {k, v} -> {to_charlist(k), to_charlist(v)} end)

      port =
        Port.open({:spawn_executable, exe}, [
          :binary,
          :exit_status,
          {:args, argv},
          {:env, env_list},
          {:cd, to_charlist(args.pod_dir)}
        ])

      timeout = Map.get(args, :init_timeout_ms, @default_init_timeout_ms)
      deadline = System.monotonic_time(:millisecond) + timeout
      do_capture(port, "", log_path, log_io, deadline)
    end
  end

  @doc """
  Pur : construit `{:ok, executable, argv}` pour `Port.open`. Risque
  clé anti-M1 (ordre/contenu du vecteur) → testé isolément.

  `bwrap_launch <role> <pod_id> <pod_dir>` puis `<command...>` =
  `claude_launch <role> <pod_id> <pod_dir> <budget_sec> <budget_usd>`.
  """
  @spec build_spawn(map()) :: {:ok, String.t(), [String.t()]} | {:error, term()}
  def build_spawn(
        %{
          role: role,
          pod_id: pod_id,
          pod_dir: pod_dir,
          bwrap_launch_path: bwrap,
          claude_launch_path: claude
        } = args
      )
      when is_binary(role) and is_binary(pod_id) and is_binary(pod_dir) and
             is_binary(bwrap) and is_binary(claude) do
    budget_sec = to_string(Map.get(args, :budget_sec, 600))
    budget_usd = to_string(Map.get(args, :budget_usd, "1.0"))

    argv = [role, pod_id, pod_dir, claude, role, pod_id, pod_dir, budget_sec, budget_usd]
    {:ok, bwrap, argv}
  end

  def build_spawn(_), do: {:error, :invalid_args}

  # ---------------------------------------------------------------

  defp ensure_executable(path) do
    cond do
      not File.exists?(path) -> {:error, {:executable_missing, path}}
      not executable?(path) -> {:error, {:not_executable, path}}
      true -> :ok
    end
  end

  defp executable?(path) do
    case File.stat(path) do
      {:ok, %File.Stat{mode: mode}} -> Bitwise.band(mode, 0o111) != 0
      _ -> false
    end
  end

  defp open_log(%{pod_dir: pod_dir}) do
    path = Path.join(pod_dir, "pod-stream.ndjson")

    case File.open(path, [:write, :binary]) do
      {:ok, io} -> {:ok, {path, io}}
      {:error, reason} -> {:error, {:ndjson_log_open, reason}}
    end
  end

  # Bloque borné : accumule stdout, capture la 1ʳᵉ frame init valide.
  defp do_capture(port, parser, log_path, log_io, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      File.close(log_io)
      safe_close(port)
      {:error, :init_timeout}
    else
      receive do
        {^port, {:data, chunk}} ->
          IO.binwrite(log_io, chunk)
          {lines, residual} = split_lines(parser <> chunk)

          case Enum.find_value(lines, &init_frame/1) do
            nil ->
              do_capture(port, residual, log_path, log_io, deadline)

            init ->
              File.close(log_io)
              {:ok, %{port: port, init_message: init, ndjson_log: log_path}}
          end

        {^port, {:exit_status, status}} ->
          File.close(log_io)
          {:error, {:exited_before_init, status}}
      after
        remaining ->
          File.close(log_io)
          safe_close(port)
          {:error, :init_timeout}
      end
    end
  end

  # Découpe NDJSON : lignes complètes + résidu (ligne coupée).
  defp split_lines(bin) do
    parts = String.split(bin, "\n")
    {complete, [residual]} = Enum.split(parts, length(parts) - 1)
    {complete, residual}
  end

  # init_frame/1 → la map décodée si c'est une frame `init` valide
  # (F-INIT-VALIDATE : 9 clés + api_key_source ∈ {"oauth","none"}), sinon nil.
  # Truthy/nil → compatible Enum.find_value/2.
  # #591 — claude 2.1.114 émet `apiKeySource`/`permissionMode` (camelCase)
  # + `apiKeySource: "none"` en mode OAuth env-vars. Résilience via alias
  # camel↔snake (symétrique à Pod.InitValidator).
  @key_aliases %{
    "api_key_source" => "apiKeySource",
    "permission_mode" => "permissionMode"
  }
  @valid_api_key_sources ["oauth", "none"]

  defp init_frame(line) do
    with trimmed when trimmed != "" <- String.trim(line),
         {:ok, %{} = ev} <- Jason.decode(trimmed),
         true <- Enum.all?(@required_init_keys, &has_field?(ev, &1)),
         src when src in @valid_api_key_sources <- get_field(ev, "api_key_source") do
      ev
    else
      _ -> nil
    end
  end

  defp has_field?(msg, key) do
    Map.has_key?(msg, key) or
      (Map.has_key?(@key_aliases, key) and Map.has_key?(msg, Map.fetch!(@key_aliases, key)))
  end

  defp get_field(msg, key) do
    case Map.get(msg, key) do
      nil -> Map.get(msg, Map.get(@key_aliases, key))
      v -> v
    end
  end

  defp safe_close(port) do
    if is_port(port) and Port.info(port) != nil, do: Port.close(port)
  rescue
    _ -> :ok
  end
end
