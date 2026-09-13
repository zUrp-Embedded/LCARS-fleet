defmodule Mix.Tasks.Lcars.Contracts.ForgeFieldsCheckTest do
  @moduledoc """
  Tests forge-field inventory and exposed-mutation scanners against synthetic
  sources and the real tree. Checker/tooling mentions must not count as product
  readers; deliberately unread fields retain an explicit rationale-debt count.

  The fixtures exercise recognised text shapes, not actual response consumption
  or execution of exposed forge mutations.
  """
  use ExUnit.Case, async: true

  alias Mix.Tasks.Lcars.Contracts.Check.Tools

  @moduletag :tmp_dir

  defp tree(files) do
    root = Fleet.TestEnv.tmp_path("forge_fields")
    lib = Path.join(root, "lib/fleet")
    File.mkdir_p!(lib)
    Enum.each(files, fn {name, body} -> File.write!(Path.join(lib, name), body) end)
    on_exit(fn -> File.rm_rf!(root) end)
    root
  end

  describe "against the real repo" do
    test "it passes, and the note says what it actually measured" do
      result = Tools.check_forge_fields_read(File.cwd!())

      assert result.status == :pass
      assert result.note =~ "fields read"
      assert result.note =~ "deliberately"
    end

    test "the allowlist ADMITS when it has no reason — a queue is not an answer" do
      assert Tools.check_forge_fields_read(File.cwd!()).note =~ "no reason recorded"
    end
  end

  describe "the instrument answers for itself" do
    test "a tree with no lib/ FAILS as broken — it never passes by measuring nothing" do
      result =
        Tools.check_forge_fields_read(Fleet.TestEnv.tmp_path("nowhere"))

      assert result.status == :fail
      assert hd(result.evidence) =~ "INSTRUMENT BROKEN"
    end

    test "a field that LOST its last reader is named" do
      result = Tools.check_forge_fields_read(tree(%{"a.ex" => "defmodule A do\\nend\\n"}))

      assert result.status == :fail
      assert hd(result.evidence) =~ "LOST their last reader"
      assert hd(result.evidence) =~ "state"
    end
  end

  describe "the trap: the checker must not read its own allowlist" do
    test "gate tooling is excluded — a field named by a mix task is not the product reading it" do
      # Keep allowlist mentions outside the product-reader population.
      root =
        tree(%{
          "real.ex" =>
            Enum.map_join(
              ~w(state merged number title body labels commit_id
                                                  dismissed login head base sha assignees full_name
                                                  submitted_at created_at updated_at),
              "\\n",
              &~s(  "#{&1}")
            )
        })

      File.mkdir_p!(Path.join(root, "lib/mix/tasks"))
      File.write!(Path.join(root, "lib/mix/tasks/fake.ex"), ~s(  "closed_at"\\n  "html_url"\\n))

      result = Tools.check_forge_fields_read(root)

      assert result.status == :pass, "evidence: #{inspect(result.evidence)}"
    end
  end

  describe "probe n°4 — a gesture with no door" do
    test "the real repo passes, and the note gives the two-column split" do
      result = Tools.check_forge_mutations_exposed(File.cwd!())

      assert result.status == :pass
      assert result.note =~ "reachable by a tool"
      assert result.note =~ "runtime-only ON RECORD"
    end

    test "a delegation it cannot parse FAILS as broken — never a pass by measuring nothing" do
      root = Fleet.TestEnv.tmp_path("nodeleg")
      File.mkdir_p!(root)
      on_exit(fn -> File.rm_rf!(root) end)

      result = Tools.check_forge_mutations_exposed(root)

      assert result.status == :fail
      assert hd(result.evidence) =~ "INSTRUMENT BROKEN"
    end

    test "a delegation reaching NO mutation is broken too, not compliant" do
      root = Fleet.TestEnv.tmp_path("emptydeleg")
      File.mkdir_p!(Path.join(root, "lib/fleet/mcp/pod_tools"))
      on_exit(fn -> File.rm_rf!(root) end)

      File.write!(
        Path.join(root, "lib/fleet/mcp/pod_tools/delegation.ex"),
        "defmodule D do\n  def nothing, do: :ok\nend\n"
      )

      result = Tools.check_forge_mutations_exposed(root)

      assert result.status == :fail
      assert hd(result.evidence) =~ "INSTRUMENT BROKEN"
      assert hd(result.evidence) =~ "seam calls parsed"
    end
  end
end
