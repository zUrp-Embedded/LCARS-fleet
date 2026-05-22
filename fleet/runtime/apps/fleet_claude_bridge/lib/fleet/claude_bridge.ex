defmodule Fleet.ClaudeBridge do
  @moduledoc """
  Wrapper LCARS sur le SDK community Elixir `guess/claude_code`
  (HEAD `9912a35` v0.36.3, MIT, https://github.com/guess/claude_code).

  Frontière vendor niveau 1 isolée par convention nommage préfixe
  `claude_*`. Sans ce wrapper, pas de `claude -p` stream-json côté
  système-side LCARS v2.

  ## 6 sous-modules co-localisés

    * `Fleet.ClaudeBridge.HookRegistry` — F-ADP-2 mitigation CRITICAL :
      force `can_use_tool` non-nil au boot pod (FAIL si nil)
    * `Fleet.ClaudeBridge.PermissionAdapter` — **vestigial** (ADR-D
      rev2 : permission routing retiré, bwrap = guard de surface).
      DefaultDeny fail-safe conservé (§0 #1 axiome préservé)
    * `Fleet.ClaudeBridge.SessionWrapper` — D5 wrap permissif `Session.new/1`
      + `Session.send/2`, pas pid exposé pods workers (D4 mitigation)
    * `Fleet.ClaudeBridge.MCPRouter` — D3 MCP stdio externe (DSL `MCP.Server`
      SDK BYPASS, PoC-4 PROVEN)
    * `Fleet.ClaudeBridge.Stream` — D4 écriture maison ~200L (helpers
      text_content/tool_uses/filter_type/until_result via PubSub
      `fleet_event_router` chantier 11)
    * `Fleet.ClaudeBridge.SPInjection` — flags `claude -p`
      `--system-prompt-file`/`--append-system-prompt-file` (cohérent
      `fleet_spbuilder` N2/N2bis chantier 2)

  ## 5 disciplines SDK obligatoires

    * Pin version exacte `0.36.3` + commit ref `9912a35`
    * Wrap systématique (`fleet_claude_bridge` seul consommateur sauf
      exception `Fleet.Credentials.PlanValidator` documentée chantier 3)
    * Watcher upstream cron hebdo (action post-1ère implem)
    * Audit complet 100% coverage (consultant SDK 2026-05-09 PROVEN
      8.0/10, 0 bug critique)
    * Contribuer upstream PR si bugs identifiés

  ## F-ADP-2 CRITICAL

  `ControlHandler.handle_can_use_tool(_, %HookRegistry{can_use_tool: nil}, _) →
  %{"behavior" => "allow"}` côté SDK = **default-ALLOW silent** si
  registry.can_use_tool nil. **Inverse canon LCARS §1 "refus par défaut"**.

  Mitigation : `Fleet.ClaudeBridge.HookRegistry.build!/1` raise si
  `permission_adapter` nil → FAIL boot pod, pas default-ALLOW silent.
  Test conformance OBLIGATOIRE CI suite.

  ## Note dep `:claude_code`

  Au chantier 8 (run #3.1), la dep `:claude_code` n'est PAS introduite
  dans `mix.exs` car le pod qualifier est en Elixir 1.14 (transitif
  `peri 0.8.4` requiert ~> 1.17 — apprentissages A1+A5). Les sous-modules
  utilisent des **maps shape-compatibles** avec les structs SDK
  (ex `%{can_use_tool, hooks_pre, hooks_post}` ↔ `%ClaudeCode.HookRegistry{}`).
  Au runtime production (pod Elixir 1.18), le caller peut promote
  map → struct.

  Wiring SDK réel = à introduire post-upgrade pod env Elixir 1.18 +
  consommateur effectif `fleet_pod_runtime` chantier 7.

  ## API publique V2 (Lot 5 — DN §amendement RCMode)

  `session_start/1` route selon `:mode` :
    * `:remote_control` → `Fleet.ClaudeBridge.RCMode` (pivot V2 ;
      `claude remote-control --spawn=session`, fallback Port si SDK absent)
    * `:print` → `Fleet.ClaudeBridge.SessionWrapper` (legacy chantier-8)
    * `:auto` (défaut) → RC (substitution V2 ; pods permanents ET
      éphémères, DN L398-399). `:print` uniquement si RC indisponible
      (ni SDK RC ni binaire `claude`) → warning (DN test 6).

  Module fonctionnel (PAS un behaviour) : chantier-8 l'a laissé doc-only ;
  Lot 5 ajoute le routeur concret (construction-additive). Le pseudo-code
  DN `@callback` est illustratif — le livrable est la fonction routeur.
  """

  require Logger

  alias Fleet.ClaudeBridge.{RCMode, SessionWrapper}

  @type session_ref :: map()

  @doc """
  Démarre une session pod selon `opts[:mode]` (`:remote_control` |
  `:print` | `:auto`, défaut `:auto`). F-ADP-2 préservé via RCMode
  (raise si `:permission_adapter` absent en mode RC).
  """
  @spec session_start(keyword()) :: {:ok, session_ref()} | {:error, term()}
  def session_start(opts) when is_list(opts) do
    case Keyword.get(opts, :mode, :auto) do
      :remote_control -> RCMode.start_session(opts)
      :print -> SessionWrapper.new(opts)
      :auto -> auto_select(opts)
      other -> {:error, {:unknown_mode, other}}
    end
  end

  @doc "Raccourci explicite RC mode (DN §amendement `session_start_rc`)."
  @spec session_start_rc(keyword()) :: {:ok, session_ref()} | {:error, term()}
  def session_start_rc(opts) when is_list(opts), do: RCMode.start_session(opts)

  @doc """
  RC est-il disponible ? Vrai si le SDK supporte RC OU si un binaire
  `claude` est résoluble (fallback Port RCMode). Test-seam `:rc_available`.
  """
  @spec rc_available?(keyword()) :: boolean()
  def rc_available?(opts \\ []) when is_list(opts) do
    case Keyword.get(opts, :rc_available) do
      nil -> RCMode.sdk_supports_rc?() or claude_binary_present?()
      forced when is_boolean(forced) -> forced
    end
  end

  defp auto_select(opts) do
    if rc_available?(opts) do
      RCMode.start_session(opts)
    else
      Logger.warning(
        "Fleet.ClaudeBridge: RC indisponible (ni SDK RC ni binaire claude) — " <>
          "fallback :print (impact coût : pool programmatic post-pivot)"
      )

      SessionWrapper.new(opts)
    end
  end

  defp claude_binary_present?, do: not is_nil(System.find_executable("claude"))
end
