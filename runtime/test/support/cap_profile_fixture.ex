defmodule Fleet.Support.CapProfileFixture do
  @moduledoc """
  Builds nominal CapProfile fixtures through the validated constructor.
  Reads the bundled YAML directly, independently of catalogue root overrides, then
  merges and validates overrides. Deliberate schema-bypass tests should construct
  their invalid structs explicitly instead of using this helper.
  """
  use Boundary, deps: [Fleet.CapProfile], exports: []

  alias Fleet.CapProfile

  @canon_rel Path.join(["catalogue", "cap_profile", "cap-profiles"])

  @doc """
  Deep-merges stringified overrides into the bundled base role (default engineer),
  replacing non-map values, and validates with CapProfile.from_map!/1. Returns the
  profile or raises on an unreadable base or invalid result.
  """
  @spec build(map(), String.t()) :: CapProfile.t()
  def build(overrides \\ %{}, base_role \\ "engineer") do
    CapProfile.from_map!(deep_merge(canon_base(base_role), stringify(overrides)))
  end

  defp canon_base(role) do
    path = Path.join([:code.priv_dir(:lcars_fleet), @canon_rel, "#{role}.yaml"])
    {:ok, raw} = YamlElixir.read_from_file(path)
    raw
  end

  defp deep_merge(l, r) when is_map(l) and is_map(r),
    do: Map.merge(l, r, fn _k, lv, rv -> deep_merge(lv, rv) end)

  defp deep_merge(_l, r), do: r

  defp stringify(m) when is_map(m) and not is_struct(m),
    do: Map.new(m, fn {k, v} -> {to_string(k), stringify(v)} end)

  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)
  defp stringify(other), do: other
end
