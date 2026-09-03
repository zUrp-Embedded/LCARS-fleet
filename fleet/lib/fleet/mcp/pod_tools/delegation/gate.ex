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

  require Logger

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

  # L'ORG DU PROJET EST CELLE DE SON CATALOGUE, et ce lien est fixe pour sa vie : « ou vit ce projet »
  # repond a « quel catalogue le traite ». Le choix se fait au guichet, la ou l'humain choisit deja sa
  # carte — starfleet porte les deux verbes.
  #
  # Un catalogue NON INSTALLE est refuse, et c'est la meme raison que l'ancien commentaire donnait pour
  # coller cette org a celle du poller : un projet onboarde dans une org que le poller ne scanne pas
  # est un RAIL MORT, silencieux — rien ne le dispatcherait jamais. Le poller scannant desormais les
  # orgs des catalogues INSTALLES, la condition se dit exactement ainsi.
  #
  # ⚖ LE CATALOGUE EST OBLIGATOIRE (user, 2026-08-17), ET CE QUI A ETE RETIRE VAUT D'ETRE LU.
  #
  # Trois versions en une journee, chacune tuee par la meme question posee un cran plus loin :
  #   1. l'omission prenait le PREMIER catalogue installe — deviner un lien fixe pour la vie ;
  #   2. puis « un seul installe -> lui, sinon derive de la carte » — « tu cables un rail
  #      d'exception par confort », et c'etait vrai : cette branche derivait de la POPULATION ;
  #   3. puis la regle unique « quels catalogues peuvent repondre ? un -> il decide » — « donc tu as
  #      encore un rail qui teste un truc, que tu supprimerais en posant le catalogue obligatoire ».
  #
  # Vrai aussi, et mon argument pour la garder etait FAUX. J'avais dit « friction pour zero
  # information » : l'information n'est pas absente, elle est dans l'objet que l'appelant vient de
  # lire — `card_list` rend chaque carte AVEC son catalogue. Exiger le champ coute une
  # recopie, et l'inference achetait, contre ce rien : un comportement qui change quand un TIERS
  # installe un catalogue portant le meme nom de carte, et deux branches dont laquelle s'execute
  # depend de la population de la boite — donc jamais les deux au meme endroit.
  #
  # Le voisin le disait deja : `import_deposit/4` prend son catalogue en argument POSITIONNEL. Ce
  # verbe-ci etait l'exception, pas la regle.
  #
  # « Quel metier traite ce projet » est la question la plus basique qu'on puisse poser sur lui, et
  # elle n'a pas de defaut — bien moins que « quel niveau de soin », qui en a un (C0 non declare).
  # Une decision permanente s'ENONCE ; on ne deduit que ce qui se rattrape.
  #
  # `:mcp_delegation_org` est mort avec l'inference : il n'avait que ce lecteur. `:pilot_fleet_org`
  # survit, il appartient au poller.
  @doc false
  @spec resolve_org(map()) :: {:ok, String.t()} | {:error, term()}
  def resolve_org(args) do
    installed = Fleet.Project.Onboard.installed_orgs()

    case Map.get(args, "catalogue") do
      cat when is_binary(cat) and cat != "" ->
        # Le refus vient de la SEULE fonction qui le formule (`Onboard.catalogue_not_installed/1`) :
        # deux formulations d'un meme refus, c'est ainsi que le vocabulaire s'etait dedouble.
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
        if role_has_capability?(role, :project_delegate) do
          case Map.get(identity, :repo) do
            repo when is_binary(repo) and repo != "" -> {:ok, %{role: role, repo: repo}}
            _ -> {:error, :repo_unbound}
          end
        else
          {:error, :forbidden_not_architect}
        end

      {:error, _reason} = err ->
        err
    end
  end

  def require_architect(_state), do: {:error, :pod_id_required}

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
