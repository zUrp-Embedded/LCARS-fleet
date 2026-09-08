defmodule Fleet.MCP.PodTools.Delegation.Gate do
  @moduledoc """
  The authorization base of the delegation channels — and the resolution of what an authorized
  gesture is allowed to reach.

  Three things live here, and they share one property: EVERY delegation channel goes through them,
  so a divergence between two copies would be a divergence between two authorizations.

    * the two capability gates (`require_architect/1`, `require_onboarder/1`) — the role is
      resolved from the CHANNEL identity (`state.pod_id`, carried by the socket acceptor), never
      from a wire argument, then asked for a CAPABILITY (`B-03`: authorize a capability, never a
      role name). The two heads and what each admits are documented in `Delegation` itself;
      this module is their single implementation, not their contract.
    * the seam conformance guard (`conforming/2`) — a runtime seam is duck-typed, so a missing
      callback becomes a named `{:seam_misconfigured, impl, missing}` BEFORE dispatch instead of
      an `UndefinedFunctionError` raised half-way through a gesture.
    * `resolve_org/1` — the catalogue of a project decides its forge org, and that link is fixed
      for the project's life.

  Every function is `@doc false`: this is the delegation family's own floor, not a surface any
  other domain calls. It is public only because the channels are separate modules.
  """

  alias Fleet.MCP.PodTools.Delegation.{EscalationForge, ForgeClient, ProjectOnboard}

  # Runtime seams are duck-typed; resolve missing callbacks as a typed error before dispatch.
  @doc false
  @spec conforming_forge() :: {:ok, module()} | {:error, term()}
  def conforming_forge, do: conforming(ForgeClient, ForgeClient.resolved())

  @doc false
  @spec conforming_onboard() :: {:ok, module()} | {:error, term()}
  def conforming_onboard, do: conforming(ProjectOnboard, ProjectOnboard.resolved())

  @doc false
  @spec conforming(module(), module()) :: {:ok, module()} | {:error, term()}
  def conforming(behaviour, impl) do
    _ = Code.ensure_loaded(impl)

    missing =
      for {fun, arity} <- behaviour.behaviour_info(:callbacks),
          not function_exported?(impl, fun, arity),
          do: {fun, arity}

    if missing == [], do: {:ok, impl}, else: {:error, {:seam_misconfigured, impl, missing}}
  end

  @doc false
  @spec conforming_escalation_forge() :: {:ok, module()} | {:error, term()}
  def conforming_escalation_forge,
    do: conforming(EscalationForge, EscalationForge.resolved())

  # L'ORG DU PROJET EST CELLE DE SON CATALOGUE, et ce lien est FIXE POUR SA VIE : « ou vit ce
  # projet » repond a « quel catalogue le traite ».
  #
  # ⚠ UN CATALOGUE NON INSTALLE EST REFUSE : le poller scanne les orgs des catalogues INSTALLES,
  # donc un projet onboarde ailleurs serait un RAIL MORT, silencieux — rien ne le dispatcherait
  # jamais.
  #
  # ⚖ ET LE CATALOGUE EST OBLIGATOIRE, JAMAIS INFERE (arbitrage user). L'inference parait gratuite
  # et ne l'est pas : elle achete un comportement qui CHANGE quand un tiers installe un catalogue
  # portant le meme nom de carte, plus deux branches dont laquelle s'execute depend de la
  # POPULATION du conteneur. L'information, elle, n'est pas absente — elle est dans l'objet que
  # l'appelant vient de lire, qui rend chaque carte AVEC son catalogue.
  #
  # Une decision permanente s'ENONCE ; on ne deduit que ce qui se rattrape.
  @doc false
  @spec resolve_org(map()) :: {:ok, String.t()} | {:error, term()}
  def resolve_org(args) do
    installed = Fleet.Project.Onboard.installed_orgs()

    case Map.get(args, "catalogue") do
      cat when is_binary(cat) and cat != "" ->
        # Le refus vient de la SEULE fonction qui le formule (`Onboard.catalogue_not_installed/1`) :
        # deux formulations d'un meme refus dedoublent le vocabulaire.
        if cat in installed,
          do: {:ok, cat},
          else: Fleet.Project.Onboard.catalogue_not_installed(cat)

      _ ->
        {:error, {:catalogue_required, installed}}
    end
  end

  @doc false
  @spec require_architect(map()) ::
          {:ok, %{role: String.t(), repo: String.t()}} | {:error, term()}
  def require_architect(%{pod_id: pod_id}) when is_binary(pod_id) and pod_id != "" do
    case resolve_identity(pod_id) do
      {:ok, %{role: role} = identity} ->
        # B-03: authorize the capability, never a role name.
        if role_has_capability?(role, :project_delegate),
          do: bound_repo(role, Map.get(identity, :repo)),
          else: {:error, :forbidden_not_architect}

      {:error, _reason} = err ->
        err
    end
  end

  def require_architect(_state), do: {:error, :pod_id_required}

  # LA CAPACITE NE SUFFIT PAS : un architecte dont l'identite de canal ne porte aucun depot ne peut
  # deleguer NULLE PART, et `:repo_unbound` le dit au lieu de laisser passer un depot vide.
  defp bound_repo(role, repo) when is_binary(repo) and repo != "",
    do: {:ok, %{role: role, repo: repo}}

  defp bound_repo(_role, _repo), do: {:error, :repo_unbound}

  # Onboarding also resolves its capability from channel identity, never the wire.
  @doc false
  @spec require_onboarder(map()) :: {:ok, String.t()} | {:error, term()}
  def require_onboarder(%{pod_id: pod_id}) when is_binary(pod_id) and pod_id != "" do
    case resolve_identity(pod_id) do
      # B-03: authorize the capability, never a role list.
      {:ok, %{role: role}} ->
        if role_has_capability?(role, :onboarder),
          do: {:ok, role},
          else: {:error, :forbidden_not_onboarder}

      {:error, _reason} = err ->
        err
    end
  end

  def require_onboarder(_state), do: {:error, :pod_id_required}

  # B-03: Spawner owns cap-profile lookup; unknown identities have no capability.
  @doc false
  @spec role_has_capability?(term(), atom()) :: boolean()
  def role_has_capability?(role, cap) when is_binary(role) and role != "",
    do: Fleet.Spawner.role_has_capability?(role, cap)

  def role_has_capability?(_role, _cap), do: false

  # Spawn-bound identity comes from Spawner; unknown identity fails closed.
  @doc false
  @spec resolve_identity(String.t()) ::
          {:ok, %{role: String.t(), repo: String.t() | nil}} | {:error, :pod_unknown}
  def resolve_identity(pod_id) when is_binary(pod_id) do
    case Fleet.MCP.PodTools.PodResolver.resolved().(pod_id) do
      {:ok, %{role: role} = identity} -> {:ok, %{role: role, repo: Map.get(identity, :repo)}}
      _ -> {:error, :pod_unknown}
    end
  end
end
