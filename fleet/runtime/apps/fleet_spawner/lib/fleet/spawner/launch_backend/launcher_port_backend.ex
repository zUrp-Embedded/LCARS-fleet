defmodule Fleet.Spawner.LaunchBackend.LauncherPortBackend do
  @moduledoc """
  Backend RÉEL — lance la chaîne `<launcher N0> → bin/claude_launch.sh` via
  `Port.open/2` `:spawn_executable`, **non-privilégié**. Le launcher N0 est choisi
  par le spawner selon `containment` (LAUNCH-Q) : `bin/bwrap_launch.sh` (défaut, bwrap
  fait l'isolation userns/mountns) ou `bin/host_launch.sh` (containment: none, host
  sans sandbox). L'`exe` du Port = `args.launcher_path` ; l'argv est identique des
  deux côtés (même contrat `<role> <pod_id> <pod_dir> <command...>`).

  ## R1.2 — modèle INTERACTIF (post -p/stream-json)

  `claude_launch` lance désormais `claude` INTERACTIF sous PTY (R1.1) ; le livrable
  est un FICHIER (`$POD_DIR/output/result.md`, lu par `Pod` EXTRACT), PAS un flux
  NDJSON stdout. Donc `launch/2` **n'attend plus** de frame `init` : il ouvre le
  Port et **retourne immédiatement**. Le **Pod owns le Port** — `launch/2` tourne
  dans le process Pod (`do_launch`), donc les messages `{port, {:data, _}}` /
  `{port, {:exit_status, _}}` arrivent à `Pod.handle_info`. Détection d'exit,
  monitoring du livrable et kill = lifecycle Pod, pas ici.

  Retour : `{:ok, %{port: port, init_message: nil, ndjson_log: nil}}` | `{:error, reason}`.
  Tests : `build_spawn/1` pur (vecteur args, anti-M1) + smoke fake-exe (Port ouvert / exe absent).
  """

  @behaviour Fleet.Spawner.LaunchBackend

  @impl Fleet.Spawner.LaunchBackend
  def launch(args, env) when is_map(args) and is_map(env) do
    with {:ok, exe, argv} <- build_spawn(args),
         :ok <- ensure_executable(exe) do
      env_list = Enum.map(env, fn {k, v} -> {to_charlist(k), to_charlist(v)} end)

      port =
        Port.open({:spawn_executable, exe}, [
          :binary,
          :exit_status,
          {:args, argv},
          {:env, env_list},
          {:cd, to_charlist(args.pod_dir)}
        ])

      {:ok,
       %{
         port: port,
         init_message: nil,
         ndjson_log: nil,
         # tmux_session présent ⇒ pod KICKABLE (PodTmux send-keys sur le sock par-pod). Le sock est
         # dérivé du pod_id (convention bwrap_launch.sh), pas besoin de le porter dans l'état.
         tmux_session: Fleet.Spawner.PodTmux.session_name(args.pod_id)
       }}
    end
  end

  @doc """
  Pur : construit `{:ok, executable, argv}` pour `Port.open`. Risque anti-M1
  (ordre/contenu du vecteur) → testé isolément.

  `<launcher_path> <role> <pod_id> <pod_dir>` puis `<command...>` =
  `claude_launch <role> <pod_id> <pod_dir> <sp>`. `launcher_path` = bwrap_launch (défaut)
  ou host_launch (containment: none) — **même argv** (LAUNCH-Q). Le **SP composé est
  l'argv4** de claude_launch (inline, PAS un fichier). R0.8-brick4 : budget retiré (pas
  d'API). Identité/session (`LCARS_POD_SESSION_ID`/`_RESUME`/`_SESSION_NAME_PREFIX`) voyagent
  par l'ENV du Port (`launch/2` `env`), que bwrap_launch `--setenv` dans le pod (host_launch
  l'hérite directement, sans namespace).
  """
  @spec build_spawn(map()) :: {:ok, String.t(), [String.t()]} | {:error, term()}
  def build_spawn(%{
        role: role,
        pod_id: pod_id,
        pod_dir: pod_dir,
        launcher_path: launcher,
        claude_launch_path: claude,
        sp: sp
      })
      when is_binary(role) and is_binary(pod_id) and is_binary(pod_dir) and
             is_binary(launcher) and is_binary(claude) and is_binary(sp) do
    argv = [role, pod_id, pod_dir, claude, role, pod_id, pod_dir, sp]
    {:ok, launcher, argv}
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
end
