defmodule Fleet.SPBuilderImageTest do
  @moduledoc """
  The SP half of the proven-good image: fragments/templates/drafts frozen at boot — the prompts
  pods receive stop tracking the live disk once published.
  """
  use ExUnit.Case, async: false

  alias Fleet.SPBuilder.Image

  @moduletag :tmp_dir

  defp write_sp_canon(tmp) do
    File.mkdir_p!(Path.join(tmp, "bundles/tdd"))
    File.mkdir_p!(Path.join(tmp, "templates"))
    File.mkdir_p!(Path.join(tmp, "drafts"))
    File.write!(Path.join(tmp, "bundles/tdd/sp.md"), "# tdd v1\n")
    File.write!(Path.join(tmp, "templates/subagent-spec-reviewer.md"), "# tpl v1\n")
    File.write!(Path.join(tmp, "drafts/agent-probe-base.md"), "# draft v1\n")
    File.write!(Path.join(tmp, "drafts/protocole-user-worker.md"), "# proto\n")
    tmp
  end

  setup %{tmp_dir: tmp} do
    write_sp_canon(tmp)
    Fleet.TestEnv.put_env_restoring(:fleet_sp_builder, :modop_root, Path.join(tmp, "bundles"))

    Fleet.TestEnv.put_env_restoring(
      :fleet_sp_builder,
      :subagent_template_root,
      Path.join(tmp, "templates")
    )

    Fleet.TestEnv.put_env_restoring(:fleet_sp_builder, :sp_drafts_root, Path.join(tmp, "drafts"))
    on_exit(fn -> Image.unpublish() end)
    :ok
  end

  test "EPOCH CLOSURE: a fragment edited after publish! is invisible to the composer", %{
    tmp_dir: tmp
  } do
    :ok = Image.publish!()
    File.write!(Path.join(tmp, "bundles/tdd/sp.md"), "# tdd v2 MUTATED\n")

    profile = %Fleet.CapProfile{kind: "CapabilityProfile", spec: %{}, metadata: %{"name" => "x"}}
    assert {:ok, %{sp_md: sp}} = Fleet.SPBuilder.compose(profile, ["tdd"])
    assert sp =~ "tdd v1"
    refute sp =~ "MUTATED"

    # Restart-republish → the new epoch.
    Image.unpublish()
    assert {:ok, %{sp_md: sp2}} = Fleet.SPBuilder.compose(profile, ["tdd"])
    assert sp2 =~ "MUTATED"
  end

  test "the Assets draft rail serves the image (closed world for role drafts)", %{tmp_dir: tmp} do
    :ok = Image.publish!()
    File.write!(Path.join(tmp, "drafts/agent-probe-base.md"), "# draft v2 MUTATED\n")

    assert {:ok, "# draft v1\n"} = Image.draft("probe")
    # A role whose draft is absent from the image = the hard no-SP-no-pod refusal, closed world.
    assert :not_found = Image.draft("ghost")
  end

  test "proven-good or do not boot: an empty artifact root makes publish! raise", %{tmp_dir: tmp} do
    File.rm_rf!(Path.join(tmp, "templates"))
    File.mkdir_p!(Path.join(tmp, "templates"))
    assert_raise RuntimeError, ~r/no artifact matches/, fn -> Image.publish!() end
  end

  test "proven-good or do not boot: an empty artifact file makes publish! raise", %{tmp_dir: tmp} do
    File.write!(Path.join(tmp, "bundles/tdd/sp.md"), "")
    assert_raise RuntimeError, ~r/empty/, fn -> Image.publish!() end
  end
end
