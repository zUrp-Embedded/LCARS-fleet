defmodule Fleet.CapProfile.Invariants do
  @moduledoc """
  Pure semantic checks on a composed profile, exposed through `CapProfile.validate/1`.
  The registry in `violations/1` defines code order; each check defines its rule.
  Run structural validation separately: arbitrary malformed field shapes can raise here.

  Error atoms are a frozen caller/test/contract-check vocabulary: do not rename or reuse
  retired g24_2, g24_5, g24_7 and g24_13. The removed mcp_channels field never enforced tool
  access; the surface comes from scope.allowedTools/mcp_fleet_tools and MCP handler gates.
  G24-14 checks only monk-field pairing, not filesystem existence or instance lookup.
  The retired apiVersion check is not a missing guard: schema versioning belongs to the code.
  """

  alias Fleet.CapProfile

  @kind_pinned "CapabilityProfile"

  # Profiles must declare denials for server-side tools that escape pod containment.
  # These checks require exact strict entries and at least one match per prefix; they do
  # not inject denials or prove the launcher enforces them. Git denials are separately
  # injected by DisallowedTools; keep the server-tool minimum visible in catalogue data.
  @disallowed_minimum_strict ~w(web_search web_fetch code_execution bash_code_execution text_editor_code_execution)
  @disallowed_minimum_prefix ~w(tool_search_)

  @containment_enum ~w(bwrap none)
  @lifetime_scope_enum ~w(one-shot pipe run forever)

  @doc """
  The list of G24 invariant codes VIOLATED by the composed profile (`[]` = all
  pass). Stable order = the declaration order of the registry below.
  Pure: same struct ⇒ same list.

  `CapProfile.validate/1` is the sole consumer; it translates `[]` into
  `:ok` and a non-empty list into `{:error, list}`.
  """
  @spec violations(CapProfile.t()) :: [atom()]
  def violations(%CapProfile{} = profile) do
    [
      {:g24_1, &check_containment/1},
      {:g24_3, &check_kind/1},
      {:g24_4, &check_lifetime_scope/1},
      {:g24_6, &check_modop_incompatible/1},
      {:g24_8, &check_metadata_name/1},
      {:g24_9_strict, &check_disallowed_strict/1},
      {:g24_9_prefix, &check_disallowed_prefix/1},
      {:g24_10, &check_boot_at_start_forever/1},
      {:g24_11, &check_subagent_template_one_shot/1},
      {:g24_12, &check_host_native_containment/1},
      {:g24_14, &check_monk_registry_pairing/1},
      {:g24_15, &check_slot_scope_declared/1},
      {:g24_16, &check_remote_control_declared/1},
      {:g24_17, &check_human_facing_visible/1}
    ]
    |> Enum.reject(fn {_code, fun} -> fun.(profile) == :ok end)
    |> Enum.map(fn {code, _fun} -> code end)
  end

  @doc """
  Returns the code-side `lifetime_scope` enum used by the schema drift test.
  """
  @spec lifetime_scope_enum() :: [String.t()]
  def lifetime_scope_enum, do: @lifetime_scope_enum

  @doc """
  Returns the code-side containment enum for schema drift checks. Widening it requires
  checking downstream containment policy: values other than bwrap bypass its proxy path.
  """
  @spec containment_enum() :: [String.t()]
  def containment_enum, do: @containment_enum

  defp check_containment(%CapProfile{metadata: meta}) do
    if Map.get(meta, "containment") in @containment_enum, do: :ok, else: :error
  end

  defp check_kind(%CapProfile{kind: k}) do
    if k == @kind_pinned, do: :ok, else: :error
  end

  defp check_lifetime_scope(%CapProfile{spec: spec}) do
    if get_in(spec, ["invocation", "lifetime_scope"]) in @lifetime_scope_enum,
      do: :ok,
      else: :error
  end

  defp check_modop_incompatible(%CapProfile{spec: spec} = profile) do
    modop_set = Map.get(spec, "modop_set", %{})

    pairs = if is_map(modop_set), do: Map.get(modop_set, "incompatible", []), else: []
    active = MapSet.new(CapProfile.active_modops(profile))

    conflict? =
      Enum.any?(pairs, fn pair ->
        case pair do
          [a, b] -> MapSet.member?(active, a) and MapSet.member?(active, b)
          _ -> false
        end
      end)

    if conflict?, do: :error, else: :ok
  end

  defp check_metadata_name(%CapProfile{metadata: meta}) do
    case Map.get(meta, "name") do
      name when is_binary(name) and byte_size(name) > 0 -> :ok
      _ -> :error
    end
  end

  defp check_disallowed_strict(%CapProfile{spec: spec}) do
    disallowed = get_in(spec, ["scope", "disallowedTools"]) || []
    if Enum.all?(@disallowed_minimum_strict, &(&1 in disallowed)), do: :ok, else: :error
  end

  defp check_disallowed_prefix(%CapProfile{spec: spec}) do
    disallowed = get_in(spec, ["scope", "disallowedTools"]) || []

    prefix_ok =
      Enum.all?(@disallowed_minimum_prefix, fn prefix ->
        Enum.any?(disallowed, &String.starts_with?(&1, prefix))
      end)

    if prefix_ok, do: :ok, else: :error
  end

  defp check_boot_at_start_forever(%CapProfile{spec: spec}) do
    if get_in(spec, ["invocation", "boot_at_start"]) == true and
         get_in(spec, ["invocation", "lifetime_scope"]) != "forever" do
      :error
    else
      :ok
    end
  end

  defp check_subagent_template_one_shot(%CapProfile{spec: spec}) do
    template = get_in(spec, ["invocation", "subagent_template"])
    scope = get_in(spec, ["invocation", "lifetime_scope"])

    if is_binary(template) and template != "" and scope != "one-shot" do
      :error
    else
      :ok
    end
  end

  defp check_host_native_containment(%CapProfile{spec: spec, metadata: meta}) do
    if get_in(spec, ["invocation", "host_native"]) == true and
         Map.get(meta, "containment") != "none" do
      :error
    else
      :ok
    end
  end

  defp check_monk_registry_pairing(%CapProfile{spec: spec}) do
    registry? = monk_present?(get_in(spec, ["knowledge", "monk_registry"]))
    instance? = monk_present?(get_in(spec, ["knowledge", "monk_instance"]))

    if registry? == instance?, do: :ok, else: :error
  end

  defp monk_present?(v), do: is_binary(v) and String.trim(v) != ""

  # Context-long profiles must choose per-ticket or shared project identity explicitly.
  # One-shot profiles may omit slot_scope; a blanket schema requirement would reject them.
  defp check_slot_scope_declared(%CapProfile{spec: spec}) do
    if get_in(spec, ["invocation", "lifetime_scope"]) == "one-shot" or
         get_in(spec, ["invocation", "slot_scope"]) in ~w(instance project),
       do: :ok,
       else: :error
  end

  # A stable project identity must explicitly choose Desktop visibility; instance slots
  # may use the invisible default to avoid a Desktop handle for every ticket.
  defp check_remote_control_declared(%CapProfile{spec: spec} = profile) do
    if CapProfile.slot_scope(profile) != "project" or
         is_boolean(get_in(spec, ["invocation", "remote_control"])),
       do: :ok,
       else: :error
  end

  # Human-facing protocols require visibility, including when derived rather than declared.
  # Ignore the fleet debug override: a temporary switch must not repair an incoherent profile.
  defp check_human_facing_visible(%CapProfile{} = profile) do
    if CapProfile.interlocutor(profile) in ~w(both human) and
         not CapProfile.remote_control?(profile),
       do: :error,
       else: :ok
  end
end
