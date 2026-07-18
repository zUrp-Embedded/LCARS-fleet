defmodule Fleet.Coord.PoliciesLoadFailloudTest do
  # async: false — mute la config globale :policies_path.
  use ExUnit.Case, async: false

  alias Fleet.Coord.Policies

  setup do
    prev = Application.get_env(:fleet_coord, :policies_path)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:fleet_coord, :policies_path, prev),
        else: Application.delete_env(:fleet_coord, :policies_path)
    end)

    :ok
  end

  # F-051 (Pattern A crash-boot, révision F025) : un coord-policies.yaml absent/malformé NE dégrade
  # plus en table vide (« coord vert mais toute décision/escalade :not_found »). Artefact de deploy
  # cassé → raise au boot. Le raise précède le `:persistent_term.put` → l'état chargé au boot reste
  # intact (les tests qui suivent gardent une table valide).
  test "F-051 : policies absentes → raise (plus de table vide DÉGRADÉE)" do
    Application.put_env(:fleet_coord, :policies_path, "/nonexistent/coord-policies-xyz.yaml")

    assert_raise RuntimeError, ~r/missing\/unreadable/, fn ->
      Policies.init_policies!()
    end
  end

  test "F-051 : policies malformées (pas une map) → raise" do
    tmp = Path.join(System.tmp_dir!(), "coord-pol-#{System.unique_integer([:positive])}.yaml")
    File.write!(tmp, "- just\n- a\n- list\n")
    on_exit(fn -> File.rm(tmp) end)

    Application.put_env(:fleet_coord, :policies_path, tmp)

    assert_raise RuntimeError, ~r/malformed/, fn ->
      Policies.init_policies!()
    end
  end

  # Finding 13 : une MAP YAML valide mais structurellement INVALIDE vs `coord-policies-v1.json` (ici un
  # mapping sans `action`) doit FAIL-FAST au boot — avant, le code n'acceptait que « est une map » et la
  # validation schema ne tournait qu'en test, jamais dans `init_policies!/0`. Le raise précède le
  # `:persistent_term.put` → la table chargée au boot reste intacte (les autres tests gardent une table valide).
  test "Finding 13 : map valide mais INVALIDE vs schema (mapping sans action) → raise fail-loud" do
    tmp = Path.join(System.tmp_dir!(), "coord-pol-bad-#{System.unique_integer([:positive])}.yaml")
    File.write!(tmp, "mappings:\n  \"audit.proven\":\n    escalation_path: []\n")
    on_exit(fn -> File.rm(tmp) end)

    Application.put_env(:fleet_coord, :policies_path, tmp)

    assert_raise RuntimeError, ~r/INVALID vs coord-policies-v1\.json/, fn ->
      Policies.init_policies!()
    end
  end
end
