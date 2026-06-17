defmodule Fleet.Coord.PoliciesF051Test do
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

    assert_raise RuntimeError, ~r/absent\/illisible/, fn ->
      Policies.init_policies!()
    end
  end

  test "F-051 : policies malformées (pas une map) → raise" do
    tmp = Path.join(System.tmp_dir!(), "coord-pol-#{System.unique_integer([:positive])}.yaml")
    File.write!(tmp, "- just\n- a\n- list\n")
    on_exit(fn -> File.rm(tmp) end)

    Application.put_env(:fleet_coord, :policies_path, tmp)

    assert_raise RuntimeError, ~r/malformé/, fn ->
      Policies.init_policies!()
    end
  end
end
