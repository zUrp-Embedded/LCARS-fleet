defmodule Fleet.CapProfile.MonksConformanceTest do
  @moduledoc """
  Conformance of the 15 monks + archivist (Memory-X V1) to the schema
  `cap-profile.json` + sanity of the `alpha.yaml`/`beta.yaml` registries.
  Same pattern as the canon cap-profile conformance suite (PROVEN).

  ## G24-11 / ADR #565
  Monks/archivist carry `lifetime_scope: forever` (Type-1 permanent), so the
  G24-11 rule (`subagent_template != null ⟹ one-shot`) is N/A for them: per
  ADR #565 verdict B they use `spec.knowledge.sp_template` (permanent pod),
  NOT `spec.invocation.subagent_template` (one-shot dispatch) — and therefore
  validate ENTIRELY.
  """
  use ExUnit.Case, async: true

  # FROZEN (BL — Memory-X frozen): schema conformance of the monk cap-profiles, now ARCHIVED
  # (`priv/memory-x/monks/`, out of the boot loop). Re-enable when Memory-X is re-homed
  # (per-project + system-wide under lcars).
  @moduletag skip:
               "Memory-X frozen (BL) — monk cap-profiles archived; re-enable at per-project re-home"

  @schema_path Path.join([
                 __DIR__,
                 "..",
                 "..",
                 "..",
                 "priv",
                 "cap_profile",
                 "schema",
                 "cap-profile.json"
               ])
  @monks_dir Path.join([
               __DIR__,
               "..",
               "..",
               "..",
               "priv",
               "catalogue",
               "cap_profile",
               "cap-profiles",
               "monks"
             ])

  setup_all do
    schema = @schema_path |> File.read!() |> Jason.decode!() |> ExJsonSchema.Schema.resolve()
    {:ok, schema: schema}
  end

  test "16 profiles present (5 alpha + 10 beta + archivist) + 2 registries" do
    alpha = Path.wildcard(Path.join(@monks_dir, "monk-alpha-*.yaml"))
    beta = Path.wildcard(Path.join(@monks_dir, "monk-beta-*.yaml"))
    assert length(alpha) == 5, "5 monk-alpha expected, saw #{length(alpha)}"
    assert length(beta) == 10, "10 monk-beta expected, saw #{length(beta)}"
    assert File.exists?(Path.join(@monks_dir, "archivist.yaml"))
    assert File.exists?(Path.join(@monks_dir, "alpha.yaml"))
    assert File.exists?(Path.join(@monks_dir, "beta.yaml"))
  end

  test "monks/archivist: FULLY conformant (post ADR #565 verdict B)",
       %{schema: schema} do
    # ADR #565 verdict B: monks use `spec.knowledge.sp_template` (permanent pod),
    # NOT `spec.invocation.subagent_template` (one-shot dispatch, G24-11).
    # G24-11 unchanged but N/A for monks → they now validate ENTIRELY.
    profiles =
      Path.wildcard(Path.join(@monks_dir, "monk-*.yaml")) ++
        [Path.join(@monks_dir, "archivist.yaml")]

    for f <- profiles do
      cp = YamlElixir.read_from_file!(f)

      assert ExJsonSchema.Validator.validate(schema, cp) == :ok,
             "#{Path.basename(f)}: non-conformant post #565-B — #{inspect(ExJsonSchema.Validator.validate(schema, cp))}"

      refute get_in(cp, ["spec", "invocation", "subagent_template"]),
             "#{Path.basename(f)}: residual subagent_template (must be knowledge.sp_template, #565-B)"

      assert get_in(cp, ["spec", "knowledge", "sp_template"]),
             "#{Path.basename(f)}: knowledge.sp_template missing (#565-B)"
    end
  end

  test "alpha.yaml/beta.yaml registries: well-formed monks (kind removed, R0.8-brick2)" do
    for {file, svc, n} <- [{"alpha.yaml", "alpha", 5}, {"beta.yaml", "beta", 10}] do
      reg = YamlElixir.read_from_file!(Path.join(@monks_dir, file))
      # R0.8-brick2: `kind: MemoryRegistry` removed (a single kind per directory).
      assert reg["metadata"]["service"] == svc
      monks = reg["spec"]["monks"]
      assert length(monks) == n, "#{file}: #{n} monks expected, saw #{length(monks)}"

      for m <- monks do
        assert is_binary(m["name"]) and m["name"] != ""
        assert is_list(m["corpus_paths"]) and m["corpus_paths"] != []
        assert is_integer(m["token_budget"])
        assert is_binary(m["persona_hint"])
        assert m["version"] == "v2.5"
      end
    end
  end

  test "registry monk names == cap-profile names (monk_instance coherence)" do
    for {file, prefix} <- [{"alpha.yaml", "monk-alpha-"}, {"beta.yaml", "monk-beta-"}] do
      reg = YamlElixir.read_from_file!(Path.join(@monks_dir, file))
      reg_names = reg["spec"]["monks"] |> Enum.map(& &1["name"]) |> Enum.sort()

      cp_instances =
        Path.wildcard(Path.join(@monks_dir, "#{prefix}*.yaml"))
        |> Enum.map(fn f ->
          YamlElixir.read_from_file!(f)["spec"]["knowledge"]["monk_instance"]
        end)
        |> Enum.sort()

      assert reg_names == cp_instances,
             "#{file}: registry names #{inspect(reg_names)} ≠ cap-profile instances #{inspect(cp_instances)}"
    end
  end
end
