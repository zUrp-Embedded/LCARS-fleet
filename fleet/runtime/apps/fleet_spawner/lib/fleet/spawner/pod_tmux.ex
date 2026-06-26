defmodule Fleet.Spawner.PodTmux do
  @moduledoc """
  Ops de contrôle host→pod sur le **socket tmux PAR-POD** (`tmux -S <sock>`), conventions PARTAGÉES
  avec `bin/bwrap_launch.sh` : le pod tourne dans un serveur tmux DANS bwrap, joignable par sa socket
  bindée (sock-dir host↔pod). Keyé par `pod_id` (pas par l'état) — `sock_path`/`session_name` dérivés
  du pod_id + config sock-base.

  ## Ce canal porte le CONTROL-PLANE, pas le mandat

  Le mandat ne voyage PAS ici (il est pull par le pod via MCP `get_task`). Ce canal = le **KICK**
  (« yop » → déclenche get_task → traite → submit_result) + les slash-commands (`/clear`) + le health
  (`has-session`). Les channels MCP sont `skipSlashCommands:true` → seul
  le send-keys tmux atteint les slash-commands.

  ## Le KILL PRIMAIRE n'est PAS ici (mais le fallback orphelin, si)

  Tuer = `Port.close` du holder bwrap (pod.ex), PAS `kill-session` : le holder (`sleep infinity`) tient
  le namespace ; tuer juste la session tmux laisserait le holder vivant → namespace orphelin. La socket
  meurt avec le namespace quand le Port se ferme. **Exception RECOVERY** : quand il n'y a plus de Port
  (orphelin post-crash GenServer, reap), `kill_holder/1` ci-dessous fait le geste de secours
  (tmux kill-server + `pkill -f` ancré).
  """

  require Logger

  @tmux_bin "tmux"

  @doc """
  Base des sockets pod. Config `:fleet_spawner, :tmux_sock_base` (défaut `~/.lcars/run/tmux-sock`) — MÊME
  défaut que `bwrap_launch.sh` (`LCARS_TMUX_SOCK_BASE`). do_launch pose cet env pour que les deux côtés
  (Elixir host / bwrap pod) calculent le MÊME chemin.
  """
  @spec sock_base() :: String.t()
  def sock_base, do: Application.get_env(:fleet_spawner, :tmux_sock_base, default_sock_base())

  # Fleet tourne sous l'humain → défaut home-relatif `~/.lcars/run/tmux-sock` (un `/run/lcars/tmux-sock`
  # serait un RuntimeDirectory systemd owned `lcars`, non-writable hors d'un daemon-lcars).
  # HOME irrésoluble = runtime cassé → fail-loud (`System.user_home!()` raise), jamais un chemin
  # fabriqué : l'état .lcars ne doit pas se disperser en silence.
  defp default_sock_base,
    do: Path.join(System.user_home!(), ".lcars/run/tmux-sock")

  @doc """
  Chemin socket du pod — convention bwrap_launch.sh : `<base>/<pod_id>/pod.sock`.

  Filename CONSTANT (`pod.sock`), pas `lcars-pod-<pod_id>.sock` : le dir `<pod_id>/`
  donne déjà l'unicité + l'isolation (bind-mount). Le double pod_id (dir + filename)
  ferait dépasser la limite dure `sun_path` (108 octets) des sockets Unix dès que
  `pod_id` est un UUID (chemin pipeline) → `error: File name too long` (un id court en
  spawn direct passerait ; un pod_id UUID de pipeline, non).
  """
  @spec sock_path(String.t()) :: String.t()
  def sock_path(pod_id) when is_binary(pod_id),
    do: Path.join([sock_base(), pod_id, "pod.sock"])

  @doc "Nom de session tmux INTERNE du pod — convention bwrap_launch.sh (`lcars-pod-<pod_id>`)."
  @spec session_name(String.t()) :: String.t()
  def session_name(pod_id) when is_binary(pod_id), do: "lcars-pod-#{pod_id}"

  @doc """
  Kill le **holder** d'un pod (le process bwrap/host_launch qui tient le namespace + serveur tmux),
  geste de RECOVERY partagé (DRY) par `Pod.reap_orphan_pod`, `Pod.terminate` (fallback tmux_session)
  et `PodWarden.reap`. Le kill PRIMAIRE reste `Port.close` (cf. § « Le KILL n'est PAS ici ») ; ceci
  est le chemin ORPHELIN/fallback où il n'y a plus de Port vivant.

  `tmux kill-server` (sur le sock par-pod) tue tmux+claude ; `pkill -9 -f <pattern>` tue le holder
  (que kill-server laisse vivant — il porte le namespace).

  Le pattern doit être échappé et ancré, jamais le `pod_id` brut : `pkill -9 -f <pod_id>` brut serait NON ÉCHAPPÉ et NON ANCRÉ :
    1. un `pod_id` métacaractérisé sur-matcherait ;
    2. un `pod_id` préfixe d'un autre (`pr-8-engineer` vs `pr-8-engineer-v2`) tuerait les deux ;
    3. un `pod_id` vide/anormal → `pkill -f ""` tuerait **TOUT le host, BEAM inclus** (self-kill).
  D'où `pkill_pattern/1` : garde de validité (refus fail-safe si le pod_id n'a pas la forme
  attendue) + `Regex.escape` + ancrage en token argv. Le holder porte le pod_id comme arg standalone
  (`bwrap_launch.sh <role> <pod_id> <pod_dir>`) → l'ancrage `(^| )id( |$)` le matche sans le manquer,
  tout en excluant les sur-matchs substring.
  """
  @spec kill_holder(String.t()) :: :ok
  def kill_holder(pod_id) when is_binary(pod_id) do
    sock = sock_path(pod_id)
    _ = System.cmd(@tmux_bin, ["-S", sock, "kill-server"], stderr_to_stdout: true)

    case pkill_pattern(pod_id) do
      {:ok, pattern} ->
        _ = System.cmd("pkill", ["-9", "-f", pattern], stderr_to_stdout: true)
        :ok

      :unsafe ->
        Logger.error(
          "PodTmux: pod_id #{inspect(pod_id)} non conforme — `pkill -f` SKIP par sécurité " <>
            "(anti self-kill F-034 : un pattern trop large tuerait le BEAM)"
        )

        :ok
    end
  end

  @doc """
  Pattern `pkill -f` pour un pod_id : ancré-en-token (`(^| )<escaped>( |$)`) et échappé, ou `:unsafe`
  si le pod_id ne matche pas la forme attendue (alphanumérique de tête + `.-_`, ≥4 chars). Public pour
  test — fonction pure. `:unsafe` ⇒ on NE lance PAS pkill (un pod_id vide/anormal produirait
  un pattern catastrophique).
  """
  @spec pkill_pattern(String.t()) :: {:ok, String.t()} | :unsafe
  def pkill_pattern(pod_id) when is_binary(pod_id) do
    if Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9._\-]{3,}\z/, pod_id) do
      {:ok, "(^| )#{Regex.escape(pod_id)}( |$)"}
    else
      :unsafe
    end
  end

  def pkill_pattern(_), do: :unsafe

  @doc "Session vivante ? (`tmux -S <sock> has-session`). Health + recovery."
  @spec alive?(String.t()) :: boolean()
  def alive?(pod_id) when is_binary(pod_id) do
    case tmux(pod_id, ["has-session", "-t", session_name(pod_id)]) do
      {_, 0} -> true
      _ -> false
    end
  end

  @doc """
  Envoie `keys` puis `Enter` au REPL du pod (le KICK, ex. « yop »/« wake »). send-keys est le control-plane
  universel (atteint aussi les slash-commands, contrairement aux channels MCP).

  Robustesse : le texte et l'`Enter` partent en DEUX send-keys distincts (cf. `send_keys_args/2`). Combinés
  en un seul (`keys "Enter"`), le TUI de claude rate l'`Enter` par intermittence (le « yop » n'est pas
  soumis tant qu'on ne renvoie pas l'Enter). send-keys est le SEUL canal out-of-band quand le Monitor
  est mort → il doit être robuste par construction, pas seulement par le retry de la boucle de kick.
  """
  @spec send_keys(String.t(), String.t()) :: :ok | {:error, term()}
  def send_keys(pod_id, keys) when is_binary(pod_id) and is_binary(keys) do
    [text_args, enter_args] = send_keys_args(pod_id, keys)

    with {_, 0} <- tmux(pod_id, text_args),
         {_, 0} <- tmux(pod_id, enter_args) do
      :ok
    else
      {out, code} ->
        Logger.warning("PodTmux send-keys pod=#{pod_id} échec (#{code}) : #{String.trim(out)}")
        {:error, {:tmux_send_failed, code, String.trim(out)}}
    end
  end

  @doc false
  # Séquence d'args tmux pour send_keys : DEUX sends — (1) le texte LITTÉRAL (`-l` : jamais interprété comme
  # key-name), (2) l'`Enter` (key). Séparés = 2 events d'input distincts → le TUI ingère le texte avant le
  # newline. Pure + testable (verrouille le contrat « texte littéral PUIS Enter », anti-régression).
  def send_keys_args(pod_id, keys) when is_binary(pod_id) and is_binary(keys) do
    s = session_name(pod_id)
    [["send-keys", "-t", s, "-l", keys], ["send-keys", "-t", s, "Enter"]]
  end

  @doc """
  Capture le contenu visible du pane du pod (`tmux capture-pane -p`) = l'écran du REPL. Canal d'observation
  DÉPORTÉ, fallback-ACK : quand l'agent n'acke pas, on attache l'écran au ticket d'escalade
  (starfleet voit ce que l'agent affichait/faisait). Renvoie `""` si la capture échoue (best-effort).
  """
  @spec capture_pane(String.t()) :: String.t()
  def capture_pane(pod_id) when is_binary(pod_id) do
    case tmux(pod_id, ["capture-pane", "-p", "-t", session_name(pod_id)]) do
      {out, 0} -> out
      _ -> ""
    end
  end

  defp tmux(pod_id, args) do
    System.cmd(@tmux_bin, ["-S", sock_path(pod_id) | args], stderr_to_stdout: true)
  end
end
