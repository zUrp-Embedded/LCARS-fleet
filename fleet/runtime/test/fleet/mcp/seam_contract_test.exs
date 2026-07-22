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
  @seams [
    {Fleet.MCP.PodTools.Delegation.ForgeClient, Fleet.Pilot.ForgeClient},
    {Fleet.MCP.PodTools.Delegation.EscalationForge, Fleet.Pilot.ForgeClient}
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
