defmodule Mix.Tasks.Lcars.Contracts.CapabilitiesExercisableCheckTest do
  @moduledoc """
  The `roles.capabilities_exercisable` wall, proven against CRAFTED trees — because it reports an
  absence, and an absence is what a blind instrument reports too.

  What it guards: a cap-profile may declare a capability whose gate opens tools the role does not
  carry. The gate would admit the pod and no call ever reaches it, so the declaration authorizes
  nothing and describes nothing — while reading, to every human and every agent, as a granted
  permission. That is how `architect` carried `onboarder` through a transition that had ended.

  Nothing here hardcodes a capability name: the check derives gate -> capability -> delegation ->
  tool from the AST, so these fixtures invent their own capabilities and the wall still finds them.
  """
  use ExUnit.Case, async: true

  alias Mix.Tasks.Lcars.Contracts.Check.Tools

  @tools_rel "lib/fleet/mcp/pod_tools.ex"
  @deleg_rel "lib/fleet/mcp/pod_tools/delegation.ex"
  @roles_rel "priv/catalogue/cap_profile/cap-profiles"

  # Two gates, each asking about ONE capability — the shape the derivation reads. `gates` lets a
  # test shrink that to one, which is the instrument floor rather than a real defect.
  defp delegation(gates) do
    defs =
      Enum.map_join(1..gates, "\n", fn i ->
        """
          def head_#{i}(state) do
            with {:ok, role} <- require_head_#{i}(state), do: {:ok, role}
          end

          defp require_head_#{i}(state) do
            if role_has_capability?(state, :cap_#{i}), do: {:ok, state}, else: {:error, :no}
          end
        """
      end)

    "defmodule Delegation do\n#{defs}\nend\n"
  end

  defp pod_tools(gates) do
    clauses =
      Enum.map_join(1..gates, "\n", fn i ->
        """
          def handle_tool_call("tool_#{i}", _args, state) do
            Delegation.head_#{i}(state)
          end
        """
      end)

    "defmodule PodTools do\n#{clauses}\nend\n"
  end

  defp role_yaml(name, caps, tools) do
    """
    kind: CapabilityProfile
    metadata:
      name: #{name}
    spec:
      capabilities: [#{Enum.join(caps, ", ")}]
      scope:
        allowedTools:
    #{Enum.map_join(tools, "\n", &"      - #{&1}")}
    """
  end

  # `roles` is a list of {name, capabilities, allowedTools}.
  defp tree(roles, opts \\ []) do
    gates = Keyword.get(opts, :gates, 2)
    root = Fleet.TestEnv.tmp_path("caps_exercisable")
    File.mkdir_p!(Path.join(root, "lib/fleet/mcp/pod_tools"))
    File.mkdir_p!(Path.join(root, @roles_rel))
    File.write!(Path.join(root, @tools_rel), pod_tools(gates))
    File.write!(Path.join(root, @deleg_rel), delegation(gates))

    for {name, caps, tools} <- roles do
      File.write!(Path.join([root, @roles_rel, "#{name}.yaml"]), role_yaml(name, caps, tools))
    end

    on_exit(fn -> File.rm_rf!(root) end)
    root
  end

  test "a role carrying a tool of the capability it declares PASSES" do
    root = tree([{"worker", ["cap_1"], ["Read", "mcp__fleet__tool_1"]}])

    assert %{status: :pass, evidence: []} = Tools.check_capabilities_exercisable(root)
  end

  test "a role declaring a capability and carrying NONE of its tools is REFUSED, and named" do
    # The exact defect: the gate would say yes, and no call can reach it.
    root = tree([{"worker", ["cap_1"], ["Read", "mcp__fleet__tool_2"]}])

    assert %{status: :fail, evidence: evidence} = Tools.check_capabilities_exercisable(root)
    assert evidence == ["worker declares cap_1 and carries none of its tools"]
  end

  test "ONE tool of the capability is enough — the check is a floor, not an inventory" do
    # A role legitimately carries a subset: the arch has the delegation head's read verbs and not
    # its writes. Demanding the full set would turn every narrowing into a red.
    root =
      tree(
        [{"worker", ["cap_1", "cap_2"], ["mcp__fleet__tool_1", "mcp__fleet__tool_2"]}],
        gates: 2
      )

    assert %{status: :pass} = Tools.check_capabilities_exercisable(root)
  end

  test "a capability NO gate reads is out of scope, not a violation" do
    # `producer` is selected by a card, the judges are resolved by the runtime to spawn someone:
    # nothing about them is exercised by reaching for a tool, so there is no list to compare.
    root = tree([{"worker", ["producer"], ["Read"]}])

    assert %{status: :pass, evidence: []} = Tools.check_capabilities_exercisable(root)
  end

  test "several roles: every violation is reported, sorted — not just the first" do
    root =
      tree([
        {"alpha", ["cap_1"], ["Read"]},
        {"beta", ["cap_2"], ["Read"]},
        {"gamma", ["cap_1"], ["mcp__fleet__tool_1"]}
      ])

    assert %{status: :fail, evidence: evidence} = Tools.check_capabilities_exercisable(root)

    assert evidence == [
             "alpha declares cap_1 and carries none of its tools",
             "beta declares cap_2 and carries none of its tools"
           ]
  end

  test "INSTRUMENT: a tree the derivation cannot read is a FAIL, never a silent pass" do
    # One gate instead of two — modelling an AST shape change that empties the derivation. Without
    # this floor the check would report "no inert capability" while having measured nothing, which
    # is the failure mode it exists to prevent in the roles it inspects.
    root = tree([{"worker", ["cap_1"], ["Read"]}], gates: 1)

    assert %{status: :fail, evidence: [evidence]} = Tools.check_capabilities_exercisable(root)
    assert evidence =~ "INSTRUMENT BROKEN"
  end
end
