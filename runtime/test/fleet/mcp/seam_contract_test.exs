defmodule Fleet.MCP.SeamContractTest do
  @moduledoc """
  IMPL-side locks of the duck-typed upward seams (mcp → pilot).

  The consumer side is compiler-checked (test stubs adopt the behaviours — anti lying-stub), but
  the REAL implementations CANNOT adopt them (`@behaviour` is a compile reference; pilot adopting
  an mcp module would be the forbidden upward edge). So nothing at compile time proves the pilot
  modules still export what the contracts promise — a renamed/re-aritied function drifts silently
  and breaks in prod, not in CI. These tests are that missing mirror (same role as the
  SOC-CONTRACT lock on the `:mcp_socket_provisioner` seam): DERIVED from `behaviour_info/1`, so a
  callback added to a contract is enforced here automatically — no second list to keep in sync.
  """
  use ExUnit.Case, async: true

  # {behaviour contract, canonical default impl (the module `resolved/0` falls back to)}
  #
  # EVERY duck-typed seam belongs here, and the list was HALF of them until 2026-08-03 (BL-6-44):
  # the two `mcp → pilot` contracts were locked while `spawner → mcp` and the onboarding contract
  # were not, for no reason anyone had written — the same mirror, the same manual propagation, the
  # same silent break at runtime. A lock that covers some instances of a hazard and not others
  # reads, to whoever adds the next one, as if the uncovered ones were deliberate.
  @seams [
    {Fleet.MCP.PodTools.Delegation.ForgeClient, Fleet.Forge.Client},
    {Fleet.MCP.PodTools.Delegation.EscalationForge, Fleet.Forge.Client},
    # spawner → mcp: a pod spawn cannot provision its socket if this one drifts.
    {Fleet.Spawner.McpSocketProvisioner, Fleet.MCP.PodSocketSupervisor},
    # mcp → pilot: the arch's `project_create` lands here.
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
