defmodule Fleet.Support.CapProfileFixture do
  @moduledoc """
  `%Fleet.CapProfile{}` fixture builder backed by the validated constructor `Fleet.CapProfile.from_map!/1`
  (BND-001): a NOMINAL fixture crosses the SAME schema boundary as prod, instead of forging a partial
  `%CapProfile{spec: …}` that short-circuits the schema (the invalid state made representable again).

  `build/2` starts from a real CANON profile (the YAML of `priv/cap_profile/canon/cap-profiles/` read
  DIRECTLY — single source = the canon, not a 2nd hardcoded copy of the schema; read by priv path,
  independent of the global `:root_dir` other tests mutate), deep-merges the `overrides` (stringified
  keys), and RE-VALIDATES the whole. An override breaking the schema raises at construction: the
  fixture is wrong, not the code.

  NOT to be used to DELIBERATELY test a schema-bypassed profile (e.g. an accessor's fail-loud on an
  absent field): those cases remain hand-built `%CapProfile{}`, in a test explicitly named
  "schema bypass" — the builder does not replace them.
  """
  use Boundary, deps: [Fleet.CapProfile], exports: []

  alias Fleet.CapProfile

  @canon_rel Path.join(["cap_profile", "canon", "cap-profiles"])

  @doc """
  Canon profile `base_role` (default `"engineer"`) deep-merged with `overrides` (stringified keys) then
  RE-VALIDATED via `Fleet.CapProfile.from_map!/1`. Returns a schema-conformant `%CapProfile{}`, or raises.
  """
  @spec build(map(), String.t()) :: CapProfile.t()
  def build(overrides \\ %{}, base_role \\ "engineer") do
    CapProfile.from_map!(deep_merge(canon_base(base_role), stringify(overrides)))
  end

  # Reads the canon YAML DIRECTLY (frozen priv path) — not via the loader, whose `:root_dir` is a
  # global another test may have repointed to a tmp catalogue without this role.
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
