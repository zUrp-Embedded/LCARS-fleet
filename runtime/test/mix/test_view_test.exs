defmodule Mix.Tasks.Lcars.Test.ViewTest do
  @moduledoc """
  Tests tokenizer classification, preserved line numbering, static loop outlines
  and the dotted Mix command name.

  The suite scan checks reparsing and textual recomposition with original non-code
  lines. It does not compare executable ASTs or cover code lost from inline-comment
  lines. The fixture distinguishes hashes in ordinary heredocs from doc literals
  and actual comments.
  """
  use ExUnit.Case, async: true

  alias Mix.Tasks.Lcars.Test.View, as: TestView

  @fixture ~S'''
  defmodule FixtureTest do
    @moduledoc """
    A doc heredoc: prose, not code.
    # this hash is inside the doc, not a comment
    """
    use ExUnit.Case

    # a real comment
    @script """
    #!/bin/sh
    # a hash inside a heredoc: CODE, not a comment
    echo ok
    """

    describe "group" do
      test "plain" do
        assert @script =~ "echo"
      end

      for n <- [1, 2] do
        test "looped #{n}" do
          assert n > 0
        end
      end
    end

    property "outside" do
      assert true
    end
  end
  '''

  test "a `#` inside a heredoc is code, a `#` inside a doc is doc, a `# comment` is comment" do
    {kinds, lines, _n} = TestView.classify(@fixture)
    at = fn needle -> Enum.find_index(lines, &String.contains?(&1, needle)) + 1 end

    assert kinds[at.("hash inside a heredoc")] == :code
    assert kinds[at.("hash is inside the doc")] == :doc
    assert kinds[at.("a real comment")] == :comment
    assert kinds[at.("echo ok")] == :code
  end

  test "the code view keeps the numbering: the blanked lines are still there, empty" do
    original = String.split(@fixture, "\n")
    projected = @fixture |> TestView.code() |> String.split("\n")

    assert length(projected) == length(original)

    assert Enum.at(projected, Enum.find_index(original, &String.contains?(&1, "a real comment"))) ==
             ""

    assert {:ok, _} = Code.string_to_quoted(TestView.code(@fixture))
  end

  test "the plan reads witnesses declared inside a `for`, and marks them" do
    plan = TestView.plan(@fixture)
    names = Enum.map(plan, fn {_l, _d, kind, name, in_for} -> {kind, name, in_for} end)

    assert {:describe, "group", false} in names
    assert {:test, "plain", false} in names
    assert {:test, "looped \#{}", true} in names
    assert {:property, "outside", false} in names
    assert Enum.count(plan, &elem(&1, 4)) == 1
  end

  test "prose attaches each comment to the nearest witness above it, or to the header" do
    prose = TestView.prose(@fixture)
    assert [{_line, nil, "# a real comment"}] = prose
  end

  @tag :tmp_dir
  test "check is lossless on the fixture, and counts what it blanked", %{tmp_dir: tmp} do
    path = Path.join(tmp, "fixture_test.exs")
    File.write!(path, @fixture)
    assert %{reparse: :ok, recomposed: true, counts: counts} = TestView.check(path)
    assert counts[:comment] == 1
    assert counts[:doc] == 4
  end

  test "check is lossless on every *_test.exs of this tree" do
    files = Path.wildcard(Path.expand("../**/*_test.exs", __DIR__))
    assert files != []

    bad =
      files
      |> Enum.map(&TestView.check/1)
      |> Enum.reject(&(&1.reparse == :ok and &1.recomposed))
      |> Enum.map(& &1.path)

    assert bad == [], "the projection is not lossless on: #{inspect(bad)}"
  end

  # Invoke by command name: direct module calls cannot detect Mix naming errors.
  @tag :tmp_dir
  test "the task answers to the name the docs give it: `mix lcars.test.view`", %{tmp_dir: tmp} do
    path = Path.join(tmp, "fixture_test.exs")
    File.write!(path, @fixture)
    Mix.shell(Mix.Shell.Process)

    try do
      Mix.Task.reenable("lcars.test.view")
      Mix.Task.run("lcars.test.view", ["plan", path])
    after
      Mix.shell(Mix.Shell.IO)
    end

    lines = collect_shell()
    assert Enum.any?(lines, &String.contains?(&1, ~s(test "plain")))
    assert Enum.any?(lines, &String.contains?(&1, "[for]"))
  end

  defp collect_shell(acc \\ []) do
    receive do
      {:mix_shell, :info, [msg]} -> collect_shell([msg | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
