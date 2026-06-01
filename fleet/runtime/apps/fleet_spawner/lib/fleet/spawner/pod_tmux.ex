defmodule Fleet.Spawner.PodTmux do
  @moduledoc """
  Ops de contrôle host→pod sur le **socket tmux PAR-POD** (`tmux -S <sock>`), conventions PARTAGÉES
  avec `bin/bwrap_launch.sh` : le pod tourne dans un serveur tmux DANS bwrap, joignable par sa socket
  bindée (sock-dir host↔pod). Keyé par `pod_id` (pas par l'état) — `sock_path`/`session_name` dérivés
  du pod_id + config sock-base.

  ## Ce canal porte le CONTROL-PLANE, pas le mandat

  Le mandat ne voyage PAS ici (il est pull par le pod via MCP `get_task`). Ce canal = le **KICK**
  (« yop » → déclenche get_task → traite → submit_result) + les slash-commands (`/clear`) + le health
  (`has-session`). Voir la chaîne reverse #5b : les channels MCP sont `skipSlashCommands:true` → seul
  le send-keys tmux atteint les slash-commands.

  ## Le KILL n'est PAS ici

  Tuer = `Port.close` du holder bwrap (pod.ex), PAS `kill-session` : le holder (`sleep infinity`) tient
  le namespace ; tuer juste la session tmux laisserait le holder vivant → namespace orphelin. La socket
  meurt avec le namespace quand le Port se ferme.
  """

  require Logger

  @tmux_bin "tmux"

  @doc """
  Base des sockets pod. Config `:fleet_spawner, :tmux_sock_base` (défaut `/run/lcars/tmux-sock`) — MÊME
  défaut que `bwrap_launch.sh` (`LCARS_TMUX_SOCK_BASE`). do_launch pose cet env pour que les deux côtés
  (Elixir host / bwrap pod) calculent le MÊME chemin.
  """
  @spec sock_base() :: String.t()
  def sock_base, do: Application.get_env(:fleet_spawner, :tmux_sock_base, "/run/lcars/tmux-sock")

  @doc "Chemin socket du pod — convention bwrap_launch.sh : `<base>/<pod_id>/lcars-pod-<pod_id>.sock`."
  @spec sock_path(String.t()) :: String.t()
  def sock_path(pod_id) when is_binary(pod_id),
    do: Path.join([sock_base(), pod_id, "lcars-pod-#{pod_id}.sock"])

  @doc "Nom de session tmux INTERNE du pod — convention bwrap_launch.sh (`lcars-pod-<pod_id>`)."
  @spec session_name(String.t()) :: String.t()
  def session_name(pod_id) when is_binary(pod_id), do: "lcars-pod-#{pod_id}"

  @doc "Session vivante ? (`tmux -S <sock> has-session`). Health + recovery."
  @spec alive?(String.t()) :: boolean()
  def alive?(pod_id) when is_binary(pod_id) do
    case tmux(pod_id, ["has-session", "-t", session_name(pod_id)]) do
      {_, 0} -> true
      _ -> false
    end
  end

  @doc """
  Envoie `keys` + `Enter` au REPL du pod (le KICK, ex. « yop »). send-keys est le control-plane
  universel (atteint aussi les slash-commands, contrairement aux channels MCP).
  """
  @spec send_keys(String.t(), String.t()) :: :ok | {:error, term()}
  def send_keys(pod_id, keys) when is_binary(pod_id) and is_binary(keys) do
    case tmux(pod_id, ["send-keys", "-t", session_name(pod_id), keys, "Enter"]) do
      {_, 0} ->
        :ok

      {out, code} ->
        Logger.warning("PodTmux send-keys pod=#{pod_id} échec (#{code}) : #{String.trim(out)}")
        {:error, {:tmux_send_failed, code, String.trim(out)}}
    end
  end

  @doc "Reset le contexte REPL claude (`/clear`). Régénère le sessionId local, le handle bridge survit."
  @spec send_clear(String.t()) :: :ok | {:error, term()}
  def send_clear(pod_id) when is_binary(pod_id), do: send_keys(pod_id, "/clear")

  defp tmux(pod_id, args) do
    System.cmd(@tmux_bin, ["-S", sock_path(pod_id) | args], stderr_to_stdout: true)
  end
end
