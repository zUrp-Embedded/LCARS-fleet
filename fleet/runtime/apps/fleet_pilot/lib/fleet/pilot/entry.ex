defmodule Fleet.Pilot.Entry do
  @moduledoc """
  **Entrée** d'un ticket dans une carte (A2.1, DN `orchestration/forge-state-machine.md` §3/§8).
  Un ticket neuf porte un `type:*` qui sélectionne une carte (`forge-routing`) ; l'entrée pose la
  **position initiale** : grave le marqueur route du premier stage + assigne son rôle. Ensuite la
  machine normale prend le relais (StageDispatcher voit assignee+route → spawn ; HopCompleter
  enchaîne via CarteNav).

  « Tout est un pipeline » (DN §3) : 1-stage = carte à 1 stage (entrée → terminal direct), N-stage =
  chaîne. Le `type:` est lu **une seule fois, ici, à l'entrée** (invariant convention-tickets v2 §5) ;
  il ne mute pas ensuite.

  ## resolve/3 (pur)

  `payload` (issue Gitea) + `routing` (`%{"type:X" => "carte-name"}`) + `loader` (seam carte) →
  `{:ok, {pipeline, first_stage, first_role}}` | `{:skip, reason}`.

  ## enter/2 (I/O)

  Idempotent : si l'issue a déjà un marqueur route (`get_route ≠ :none`), elle est déjà entrée →
  `{:skip, :already_routed}`. Sinon : `post_route(pipeline, first_stage)` PUIS
  `set_assignee(first_role)` — route AVANT assignee (le prochain tick voit l'assignee avec sa
  position déjà gravée, cohérent §5).
  """

  require Logger

  @doc """
  Résout la carte d'entrée depuis le `type:*` du ticket. Pur (loader = seam carte).
  """
  @spec resolve(map(), %{optional(String.t()) => String.t()}, module()) ::
          {:ok, {String.t(), String.t(), String.t()}} | {:skip, term()}
  def resolve(payload, routing, loader) do
    issue = Map.get(payload, "issue", payload)
    labels = Enum.map(Map.get(issue, "labels", []), & &1["name"])

    case Enum.find(labels, &String.starts_with?(&1 || "", "type:")) do
      nil ->
        {:skip, :no_type}

      type_label ->
        case Map.get(routing, type_label) do
          nil ->
            {:skip, {:no_carte_for, type_label}}

          pipeline ->
            resolve_first_stage(pipeline, loader)
        end
    end
  end

  defp resolve_first_stage(pipeline, loader) do
    case load_carte(pipeline, loader) do
      {:ok, carte} ->
        case Fleet.Pilot.CarteNav.first_stage(carte) do
          {:ok, {stage, role}} -> {:ok, {pipeline, stage, role}}
          {:error, reason} -> {:skip, {:carte_first_stage, reason}}
        end

      {:error, reason} ->
        {:skip, {:carte_load, reason}}
    end
  end

  defp load_carte(pipeline, loader) do
    # B (§L441) : plus de `validate_explicit_stage` (biconditionnelle soft⟺gatekeeper,
    # A2.3b) — une gate soft sur un stage métier est légitime (escalade gatekeeper). Le
    # Loader valide le schema ; pas de garde-fou explicit-stage.
    {:ok, loader.load!(pipeline)}
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc """
  Entre effectivement le ticket dans sa carte. Idempotent (déjà routé → skip).

  `opts` : `:repo` (obligatoire), `:routing` (map type→carte), `:forge_opts`, seams
  `:forge_client` / `:loader`.
  """
  @spec enter(map(), keyword()) ::
          {:ok, {:entered, role :: String.t()}} | {:skip, term()} | {:error, term()}
  def enter(payload, opts) do
    forge = Keyword.get(opts, :forge_client, Fleet.Pilot.ForgeClient)
    loader = Keyword.get(opts, :loader, Fleet.Pipeline.Loader)
    routing = Keyword.get(opts, :routing, %{})
    repo = Keyword.fetch!(opts, :repo)
    forge_opts = Keyword.get(opts, :forge_opts, [])

    issue = Map.get(payload, "issue", payload)
    number = issue["number"]

    case forge.get_route(repo, number, forge_opts) do
      {:ok, _} ->
        {:skip, :already_routed}

      :none ->
        do_enter(payload, number, routing, loader, forge, repo, forge_opts)

      {:error, reason} ->
        {:error, {:route_read, reason}}
    end
  end

  defp do_enter(payload, number, routing, loader, forge, repo, forge_opts) do
    case resolve(payload, routing, loader) do
      {:skip, reason} ->
        {:skip, reason}

      {:ok, {pipeline, first_stage, first_role}} ->
        # #8.A : Entry grave SEULEMENT la route (position carte). L'assignee N'EST PLUS écrasé par le
        # rôle-worker (`set_assignee` retiré) — il reste l'HUMAIN (traça, posé à la création du ticket).
        # Le rôle du stage courant est dérivé de la route au dispatch (`StageDispatcher.carte_role`),
        # plus de l'assignee. L'état/position vit dans la route + les labels, pas dans l'assignee.
        case forge.post_route(repo, number, pipeline, first_stage, forge_opts) do
          {:ok, _} ->
            Logger.info(
              "Entry: #{repo}##{number} → carte=#{pipeline} stage=#{first_stage} (role=#{first_role}, assignee=humain inchangé)"
            )

            {:ok, {:entered, first_role}}

          {:error, reason} ->
            {:error, {:enter, reason}}
        end
    end
  end
end
