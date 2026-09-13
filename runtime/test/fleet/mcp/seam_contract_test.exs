defmodule Fleet.MCP.SeamContractTest do
  @moduledoc """
  Check callback exports of the explicitly listed default implementations.
  This supports cross-boundary seams where adopting the consumer's behaviour would
  create a forbidden compile dependency. Callback additions are derived from each
  behaviour; adding another seam still requires extending this manual list.
  """
  use ExUnit.Case, async: true

  # Selected behaviour/default pairs, including spawner socket provisioning.
  @seams [
    {Fleet.MCP.PodTools.Delegation.ForgeClient, Fleet.Forge.Client},
    {Fleet.MCP.PodTools.Delegation.EscalationForge, Fleet.Forge.Client},
    # spawner → mcp: a pod spawn cannot provision its socket if this one drifts.
    {Fleet.Spawner.McpSocketProvisioner, Fleet.MCP.PodSocketSupervisor},
    # Onboarding default behind project tools.
    {Fleet.MCP.PodTools.Delegation.ProjectOnboard, Fleet.Project.Onboard}
  ]

  for {contract, impl} <- @seams do
    test "#{inspect(impl)} exports every callback of #{inspect(contract)}" do
      contract = unquote(contract)
      impl = unquote(impl)
      Code.ensure_loaded!(impl)

      missing =
        for {fun, arity} <- contract.behaviour_info(:callbacks),
            not function_exported?(impl, fun, arity),
            do: {fun, arity}

      assert missing == [],
             "#{inspect(impl)} is missing #{inspect(missing)} promised by #{inspect(contract)} — " <>
               "the duck-typed seam would crash at runtime dispatch, not at compile"
    end
  end
end
