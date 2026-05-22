defmodule Fleet.ClaudeBridge.RCMode do
  @moduledoc """
  Wrapper LCARS pour `claude remote-control --spawn=session` — substitut
  V2 de `claude --print` post-pivot Anthropic 15/06/2026 (préserve le pool
  subscription, cf. `01_architecture/decisions-pivot.md` décision 1).

  DN : `ring1/fleet_claude_bridge.md` §"Extensions V2 — extension RCMode".
  Frontière vendor N1 préfixe `claude_*` (ADR-C). **Extension** du wrapping
  chantier-8 (PAS refactor — errata decisions-pivot rev1).

  ## Réalité chantier-8 (lecture, pas supposition)

  Le SDK `guess/claude_code` est **délibérément absent** des deps
  (`apps/fleet_claude_bridge/mix.exs` — env pod < 1.18). Les modules
  wrappers utilisent des maps shape-compatibles, **aucune référence
  `ClaudeCode.*` en dur** dans le code. RCMode respecte ce pattern :

  - `sdk_supports_rc?/0` → `false` tant que le SDK n'est pas chargé
    (`Code.ensure_loaded?`) → **chemin MVP = fallback `Port` direct**
    sur le binaire `claude` (`claude remote-control --spawn=session`).
  - La branche SDK est invoquée par `apply/3` sur un atome module
    (jamais d'appel `ClaudeCode.Session.x()` littéral) → compile clean,
    pas de warning, bascule automatique si le SDK ajoute le support
    upstream (discipline #5 PR).

  ## F-ADP-2 CRITICAL préservé

  `start_session/1` exige `:permission_adapter` et appelle
  `Fleet.ClaudeBridge.HookRegistry.build!/1` qui **raise** si nil —
  pas de default-ALLOW silent en mode RC (canon LCARS §1 refus-défaut).
  """

  @sdk_session ClaudeCode.Session
  @rc_min_version "0.37.0"

  @type session_ref :: %{
          required(:adapter) => :sdk_rc | :lcars_port,
          required(:opaque) => term(),
          required(:hook_registry) => map()
        }

  @doc """
  Démarre une session `claude remote-control --spawn=session`.

  ## Inputs (opts)

    * `:system_prompt_file` (obligatoire) — path absolu SP
    * `:permission_adapter` (obligatoire, F-ADP-2) — module `can_use_tool/3`
    * `:name` (optionnel) — nom de session
    * `:resume` (optionnel) — session_id à reprendre
    * `:port_opener` (optionnel, test-seam) — fun/2 `(path, args) -> port`
      (défaut : `Port.open` réel sur le binaire `claude`)

  ## Returns

  `{:ok, session_ref()}` | `{:error, term()}`. **Raise** si
  `:permission_adapter` absent (F-ADP-2, via `HookRegistry.build!/1`).
  """
  @spec start_session(keyword()) :: {:ok, session_ref()} | {:error, term()}
  def start_session(opts) when is_list(opts) do
    sp_path = Keyword.fetch!(opts, :system_prompt_file)
    # F-ADP-2 : build!/1 POSSÈDE le raise canonique (RuntimeError "F-ADP-2:
    # permission_adapter obligatoire") si nil. On passe via Keyword.get —
    # surtout PAS fetch!/2 (qui masquerait le F-ADP-2 par un KeyError).
    hook_registry =
      Fleet.ClaudeBridge.HookRegistry.build!(
        permission_adapter: Keyword.get(opts, :permission_adapter)
      )

    args = build_rc_args(opts)

    if sdk_supports_rc?() do
      start_via_sdk(sp_path, opts, hook_registry)
    else
      start_via_port(args, opts, hook_registry)
    end
  end

  @doc """
  Construit la liste d'arguments `claude remote-control` (fonction pure —
  cœur testable, DN test 4/7).

      iex> Fleet.ClaudeBridge.RCMode.build_rc_args(
      ...>   system_prompt_file: "/sp.md", name: "architect", resume: "abc")
      ["remote-control", "--spawn=session", "--system-prompt-file", "/sp.md",
       "--name", "architect", "--resume", "abc"]
  """
  @spec build_rc_args(keyword()) :: [String.t()]
  def build_rc_args(opts) when is_list(opts) do
    sp_path = Keyword.fetch!(opts, :system_prompt_file)

    ["remote-control", "--spawn=session", "--system-prompt-file", sp_path]
    |> maybe_arg("--name", Keyword.get(opts, :name))
    |> maybe_arg("--resume", Keyword.get(opts, :resume))
  end

  @doc "Envoie un message à une session RC (équivalent `Session.send/2`)."
  @spec send_message(session_ref(), map()) :: :ok | {:error, term()}
  def send_message(%{adapter: :sdk_rc, opaque: s}, msg) do
    apply(@sdk_session, :send, [s, msg])
  end

  def send_message(%{adapter: :lcars_port, opaque: port}, msg) when is_port(port) do
    payload = Jason.encode!(msg) <> "\n"

    if Port.command(port, payload), do: :ok, else: {:error, :port_command_failed}
  rescue
    e -> {:error, {:port_send_failed, Exception.message(e)}}
  end

  @doc "Termine proprement une session RC."
  @spec close_session(session_ref()) :: :ok
  def close_session(%{adapter: :sdk_rc, opaque: s}) do
    apply(@sdk_session, :stop, [s])
    :ok
  end

  def close_session(%{adapter: :lcars_port, opaque: port}) when is_port(port) do
    if Port.info(port), do: Port.close(port)
    :ok
  end

  @doc """
  Le SDK `guess/claude_code` chargé supporte-t-il le mode remote-control ?
  MVP : `false` (SDK absent des deps chantier-8). Bascule automatique si
  le SDK est introduit + version ≥ #{@rc_min_version} (discipline #5).
  """
  @spec sdk_supports_rc?() :: boolean()
  def sdk_supports_rc? do
    Code.ensure_loaded?(@sdk_session) and
      function_exported?(@sdk_session, :start_link, 1) and
      sdk_version_supports_rc?(Application.spec(:claude_code, :vsn))
  end

  # --- privé ---

  defp start_via_sdk(sp_path, opts, hook_registry) do
    case apply(@sdk_session, :start_link, [
           [
             mode: :remote_control,
             spawn: :session,
             system_prompt_file: sp_path,
             name: Keyword.get(opts, :name),
             resume: Keyword.get(opts, :resume),
             hook_registry: hook_registry
           ]
         ]) do
      {:ok, s} -> {:ok, %{adapter: :sdk_rc, opaque: s, hook_registry: hook_registry}}
      {:error, _} = err -> err
      other -> {:error, {:sdk_session_failed, other}}
    end
  end

  defp start_via_port(args, opts, hook_registry) do
    opener = Keyword.get(opts, :port_opener, &default_port_open/2)
    bin = Keyword.get(opts, :claude_bin) || claude_binary_path()

    try do
      port = opener.(bin, args)
      {:ok, %{adapter: :lcars_port, opaque: port, hook_registry: hook_registry}}
    rescue
      e -> {:error, {:rc_port_open_failed, Exception.message(e)}}
    end
  end

  defp default_port_open(bin, args) do
    Port.open({:spawn_executable, bin}, [:binary, :exit_status, {:args, args}])
  end

  defp claude_binary_path do
    System.find_executable("claude") || raise "claude binary not found in PATH"
  end

  defp sdk_version_supports_rc?(vsn) when is_list(vsn) do
    case Version.parse(to_string(vsn)) do
      {:ok, v} -> Version.compare(v, @rc_min_version) in [:gt, :eq]
      :error -> false
    end
  end

  defp sdk_version_supports_rc?(_), do: false

  defp maybe_arg(args, _flag, nil), do: args
  defp maybe_arg(args, _flag, ""), do: args
  defp maybe_arg(args, flag, val) when is_binary(val), do: args ++ [flag, val]
end
