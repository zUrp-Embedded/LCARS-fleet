defmodule Mix.Tasks.Lcars.TestViewTest do
  @moduledoc """
  The projection must be LOSSLESS, or it is a way to miss something while feeling thorough.

  Two halves. The fixture half pins the three traps a regex-based strip falls into — a `#` inside
  a heredoc, a `@moduledoc` heredoc, a witness declared inside a `for` — on a file written for
  that. The suite half runs `check` on every `*_test.exs` of this tree: the code view must
  reparse and code + prose must recompose the original, file by file. The day a construct the
  tokenizer classifies differently enters the suite, this is where it shows.
  """
  use ExUnit.Case, async: true

  alias Mix.Tasks.Lcars.TestView

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

  # THE SUITE HALF. Every witness of this tree, projected and recomposed — the only proof that the
  # instrument can be trusted on what it will actually be used on.
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
end
