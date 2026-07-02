defmodule Fleet.Pilot.ForgeProtocol do
  @moduledoc """
  Vocabulaire **pur** du wire-protocol forge-state-machine : la forge EST la machine à états,
  ces formats sont son fil. SOURCE UNIQUE des marqueurs gravés sur les issues/PR et des
  feature-branches. Aucun I/O — que du build + parse de chaînes (les ops HTTP qui les
  *posent*/les *lisent* vivent dans `Fleet.Pilot.ForgeClient`).

  Pendant de `Fleet.Pilot.Labels` (les deux portent le wire-protocol) : `Labels` = les
  **labels-verrous** (`lcars-in-flight`/`lcars-awaits-arch`) ; ici = **branches, marqueurs
  route/step_run/onboard, blocs result** et le **primitif de confiance** `system_authored?/2`.

  **Invariant build+parse co-localisés** : chaque format a son BUILDER et son PARSEUR dans
  CE module, l'un collé à l'autre — un changement de format se fait ICI, les deux ensemble,
  jamais l'un sans l'autre (plus de drift entre ce qui est écrit et ce qui est relu).
  Les consommateurs (`StepDispatcher`, `StepRunConsumer`, `StepRunCompleter`, `Poller`) appellent ces
  fonctions DIRECTEMENT. Seul `parse_feature_branch/1` est aussi ré-exporté par `ForgeClient`
  (`defdelegate`) : `fleet_mcp` l'atteint via le seam `:forge_client` pour éviter une dépendance
  compile-time vers fleet_pilot.
  """

  # ============================================================
  # Feature-branch système `lcars/issue-<n>-<role>`.
  # ============================================================

  # Littéral-SOURCE UNIQUE du format : builder ET parseur en dérivent (zéro token écrit en double).
  @feature_branch_prefix "lcars/issue-"
  # Regex DÉRIVÉ du même littéral — `Regex.escape` neutralise le `/` (et tout méta-caractère) du prefix
  # → littéral inerte dans le pattern, jamais interprété comme syntaxe regex.
  @feature_branch_rx Regex.compile!("^" <> Regex.escape(@feature_branch_prefix) <> "(\\d+)-(.+)$")

  @doc """
  Construit la feature-branch systeme `lcars/issue-<n>-<role>` — le BUILDER unique du format,
  dérivé de `@feature_branch_prefix` tout comme son parseur `parse_feature_branch/1` : un changement
  de format se fait sur CE seul littéral, build et parse suivent (plus de token en double).
  Identite garantie : `parse_feature_branch(feature_branch(n, role)) == {:ok, {n, role}}`.
  """
  @spec feature_branch(integer(), String.t()) :: String.t()
  # => "lcars/issue-<n>-<role>"
  def feature_branch(n, role) when is_integer(n) and is_binary(role),
    do: "#{@feature_branch_prefix}#{n}-#{role}"

  @doc """
  Extrait `{issue_number, role}` d'une feature-branch systeme `lcars/issue-<n>-<role>` (format
  construit par `feature_branch/2`, son inverse co-localise). Sert au dispatch juge PR-driven a
  remonter de la PR (head.ref) au issue. `:error` si le ref n'est pas une feature-branch fleet (PR
  externe / branche manuelle -> ignoree par le dispatch, jamais misroutee).
  """
  @spec parse_feature_branch(String.t()) :: {:ok, {integer(), String.t()}} | :error
  def parse_feature_branch(head) when is_binary(head) do
    case Regex.run(@feature_branch_rx, head) do
      [_, n, role] -> {:ok, {String.to_integer(n), role}}
      _ -> :error
    end
  end

  def parse_feature_branch(_), do: :error

  # ============================================================
  # Marqueur ROUTE — position workflow_map sur la forge.
  # `[lcars-route:<workflow_map_name>:<step>]` : grave (workflow_map_name, step) sur l'issue, car l'assignee
  # (= rôle) seul n'identifie pas le step (un rôle peut être sur N steps, cf. WorkflowMapNav).
  # ============================================================

  # Littéral-SOURCE UNIQUE : builder ET parseur en dérivent.
  @route_prefix "[lcars-route:"
  # Regex DÉRIVÉ du même littéral — `Regex.escape` neutralise le `[` (et `-`) du prefix → littéral, pas
  # de la syntaxe regex. PAS d'ancre `^` : un marqueur route peut être noyé dans le corps d'un comment.
  @route_marker_rx Regex.compile!(Regex.escape(@route_prefix) <> "([^:\\]]+):([^:\\]]+)\\]")

  @doc """
  Construit le marqueur route `[lcars-route:<workflow_map_name>:<step>]` (builder unique, dérivé de
  `@route_prefix` comme son parseur `parse_route_marker/1`). Posé par `ForgeClient.post_route/5`.
  """
  @spec route_marker(String.t(), String.t()) :: String.t()
  # => "[lcars-route:<workflow_map_name>:<step>]"
  def route_marker(workflow_map_name, step) when is_binary(workflow_map_name) and is_binary(step),
    do: "#{@route_prefix}#{workflow_map_name}:#{step}]"

  @doc false
  # Pur : extrait `{workflow_map_name, step}` d'un body contenant `[lcars-route:p:s]`, sinon nil.
  def parse_route_marker(nil), do: nil

  def parse_route_marker(body) when is_binary(body) do
    case Regex.run(@route_marker_rx, body) do
      [_, workflow_map_name, step] -> {:ok, {workflow_map_name, step}}
      _ -> nil
    end
  end

  # ============================================================
  # Marqueur de STEP_RUN signé `[step_run:<role>:<sha>]` — compteur forge-natif anti-runaway.
  # ============================================================

  # Littéral-SOURCE UNIQUE : builder ET prédicat en dérivent.
  @step_run_prefix "[step_run:"
  # Regex DÉRIVÉ du même littéral — `Regex.escape` neutralise le `[` du prefix. PAS d'ancre : le
  # marqueur est posé en fin de body de comment.
  @step_run_marker_rx Regex.compile!(Regex.escape(@step_run_prefix) <> "[^:\\]]+:[^:\\]]+\\]")

  @doc """
  Format du marqueur de step_run signé `[step_run:<role>:<sha>]` (builder dérivé de `@step_run_prefix`, tout comme
  son prédicat `step_run_marker?/1` — un changement de format se fait sur CE seul littéral). Posé par
  `StepRunCompleter` en fin-de-step-run, sert aussi de `:dedup_signature` (replay idempotent).

  Round-trip builder -> prédicat (le prédicat reconnaît ce que le builder grave) :

      iex> marker = Fleet.Pilot.ForgeProtocol.step_run_marker("engineer", "deadbeef")
      iex> marker
      "[step_run:engineer:deadbeef]"
      iex> Fleet.Pilot.ForgeProtocol.step_run_marker?(marker)
      true
      iex> Fleet.Pilot.ForgeProtocol.step_run_marker?("juste un commentaire")
      false
  """
  @spec step_run_marker(String.t(), String.t()) :: String.t()
  def step_run_marker(role, sha) when is_binary(role) and is_binary(sha) do
    # => "[step_run:<role>:<sha>]"
    "#{@step_run_prefix}#{role}:#{sha}]"
  end

  @doc false
  # Pur : un body porte-t-il un marqueur de step_run signé ? Inverse de `step_run_marker/2` pour le comptage
  # forge-natif (`ForgeClient.count_signed_step_runs`).
  def step_run_marker?(body) when is_binary(body), do: Regex.match?(@step_run_marker_rx, body)
  def step_run_marker?(_), do: false

  # ============================================================
  # Bloc ` ```result ` — sérialise les `outputs` d'un step dans le comment de step_run.
  # ============================================================

  @result_block_rx ~r/```result\n(.*?)\n```/s
  @result_fence_limit 8192

  @doc """
  Format du bloc ` ```result ` (sérialise les `outputs` d'un step dans le comment de step_run).
  Co-localisé avec son parseur `parse_result_block/1` — round-trip garanti. `nil`/vide →
  `""` (pas de bruit). JSON fencé si ≤ 8 KB ; au-delà, une note pointant vers le livrable de la
  branche (jamais de JSON tronqué = invalide). Préfixe `\\n\\n` inclus (séparateur du corps).
  """
  @spec result_block(map() | nil) :: String.t()
  def result_block(outputs) when is_map(outputs) and map_size(outputs) > 0 do
    json = Jason.encode!(outputs)

    if byte_size(json) <= @result_fence_limit do
      "\n\n```result\n#{json}\n```"
    else
      "\n\n_(result #{byte_size(json)} o — trop volumineux pour le comment ; livrable complet sur la branche système)_"
    end
  end

  def result_block(_), do: ""

  @doc false
  # Pur : extrait le map du dernier bloc ```result d'un body, sinon nil.
  def parse_result_block(body) when is_binary(body) do
    case Regex.run(@result_block_rx, body) do
      [_, json] ->
        case Jason.decode(json) do
          {:ok, map} when is_map(map) -> {:ok, map}
          _ -> nil
        end

      _ ->
        nil
    end
  end

  def parse_result_block(_), do: nil

  # ============================================================
  # Marqueur d'ADMISSION `[lcars-onboarded:<human>]` + primitif de confiance.
  # ============================================================

  @onboard_marker_prefix "[lcars-onboarded:"

  @doc """
  Format du marqueur d'admission `[lcars-onboarded:<human>]` (co-localisé avec son lecteur
  `ForgeClient.admitted?/3`). Posé par l'onboarding via `ForgeClient.post_onboard_marker/3` comme
  TITRE de l'issue système d'admission, lu+vérifié bot-authored par le poller à la découverte.
  """
  @spec onboard_marker(String.t()) :: String.t()
  def onboard_marker(human) when is_binary(human), do: "#{@onboard_marker_prefix}#{human}]"

  @doc false
  # Pur : un comment est DE CONFIANCE ssi son auteur = le compte système (bot)
  # de la fleet. Un user forge (humain/attaquant) a un autre login → ses marqueurs sont ignorés.
  def system_authored?(comment, bot_login)
      when is_map(comment) and is_binary(bot_login) and bot_login != "" do
    get_in(comment, ["user", "login"]) == bot_login
  end

  def system_authored?(_comment, _bot), do: false
end
