defmodule Fleet.CapProfile.MonksV25ConformanceTest do
  @moduledoc """
  Lot 4 inc4 — conformité des 15 monks + archivist (Memory-X V1) au schema
  `cap-profile-v2.5.json` + sanity des registries `alpha.yaml`/`beta.yaml`.
  Pattern Lot 0bis/Lot 5 inc4 (PROVEN).

  ## Honnêteté D-LS-6 — gap G24-11 escaladé #565
  Les monks/archivist portent `subagent_template` (DN fleet_memory.md
  L153, requis) ET `lifetime_scope: forever` (Type-1 permanent). Le schema
  G24-11 (`subagent_template != null ⟹ one-shot`) le rejette.
  Contradiction canon escaladée architect **#565** (option A reco). Ce
  test n'affirme PAS un pass complet (faux) ni un fail (la SEULE
  non-conformité = G24-11). Il prouve : (a) structurellement valides
  hors G24-11, (b) G24-11 est l'unique gap (borné, tracé).
  """
  use ExUnit.Case, async: true

  # GELÉ (BL — Memory-X frozen 2026-06-19) : conformité v2.5 des cap-profiles monk, désormais ARCHIVÉS
  # (`priv/canon/_frozen-monks/`, hors boucle de boot). Ré-activer au re-home de Memory-X (per-project +
  # system-wide sous lcars). cf. work/backlog.md.
  @moduletag skip:
               "Memory-X gelé (BL) — cap-profiles monks archivés ; ré-activer au re-home per-project"

  @schema_path Path.join([__DIR__, "..", "priv", "cap_profile", "schema", "cap-profile-v2.5.json"])
  @monks_dir Path.join([__DIR__, "..", "priv", "cap_profile", "canon", "cap-profiles", "monks"])

  setup_all do
    schema = @schema_path |> File.read!() |> Jason.decode!() |> ExJsonSchema.Schema.resolve()
    {:ok, schema: schema}
  end

  test "16 profils présents (5 alpha + 10 beta + archivist) + 2 registries" do
    alpha = Path.wildcard(Path.join(@monks_dir, "monk-alpha-*.yaml"))
    beta = Path.wildcard(Path.join(@monks_dir, "monk-beta-*.yaml"))
    assert length(alpha) == 5, "5 monk-alpha attendus, vu #{length(alpha)}"
    assert length(beta) == 10, "10 monk-beta attendus, vu #{length(beta)}"
    assert File.exists?(Path.join(@monks_dir, "archivist.yaml"))
    assert File.exists?(Path.join(@monks_dir, "alpha.yaml"))
    assert File.exists?(Path.join(@monks_dir, "beta.yaml"))
  end

  test "monks/archivist : PLEINEMENT conformes v2.5 (post ADR #565 verdict B)",
       %{schema: schema} do
    # ADR #565 verdict B : les monks utilisent `spec.knowledge.sp_template`
    # (pod permanent), PAS `spec.invocation.subagent_template` (dispatch
    # one-shot, G24-11). G24-11 inchangé mais N/A pour les monks → ils
    # valident désormais ENTIÈREMENT. (Ancienne version assertait l'échec
    # G24-11 = gap pré-arbitrage, maintenant résolu.)
    profiles =
      Path.wildcard(Path.join(@monks_dir, "monk-*.yaml")) ++
        [Path.join(@monks_dir, "archivist.yaml")]

    for f <- profiles do
      cp = YamlElixir.read_from_file!(f)

      assert ExJsonSchema.Validator.validate(schema, cp) == :ok,
             "#{Path.basename(f)} : non-conforme post #565-B — #{inspect(ExJsonSchema.Validator.validate(schema, cp))}"

      refute get_in(cp, ["spec", "invocation", "subagent_template"]),
             "#{Path.basename(f)} : subagent_template résiduel (doit être knowledge.sp_template, #565-B)"

      assert get_in(cp, ["spec", "knowledge", "sp_template"]),
             "#{Path.basename(f)} : knowledge.sp_template manquant (#565-B)"
    end
  end

  test "registries alpha.yaml/beta.yaml : monks bien formés (kind retiré R0.8-brick2)" do
    for {file, svc, n} <- [{"alpha.yaml", "alpha", 5}, {"beta.yaml", "beta", 10}] do
      reg = YamlElixir.read_from_file!(Path.join(@monks_dir, file))
      # R0.8-brick2 : `kind: MemoryRegistry` retiré (1 seul kind par dossier).
      assert reg["metadata"]["service"] == svc
      monks = reg["spec"]["monks"]
      assert length(monks) == n, "#{file} : #{n} monks attendus, vu #{length(monks)}"

      for m <- monks do
        assert is_binary(m["name"]) and m["name"] != ""
        assert is_list(m["corpus_paths"]) and m["corpus_paths"] != []
        assert is_integer(m["token_budget"])
        assert is_binary(m["persona_hint"])
        assert m["version"] == "v2.5"
      end
    end
  end

  test "noms monks registry == noms cap-profiles (cohérence monk_instance)" do
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
             "#{file} : registry names #{inspect(reg_names)} ≠ cap-profile instances #{inspect(cp_instances)}"
    end
  end
end
