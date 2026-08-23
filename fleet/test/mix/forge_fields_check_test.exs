defmodule Mix.Tasks.Lcars.Contracts.ForgeFieldsCheckTest do
  @moduledoc """
  Probe n°1 of the 2026-08-04 pattern hunt, as a wall — with the trap it fell into on its first run.

  The forge hands back whole objects; the code picks what it needs and drops the rest silently. That
  is correct until the dropped part is the answer someone is reconstructing from outside. Measured
  that day: `submitted_at`, `merged_at`, `closed_at`, `html_url` arrived in payloads already fetched
  and no line of `lib/` touched them — the exact list an architect had spent three campaigns
  rebuilding, produced by one command.

  THE TRAP, and it is why this file exists: the allowlist of deliberately-unread fields lives INSIDE
  the checker, so the first run found `"closed_at" =>` in its own source and reported all three as
  read. The instrument measured its own declaration. A wall that reads its allowlist as evidence
  passes forever, and this one is built to catch precisely that shape.
  """
  use ExUnit.Case, async: true

  alias Mix.Tasks.Lcars.Contracts.Check

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
      result = Check.check_forge_fields_read(File.cwd!())

      assert result.status == :pass
      assert result.note =~ "fields read"
      assert result.note =~ "deliberately"
    end

    test "the allowlist ADMITS when it has no reason — a queue is not an answer" do
      # An allowlist that invents rationales is worse than one saying "not decided". The note
      # carries that count so the debt is visible from the gate output, not only from the source.
      assert Check.check_forge_fields_read(File.cwd!()).note =~ "no reason recorded"
    end
  end

  describe "the instrument answers for itself" do
    test "a tree with no lib/ FAILS as broken — it never passes by measuring nothing" do
      result =
        Check.check_forge_fields_read(Fleet.TestEnv.tmp_path("nowhere"))

      assert result.status == :fail
      assert hd(result.evidence) =~ "INSTRUMENT BROKEN"
    end

    test "a field that LOST its last reader is named" do
      # Every inventoried field absent from this crafted tree: the check must say so rather than
      # shrug. One entry is enough to prove the direction.
      result = Check.check_forge_fields_read(tree(%{"a.ex" => "defmodule A do\\nend\\n"}))

      assert result.status == :fail
      assert hd(result.evidence) =~ "LOST their last reader"
      assert hd(result.evidence) =~ "state"
    end
  end

  describe "the trap: the checker must not read its own allowlist" do
    test "gate tooling is excluded — a field named by a mix task is not the product reading it" do
      # `lib/mix/tasks/` is where the allowlist lives. Before the exclusion, `"closed_at" =>` in the
      # checker counted as a reader and the three deliberately-unread fields reported themselves as
      # read: the wall passing on its own declaration.
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

      result = Check.check_forge_fields_read(root)

      # The two names appear in the tree, under `tasks/`. If the exclusion regressed, the check
      # would report them as "now read, remove from the allowlist".
      assert result.status == :pass, "evidence: #{inspect(result.evidence)}"
    end
  end

  describe "probe n°4 — a gesture with no door" do
    test "the real repo passes, and the note gives the two-column split" do
      result = Check.check_forge_mutations_exposed(File.cwd!())

      assert result.status == :pass
      assert result.note =~ "reachable by a tool"
      assert result.note =~ "runtime-only ON RECORD"
    end

    test "a delegation it cannot parse FAILS as broken — never a pass by measuring nothing" do
      root = Fleet.TestEnv.tmp_path("nodeleg")
      File.mkdir_p!(root)
      on_exit(fn -> File.rm_rf!(root) end)

      result = Check.check_forge_mutations_exposed(root)

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

      result = Check.check_forge_mutations_exposed(root)

      assert result.status == :fail
      assert hd(result.evidence) =~ "INSTRUMENT BROKEN"
      assert hd(result.evidence) =~ "seam calls parsed"
    end
  end
end
