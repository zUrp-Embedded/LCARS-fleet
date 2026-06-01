defmodule Fleet.Spawner.LaunchBackend.TmuxBackend do
  @moduledoc """
  Backend unifié U3 — lance `claude --remote-control --name <role>` dans
  une tmux session nommée `lcars:<pod_id>`. Remplace `LauncherPortBackend` (mode
  `claude --print` legacy) pour le pivot RC permanent + reset via /clear.

  ## Pourquoi tmux

  Trois propriétés essentielles que `Port.open` n'offre pas :

    1. **Persistance** : la tmux session survit aux crashes du LCARS
       daemon BEAM — au respawn supervisor, le Pod GenServer re-attache
       à la session existante (via `tmux has-session -t lcars:<pod_id>`).
    2. **Canal `/clear`** : `tmux send-keys -t lcars:<pod_id> "/clear" Enter`
       est le SEUL canal pour les slash commands claude (MCP channels
       sont `skipSlashCommands: true` par design vendor — cf. reverse
       `#5b_channels-structuredio.md`).
    3. **PTY natif** : claude REPL exige TTY ; tmux fournit le pseudo-tty
       sans qu'on doive bricoler `expect`/`socat`.

  ## ⚠️ Containment dégradé (POC scope)

  Cette POC lance claude **hors-bwrap** (containment: none). Le bwrap +
  tmux + claude --remote-control demande `--share-net` (bridge HTTPS
  Anthropic), `--bind /run/user/<uid>` (tmux socket), mount-bind setup
  XDG → complexité substantielle. **À reload Phase 2 livrable** :
  réintégrer bwrap pour cap-profiles canon (G24-12 host_native par
  dérogation explicite si bwrap+tmux pas fixable).

  ## Lifecycle

    * `launch/2` :
        1. spawn `tmux new-session -d -s lcars:<pod_id> "claude --remote-control --name <role> ..."`
        2. `tmux has-session -t lcars:<pod_id>` → confirme up
        3. retourne `{:ok, %{tmux_session: name, port: nil, init_message: nil}}`

  Le Pod (caller) gère les phases suivantes via les seams existants :
  Bus subscribe `pod.result_submitted` pour completion, kill_pod via
  `kill_session/1`, `/clear` via `send_clear/1`.

  ## Pas de Port Erlang

  Contrairement à LauncherPortBackend, on ne tient PAS un `port()` Erlang sur
  le process claude — la tmux session est detached, donc `Port.open` du
  tmux client retournerait immédiatement. À la place, le pod_id est la
  clé : `tmux_session` name = `"lcars:" <> pod_id`, et toutes les ops
  passent par `System.cmd("tmux", [...])`.
  """

  @behaviour Fleet.Spawner.LaunchBackend

  require Logger

  # `:` est séparateur tmux target spec (`session:window.pane`) → forbidden
  # dans noms de session, tmux le remplace silencieusement par `_`. On
  # utilise `-` au lieu de `:` pour le prefix.
  @session_prefix "lcars-"
  @tmux_bin "tmux"

  @impl Fleet.Spawner.LaunchBackend
  def launch(args, env) when is_map(args) and is_map(env) do
    with {:ok, session_name, cmd} <- build_tmux_spawn(args),
         {:ok, _} <- ensure_tmux_available(),
         :ok <- kill_existing(session_name),
         :ok <- spawn_session(session_name, cmd, args, env),
         :ok <- confirm_session(session_name) do
      Logger.info(
        "fleet_spawner TmuxBackend launched session=#{session_name} role=#{Map.get(args, :role, "?")}"
      )

      {:ok, %{tmux_session: session_name, port: nil, init_message: nil, ndjson_log: nil}}
    end
  end

  # ============================================================
  # Public helpers (Pod owns send_clear + kill_session)
  # ============================================================

  @doc "Nom de tmux session conventionnel pour `pod_id`."
  @spec session_name(String.t()) :: String.t()
  def session_name(pod_id) when is_binary(pod_id), do: @session_prefix <> pod_id

  @doc """
  Envoie `/clear` (ou autre slash command) au pod via tmux send-keys.
  Reset le context claude REPL en préservant l'identité bridge
  (cf. doctrine consultant : /clear régénère sessionId local, bridge
  handle survit → environment_id Desktop stable).
  """
  @spec send_clear(String.t()) :: :ok | {:error, term()}
  def send_clear(session_name) when is_binary(session_name) do
    case System.cmd(@tmux_bin, ["send-keys", "-t", session_name, "/clear", "Enter"],
           stderr_to_stdout: true
         ) do
      {_, 0} -> :ok
      {output, code} -> {:error, {:tmux_send_failed, code, String.trim(output)}}
    end
  end

  @doc """
  Injecte un prompt multi-ligne dans le claude REPL via load-buffer + paste-buffer.

  Pourquoi pas `notifications/claude/channel` MCP push : reverse #5b §2.3 — gate 2
  `isChannelsEnabled() = tengu_harbor` GrowthBook flag default false côté
  Anthropic. Sans dev bypass non-public, channels skipped. send-keys (control
  plane) reste le canal universel tant que le flag n'est pas activé.

  load-buffer fait passer le content entier (newlines préservés) dans un buffer
  tmux nommé. paste-buffer le déverse dans le pane sans interprétation shell.
  Enter final valide le prompt côté REPL. Buffer puis supprimé (isolation).

  Le buffer name = "lcars-brief-<session_short>" pour éviter collisions cross-pod
  si plusieurs pods envoient des briefs en parallèle (tmux a un namespace global
  buffer).
  """
  @spec send_prompt(String.t(), String.t()) :: :ok | {:error, term()}
  def send_prompt(session_name, content) when is_binary(session_name) and is_binary(content) do
    buffer_name = "lcars-brief-#{:erlang.phash2(session_name) |> Integer.to_string()}"

    with :ok <- load_buffer(buffer_name, content),
         :ok <- paste_buffer(session_name, buffer_name),
         :ok <- send_enter(session_name) do
      delete_buffer(buffer_name)
      :ok
    else
      {:error, _} = err ->
        delete_buffer(buffer_name)
        err
    end
  end

  defp load_buffer(buffer_name, content) do
    # System.cmd ne supporte pas :input stdin → write content dans temp file
    # puis `tmux load-buffer -b NAME FILE`. Cleanup du fichier en fin.
    tmp_path = Path.join(System.tmp_dir!(), "lcars-brief-#{:erlang.phash2(buffer_name)}.txt")

    try do
      File.write!(tmp_path, content)

      case System.cmd(@tmux_bin, ["load-buffer", "-b", buffer_name, tmp_path],
             stderr_to_stdout: true
           ) do
        {_, 0} -> :ok
        {output, code} -> {:error, {:tmux_load_buffer_failed, code, String.trim(output)}}
      end
    after
      _ = File.rm(tmp_path)
    end
  end

  defp paste_buffer(session_name, buffer_name) do
    case System.cmd(@tmux_bin, ["paste-buffer", "-t", session_name, "-b", buffer_name],
           stderr_to_stdout: true
         ) do
      {_, 0} -> :ok
      {output, code} -> {:error, {:tmux_paste_buffer_failed, code, String.trim(output)}}
    end
  end

  defp send_enter(session_name) do
    case System.cmd(@tmux_bin, ["send-keys", "-t", session_name, "Enter"], stderr_to_stdout: true) do
      {_, 0} -> :ok
      {output, code} -> {:error, {:tmux_send_enter_failed, code, String.trim(output)}}
    end
  end

  defp delete_buffer(buffer_name) do
    System.cmd(@tmux_bin, ["delete-buffer", "-b", buffer_name], stderr_to_stdout: true)
    :ok
  end

  @doc "Termine la tmux session (et le process claude qu'elle hébergeait)."
  @spec kill_session(String.t()) :: :ok
  def kill_session(session_name) when is_binary(session_name) do
    System.cmd(@tmux_bin, ["kill-session", "-t", session_name], stderr_to_stdout: true)
    :ok
  end

  @doc "Vérifie si la session existe (utilisé par Pod recovery + health)."
  @spec session_alive?(String.t()) :: boolean()
  def session_alive?(session_name) when is_binary(session_name) do
    case System.cmd(@tmux_bin, ["has-session", "-t", session_name], stderr_to_stdout: true) do
      {_, 0} -> true
      _ -> false
    end
  end

  # ============================================================
  # Pure build (testable)
  # ============================================================

  @doc """
  Pur : construit `{:ok, session_name, claude_cmd_string}` pour
  `tmux new-session -d -s <name> "<claude_cmd>"`. La cmd est une string
  shell (tmux la passe à `sh -c`), pas argv direct.
  """
  @spec build_tmux_spawn(map()) :: {:ok, String.t(), String.t()} | {:error, term()}
  def build_tmux_spawn(%{role: role, pod_id: pod_id} = args)
      when is_binary(role) and is_binary(pod_id) do
    session = session_name(pod_id)
    cmd = build_pod_cmd(role, args)
    {:ok, session, cmd}
  end

  def build_tmux_spawn(_), do: {:error, :invalid_args}

  defp build_pod_cmd(role, args) do
    pod_dir = Map.get(args, :pod_dir, "")
    settings_path = Path.join([pod_dir, ".lcars", "settings.json"])
    # U4 canon : `.mcp-fleet.json` (PAS `.mcp.json`) — c'est le nom écrit par
    # `Fleet.Spawner.Pod.maybe_provision_mcp_config/1`. Évite l'auto-discovery
    # de `.mcp.json` + son dialog de trust (cohérent claude_launch.sh R1.1).
    # `--strict-mcp-config` : claude n'utilise QUE cette config (rien d'autre).
    mcp_config_path = Path.join([pod_dir, ".mcp-fleet.json"])
    # SP du pod écrit par `Fleet.Spawner.Pod.do_project` (compose SPBuilder +
    # agent-worker-base draft). Passé via `--system-prompt-file` (PAS append) :
    # le SP composé est l'IDENTITÉ DU POD, doit dominer le canal API system
    # parameter (cf. reverse `moon-shot_v1/02-prior-art/reverse-claude-code/
    # sp-vs-claudemd.md` Finding 1+6 : --system-prompt-file = system parameter
    # API, canal le plus fort, blob unique). Avec --append on traînerait le
    # default claude (skills auto-discovery + CLAUDE.md auto + onboarding)
    # = dilution + bruit contexte. Le pod a son SP, point.
    sp_path = Path.join([pod_dir, ".lcars", "system-prompt.md"])

    # Binaire claude system-wide. Voie officielle Anthropic sur Linux =
    # dépôt apt/dnf/apk signé (cf. https://code.claude.com/docs/en/setup
    # § "Install with Linux package managers"). Sur Debian/Ubuntu (cas
    # LCARS) : `sudo apt install claude-code` depuis le repo
    # `https://downloads.claude.ai/claude-code/apt/latest` → binaire posé
    # dans `/usr/bin/claude` par dpkg.
    # Le `claude install` natif ne supporte PAS --global (issue #21570) ;
    # toute install per-home `~/.local/bin/claude` est per-user (versions
    # potentiellement hétérogènes, anti-pattern pour la fleet).
    # Default : `/usr/bin/claude` (apt-installed, dpkg-managed, updates
    # pilotés par starfleet hors LCARS — backlog discipline SDK).
    # Override par env `LCARS_CLAUDE_BIN` ou config `:fleet_spawner,
    # :claude_bin` (utile pour tests ou environnements non-Debian).
    claude_bin = resolve_claude_bin()

    # `--dangerously-skip-permissions` : flag de base inconditionnel pour les
    # pods. Le pod EST une sandbox (workspace isolé, HOME=pod_dir, containment
    # bwrap en livrable Phase 2 — POC dégradé pour l'instant). La validation
    # amont est le cap-profile (allowedTools/disallowedTools/git_ops_denied
    # appliqués par baseline + with_resolved_disallowed_tools). À l'intérieur
    # de la sandbox, l'agent est libre — c'est le contrat sandbox.
    # Pattern cohérent avec le LCARS v1 (consultant, qualifier-tmux) qui
    # tournent sous ce flag.
    parts =
      [
        shell_quote(claude_bin),
        "--remote-control",
        shell_quote(role),
        "--dangerously-skip-permissions"
      ]
      |> maybe_append("--settings", settings_path, &File.exists?/1)
      |> maybe_append("--system-prompt-file", sp_path, &File.exists?/1)
      |> maybe_append_strict_mcp(mcp_config_path)

    Enum.join(parts, " ")
  end

  defp resolve_claude_bin do
    Application.get_env(:fleet_spawner, :claude_bin) ||
      System.get_env("LCARS_CLAUDE_BIN") ||
      "/usr/bin/claude"
  end

  defp maybe_append(parts, flag, path, exists_fn) do
    if exists_fn.(path), do: parts ++ [flag, shell_quote(path)], else: parts
  end

  defp maybe_append_strict_mcp(parts, mcp_config_path) do
    if File.exists?(mcp_config_path) do
      parts ++ ["--mcp-config", shell_quote(mcp_config_path), "--strict-mcp-config"]
    else
      parts
    end
  end

  # Shell-quote minimal : enveloppe single-quotes, échappe les single-quotes
  # internes (a'b → 'a'\''b'). Suffisant pour les paths LCARS qui sont
  # alphanumériques + tirets + slashes (pas de quotes attendues).
  defp shell_quote(s) when is_binary(s) do
    "'" <> String.replace(s, "'", "'\\''") <> "'"
  end

  # ============================================================
  # Internals — tmux ops
  # ============================================================

  defp ensure_tmux_available do
    case System.find_executable(@tmux_bin) do
      nil -> {:error, :tmux_not_found_in_path}
      path -> {:ok, path}
    end
  end

  defp kill_existing(session_name) do
    if session_alive?(session_name) do
      Logger.warning(
        "fleet_spawner TmuxBackend session #{session_name} déjà existante — kill puis re-spawn"
      )

      kill_session(session_name)
    end

    :ok
  end

  defp spawn_session(session_name, cmd, args, env) do
    pod_dir = Map.get(args, :pod_dir, System.tmp_dir!())

    # tmux spawn la cmd via le default-shell de l'user du process.
    # Si l'user système qui run le daemon (ex. `lcars` en prod) a un
    # shell `/usr/sbin/nologin` (sécurité service systemd), tmux échoue
    # silencieusement → session_not_up. On force `bash -c "<cmd>"` pour
    # contourner.
    #
    # Env propagation : `tmux -e KEY=VAL` set la var au SESSION level mais
    # ne la propage PAS automatiquement au premier shell (besoin d'un
    # update-environment configuré côté tmux). Pour garantir que claude
    # voit LCARS_POD_ID, OAuth tokens, etc., on inline `export` dans
    # le wrap shell. Trade-off : env vars (dont OAuth tokens) visibles
    # dans cmdline ps — acceptable POC (host trust, sandbox containment
    # Phase 2 livrable). Filter ANTHROPIC_API_KEY / ANTHROPIC_AUTH_TOKEN
    # explicitement.
    inner_cmd = build_inline_export(env) <> cmd
    shell_wrapped_cmd = "bash -c #{shell_quote(inner_cmd)}"

    tmux_args =
      ["new-session", "-d", "-s", session_name, "-c", pod_dir, shell_wrapped_cmd]

    # `SHELL=/bin/bash` : tmux exec le cmd via le shell pointé par $SHELL
    # (fallback /etc/passwd login shell). En prod le daemon tourne user
    # `lcars` dont passwd shell = `/usr/sbin/nologin` → tmux fail
    # silencieusement (session_not_up_after_spawn). Forcer SHELL=/bin/bash
    # sur le sub-process tmux contourne sans toucher au système.
    case System.cmd(@tmux_bin, tmux_args,
           stderr_to_stdout: true,
           env: [{"SHELL", "/bin/bash"}]
         ) do
      {_, 0} -> :ok
      {output, code} -> {:error, {:tmux_new_session_failed, code, String.trim(output)}}
    end
  end

  # Construit un préfixe shell `export K=V; export K2=V2; ...` pour le
  # bash -c. Garantit la propagation env au premier shell (vs tmux -e qui
  # ne propage pas auto). Filtre vars sensibles (ANTHROPIC_API_KEY /
  # ANTHROPIC_AUTH_TOKEN) pour ne pas bypasser l'OAuth.
  defp build_inline_export(env) do
    env
    |> Enum.reject(fn {k, _} -> k in ~w(ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN) end)
    |> Enum.map_join("", fn {k, v} -> "export #{k}=#{shell_quote(to_string(v))}; " end)
  end

  defp confirm_session(session_name) do
    if session_alive?(session_name) do
      :ok
    else
      {:error, {:session_not_up_after_spawn, session_name}}
    end
  end
end
