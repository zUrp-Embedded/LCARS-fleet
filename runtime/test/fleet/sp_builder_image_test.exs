defmodule Fleet.SPBuilderImageTest do
  @moduledoc """
  Checks frozen artifact reads, closed-world misses and source drift using temporary
  overrides plus shipped system fallbacks. Fingerprints are exercised with edits made
  after publication, not concurrent mutation during its separate read passes.
  """
  use ExUnit.Case, async: false

  alias Fleet.Spawner.Pod.Assets
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
    File.write!(Path.join(tmp, "drafts/protocole-user-human.md"), "# human proto\n")
    tmp
  end

  # `read_protocole_user/1` selects on the cap-profile's `interlocutor`; these tests are about the
  # image, so they use the machine-facing shape and let the branch itself be tested where it lives.
  defp fleet_facing do
    %Fleet.CapProfile{
      kind: "CapabilityProfile",
      metadata: %{"name" => "probe"},
      spec: %{"interlocutor" => "fleet"}
    }
  end

  setup %{tmp_dir: tmp} do
    write_sp_canon(tmp)

    Fleet.TestEnv.put_env_restoring(
      :lcars_fleet,
      :sp_builder_modop_root,
      Path.join(tmp, "bundles")
    )

    Fleet.TestEnv.put_env_restoring(
      :lcars_fleet,
      :sp_builder_subagent_template_root,
      Path.join(tmp, "templates")
    )

    Fleet.TestEnv.put_env_restoring(
      :lcars_fleet,
      :sp_builder_sp_drafts_root,
      Path.join(tmp, "drafts")
    )

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

    # Unpublish switches this read to live disk; no restart or republish occurs here.
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
    # Use the shared protocol override. Reading changed bytes after unpublish confirms that
    # the frozen assertion is not accidentally reading a different file.
    custom = Path.join(tmp, "custom-protocole.md")
    File.write!(custom, "# custom proto\n")
    Fleet.TestEnv.put_env_restoring(:lcars_fleet, :spawner_protocole_user_path, custom)

    :ok = Image.publish!()
    File.write!(custom, "# custom MUTATED\n")

    assert {:ok, "# custom proto\n"} =
             Assets.read_protocole_user(fleet_facing())

    # The unpublished disk fallback can see the mutation.
    Image.unpublish()
    assert {:ok, served} = Assets.read_protocole_user(fleet_facing())
    assert served =~ "MUTATED"
  end

  test "EPOCH CLOSURE: an EEx template edited after publish! is invisible to the composer", %{
    tmp_dir: tmp
  } do
    # Historical title overstates the fixture: this replaces the image directly and checks
    # its consumption/miss handling. The temporary EEx file is not wired into publication.
    tpl_root = Path.join(tmp, "eex")
    File.mkdir_p!(tpl_root)
    src = Path.join(tpl_root, "sp_template.eex")
    File.write!(src, "MARKER-V1\n")

    # Supply a known source through the image test seam.
    :ok = Image.publish!()
    published = Image.published()

    Image.republish(put_in(published, [:templates, "sp_template.eex"], "MARKER-V1\n"))

    profile = %Fleet.CapProfile{kind: "CapabilityProfile", spec: %{}, metadata: %{"name" => "x"}}
    assert {:ok, %{sp_md: sp}} = Fleet.SPBuilder.compose(profile, ["tdd"])
    assert sp == "MARKER-V1\n"

    # Closed world: a template the image does not carry is a loud error, never a disk re-read.
    Image.republish(put_in(published, [:templates], %{}))

    assert {:error, {:template_missing_from_image, "sp_template.eex"}} =
             Fleet.SPBuilder.compose(profile, ["tdd"])
  end

  test "a BORROWED SP absent from a published image is a closed-world error, not a disk read", %{
    tmp_dir: tmp
  } do
    # Write the borrowed role's draft after publication: a readable disk file distinguishes
    # an image miss from a disk fallback. Override only drafts so other artifact prerequisites
    # remain available and cannot mask the property under test.
    drafts = Path.join(tmp, "drafts")
    File.mkdir_p!(drafts)
    Fleet.TestEnv.put_env_restoring(:lcars_fleet, :sp_builder_sp_drafts_root, drafts)
    :ok = Image.publish!()

    profile = %Fleet.CapProfile{
      kind: "CapabilityProfile",
      spec: %{"systemPrompt" => "late-role"},
      metadata: %{"name" => "x"}
    }

    assert {:error, {:agent_draft_missing, _, _}} =
             Assets.read_agent_draft(profile)

    File.write!(
      Path.join(drafts, "agent-late-role-base.md"),
      "# an SP the epoch never admitted\n"
    )

    assert File.exists?(Path.join(drafts, "agent-late-role-base.md")),
           "fixture must be readable on disk"

    assert {:error, {:agent_draft_missing, _, _}} =
             Assets.read_agent_draft(profile)

    # Republishing admits the new draft into the image, without a daemon restart.
    Image.unpublish()
    :ok = Image.publish!()

    assert {:ok, content} = Assets.read_agent_draft(profile)
    assert content =~ "an SP the epoch never admitted"
  end

  test "systemPrompt: a role REUSES another role's SP instead of copying it" do
    # A renamed role can reuse the same prompt bytes without maintaining a duplicate draft.
    :ok = Image.publish!()

    renamed = %Fleet.CapProfile{
      kind: "CapabilityProfile",
      spec: %{"systemPrompt" => "architect"},
      metadata: %{"name" => "chef-de-projet"}
    }

    assert {:ok, borrowed} = Assets.read_agent_draft(renamed)

    own = %Fleet.CapProfile{
      kind: "CapabilityProfile",
      spec: %{},
      metadata: %{"name" => "architect"}
    }

    assert {:ok, ^borrowed} = Assets.read_agent_draft(own),
           "the renamed role must receive the SAME bytes, not a lookalike"
  end

  test "systemPrompt is a ROLE NAME: a path is refused as an invalid role, never resolved" do
    # The Assets consumer validates the borrowed role name before constructing a path.
    :ok = Image.publish!()

    for hostile <- ["../../../etc/passwd", "role\0", "sub/dir", ""] do
      profile = %Fleet.CapProfile{
        kind: "CapabilityProfile",
        spec: %{"systemPrompt" => hostile},
        metadata: %{"name" => "x"}
      }

      assert {:error, {:agent_draft_invalid_role, ^hostile}} =
               Assets.read_agent_draft(profile),
             "systemPrompt=#{inspect(hostile)} must be refused as a role, not resolved as a path"
    end
  end

  describe "drift — the epoch knows whether the disk still matches what it validated" do
    test "a source edited after publish! is REPORTED (the silence is the defect, not the copy)",
         %{
           tmp_dir: tmp
         } do
      :ok = Image.publish!()
      assert {:ok, []} = Image.drift()

      edited = Path.join(tmp, "bundles/tdd/sp.md")
      File.write!(edited, "# tdd v2 MUTATED\n")

      assert {:ok, [{^edited, :modified}]} = Image.drift()
      # Reporting drift must not switch the reader to changed disk bytes.
      profile = %Fleet.CapProfile{
        kind: "CapabilityProfile",
        spec: %{},
        metadata: %{"name" => "x"}
      }

      assert {:ok, %{sp_md: sp}} = Fleet.SPBuilder.compose(profile, ["tdd"])
      assert sp =~ "tdd v1"
    end

    test "a source DELETED after publish! is reported as :vanished, distinctly", %{tmp_dir: tmp} do
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

    test "the fingerprint covers EVERY imaged section, both protocols included", %{
      tmp_dir: tmp
    } do
      # Edit each listed fixture class in turn; despite the title, this list omits EEx templates.
      :ok = Image.publish!()

      for rel <- [
            "bundles/tdd/sp.md",
            "templates/subagent-spec-reviewer.md",
            "drafts/agent-probe-base.md",
            "drafts/protocole-user-worker.md",
            "drafts/protocole-user-human.md"
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

  # Empty subagent corpus is allowed. The following case checks an empty selected file;
  # required artifact classes can still fall back to system and are not emptied by this fixture.
  test "une racine de subagent-templates VIDE ne bloque PLUS le boot (aucun rôle n'en déclare)",
       %{tmp_dir: tmp} do
    File.rm_rf!(Path.join(tmp, "templates"))
    File.mkdir_p!(Path.join(tmp, "templates"))
    assert :ok = Image.publish!()
  end

  test "proven-good or do not boot: an empty artifact file makes publish! raise", %{tmp_dir: tmp} do
    File.write!(Path.join(tmp, "bundles/tdd/sp.md"), "")
    assert_raise RuntimeError, ~r/empty/, fn -> Image.publish!() end
  end

  # Broken symlinks reproduce listed-but-unreadable inputs without a timing race. Assert the
  # named RuntimeError, distinguishing it from a generic File.Error; no concurrent writer is used.
  describe "6-029 — « liste puis illisible » se nomme, aux TROIS lecteurs" do
    test "lecteur de repertoire (drafts)", %{tmp_dir: tmp} do
      File.ln_s!("/nonexistent/gone", Path.join(tmp, "drafts/agent-ghost-base.md"))

      assert_raise RuntimeError,
                   ~r/artifact .*agent-ghost-base\.md was listed, then unreadable/,
                   fn ->
                     Image.publish!()
                   end
    end

    test "lecteur de protocole (chemin resolu, pas glob)", %{tmp_dir: tmp} do
      ghost = Path.join(tmp, "proto-fantome.md")
      File.ln_s!("/nonexistent/gone", ghost)
      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :spawner_protocole_user_path, ghost)

      assert_raise RuntimeError,
                   ~r/worker protocol .*proto-fantome\.md was listed, then unreadable/,
                   fn -> Image.publish!() end
    end

    # A shadowed system draft skips the content read but reaches the fingerprint pass,
    # isolating that reader's failure handling.
    test "empreinte de sources — un chemin MASQUE que l'image n'a pas lu", %{tmp_dir: tmp} do
      sys = Path.join(tmp, "sysroot")
      File.mkdir_p!(Path.join(sys, "sp_builder/sp_drafts"))
      File.mkdir_p!(Path.join(sys, "sp_builder/templates"))
      File.write!(Path.join(sys, "sp_builder/templates/probe.eex"), "x\n")

      # MEME NOM que le draft business : masque a la lecture, present a l'empreinte.
      File.ln_s!("/nonexistent/gone", Path.join(sys, "sp_builder/sp_drafts/agent-probe-base.md"))
      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :catalogue_system_root, sys)

      assert_raise RuntimeError,
                   ~r/fingerprinted source .*sysroot.*agent-probe-base\.md was listed, then unreadable/,
                   fn -> Image.publish!() end
    end
  end
end
