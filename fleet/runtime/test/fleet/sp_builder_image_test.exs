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

  test "EPOCH CLOSURE: the worker protocole-user edited after publish! is invisible to Assets", %{
    tmp_dir: tmp
  } do
    # This file redefines the pod's trigger keywords: unimaged, a mid-life edit changed what `yop`
    # MEANS for the next pod while the image version still claimed a closed epoch.
    #
    # Driven through the `:protocole_user_path` override, which is the ONE resolution the image and
    # the disk fallback share — so the same test proves both halves: the image freezes what the
    # consumer would have read (an image freezing the bundled default while the consumer read the
    # override would let the override escape the epoch in silence), and unpublished, the mutation
    # DOES show, which is what makes the frozen assertion above evidence rather than coincidence.
    custom = Path.join(tmp, "custom-protocole.md")
    File.write!(custom, "# custom proto\n")
    Fleet.TestEnv.put_env_restoring(:fleet_spawner, :protocole_user_path, custom)

    :ok = Image.publish!()
    File.write!(custom, "# custom MUTATED\n")

    assert {:ok, "# custom proto\n"} = Fleet.Spawner.Pod.Assets.read_protocole_user()

    # Restart-republish → the new epoch (and proof the mutation was reachable all along).
    Image.unpublish()
    assert {:ok, served} = Fleet.Spawner.Pod.Assets.read_protocole_user()
    assert served =~ "MUTATED"
  end

  test "EPOCH CLOSURE: an EEx template edited after publish! is invisible to the composer", %{
    tmp_dir: tmp
  } do
    # A template is the SHAPE of every prompt the fleet emits. It was the last live read left, and
    # the one whose drift would be hardest to attribute to a file nobody touched on purpose.
    tpl_root = Path.join(tmp, "eex")
    File.mkdir_p!(tpl_root)
    src = Path.join(tpl_root, "sp_template.eex")
    File.write!(src, "MARKER-V1\n")

    # The template root is derived from priv (no knob): drive the image directly to prove the
    # consumption path, which is what the finding is about.
    :ok = Image.publish!()
    published = Image.published()

    :persistent_term.put(
      {Image, :image},
      put_in(published, [:templates, "sp_template.eex"], "MARKER-V1\n")
    )

    profile = %Fleet.CapProfile{kind: "CapabilityProfile", spec: %{}, metadata: %{"name" => "x"}}
    assert {:ok, %{sp_md: sp}} = Fleet.SPBuilder.compose(profile, ["tdd"])
    assert sp == "MARKER-V1\n"

    # Closed world: a template the image does not carry is a loud error, never a disk re-read.
    :persistent_term.put({Image, :image}, put_in(published, [:templates], %{}))

    assert {:error, {:template_missing_from_image, "sp_template.eex"}} =
             Fleet.SPBuilder.compose(profile, ["tdd"])
  end

  test "a role SP base absent from a published image is a closed-world error, not a disk read", %{
    tmp_dir: tmp
  } do
    # `spec.systemPrompt` is a dormant extension point (no canon profile declares one), so the root
    # is legitimately empty and publish! must NOT raise on it. But once published, a profile naming
    # a base the image lacks must fail loud — silently reading the live file is what reopened the
    # epoch precisely where a deployment had extended it.
    #
    # The fixture is the DISCRIMINATING one, and it has to be: the base is written to disk AFTER the
    # publish, so it EXISTS and is readable. An image-first lookup refuses it (closed world); a disk
    # read would serve it. Asserting the error against a file that is missing on disk too would pass
    # under either implementation and prove nothing.
    Fleet.TestEnv.put_env_restoring(:fleet_sp_builder, :sp_role_root, tmp)
    :ok = Image.publish!()
    assert :not_found = Image.sp_role_base("late-role.md")

    File.write!(Path.join(tmp, "late-role.md"), "# a base the epoch never admitted\n")
    assert File.exists?(Path.join(tmp, "late-role.md")), "fixture must be readable on disk"

    profile = %Fleet.CapProfile{
      kind: "CapabilityProfile",
      spec: %{"systemPrompt" => "late-role.md"},
      metadata: %{"name" => "x"}
    }

    assert {:error, {:sp_role_path_missing, _}} = Fleet.SPBuilder.compose(profile, ["tdd"])

    # Restart-republish → the new epoch admits it, which is the only way in.
    Image.unpublish()
    :ok = Image.publish!()
    assert {:ok, %{sp_md: sp}} = Fleet.SPBuilder.compose(profile, ["tdd"])
    assert sp =~ "a base the epoch never admitted"
  end

  describe "drift — the epoch knows whether the disk still matches what it validated" do
    test "a source edited after publish! is REPORTED (the silence is the defect, not the copy)",
         %{
           tmp_dir: tmp
         } do
      # Serving the frozen copy is the DEFENCE: bytes that appear on disk after boot never reach an
      # agent. Saying nothing about the divergence was the defect — an edit to the deployed program's
      # prompt material was absorbed as a non-event by the very mechanism guarding it.
      :ok = Image.publish!()
      assert {:ok, []} = Image.drift()

      edited = Path.join(tmp, "bundles/tdd/sp.md")
      File.write!(edited, "# tdd v2 MUTATED\n")

      assert {:ok, [{^edited, :modified}]} = Image.drift()
      # And the pod still gets the proven-good content — detection never becomes degradation.
      profile = %Fleet.CapProfile{
        kind: "CapabilityProfile",
        spec: %{},
        metadata: %{"name" => "x"}
      }

      assert {:ok, %{sp_md: sp}} = Fleet.SPBuilder.compose(profile, ["tdd"])
      assert sp =~ "tdd v1"
    end

    test "a source DELETED after publish! is reported as :vanished, distinctly", %{tmp_dir: tmp} do
      # A different operator story from an edit (a botched deploy, not a botched edit), so it must
      # not collapse into the same word.
      :ok = Image.publish!()
      gone = Path.join(tmp, "drafts/agent-probe-base.md")
      File.rm!(gone)

      assert {:ok, [{^gone, :vanished}]} = Image.drift()
    end

    test "an untouched deployment reports NO drift — the check is not a permanent alarm", %{
      tmp_dir: _tmp
    } do
      :ok = Image.publish!()
      assert {:ok, []} = Image.drift()
    end

    test "no image published → :unpublished (nothing was validated, nothing can have drifted)" do
      Image.unpublish()
      assert :unpublished = Image.drift()
    end

    test "the fingerprint covers EVERY imaged section, including the worker protocol", %{
      tmp_dir: tmp
    } do
      # A section imaged but absent from the fingerprint is material whose drift nobody can see —
      # the exact hole this closes, one level down. Each source is edited in turn and must surface.
      :ok = Image.publish!()

      for rel <- [
            "bundles/tdd/sp.md",
            "templates/subagent-spec-reviewer.md",
            "drafts/agent-probe-base.md",
            "drafts/protocole-user-worker.md"
          ] do
        path = Path.join(tmp, rel)
        original = File.read!(path)
        File.write!(path, original <> "\nMUTATED\n")

        assert {:ok, drifted} = Image.drift()

        assert Enum.any?(drifted, &match?({^path, :modified}, &1)),
               "#{rel} is imaged but invisible to the drift check"

        File.write!(path, original)
      end

      assert {:ok, []} = Image.drift()
    end
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
