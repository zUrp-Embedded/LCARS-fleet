defmodule Fleet.MCP.PodTools.Delegation.Gate do
  @moduledoc """
  Shared capability checks, runtime seam export checks and explicit catalogue selection.
  PodTools supplies channel state; roles resolve through PodResolver and capabilities
  through Spawner. The architect gate additionally requires a nonempty repo binding.

  conforming checks exported callback names/arities, not result shapes or semantics.
  resolve_org requires an installed catalogue rather than inferring it from a card.
  Public functions are internal helpers shared across delegation modules.
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

  # Catalogue chooses the onboarding org. Require it explicitly: a card name can
  # become ambiguous when another catalogue is installed. Restrict to installed
  # catalogues because those are the orgs the poller discovers.
  @doc false
  @spec resolve_org(map()) :: {:ok, String.t()} | {:error, term()}
  def resolve_org(args) do
    installed = Fleet.Project.Onboard.installed_orgs()

    case Map.get(args, "catalogue") do
      cat when is_binary(cat) and cat != "" ->
        # Reuse Onboard's named refusal for an uninstalled catalogue.
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

  # Capability without a project binding cannot authorize project-bound delegation.
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
