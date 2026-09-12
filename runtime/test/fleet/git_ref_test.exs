defmodule Fleet.GitRefTest do
  @moduledoc """
  Supported Git ref grammar, including structural edge cases beyond the ASCII charset check.
  """
  use ExUnit.Case, async: true

  alias Fleet.GitRef

  test "well-formed refs accepted (slash, dots, simple ref)" do
    for ok <- ["main", "feature/work", "lcars/issue-7-engineer", "release-1.2.3", "a"] do
      assert GitRef.valid?(ok), "ref #{inspect(ok)} should be valid"
    end
  end

  test "malformed refs rejected (leading dash, space, .., empty, non-binary)" do
    for bad <- ["-force", "feat ure", "a..b", "..", "../evil", "", ".hidden", "/leading", nil, 42] do
      refute GitRef.valid?(bad), "ref #{inspect(bad)} should be rejected"
    end
  end

  test "R2-06: git check-ref-format rules a charset regex misses" do
    # trailing /, // (empty component), trailing ., .lock suffix, component starting with .
    for bad <- ["foo/", "a//b", "foo.", "foo.lock", "feature/foo.lock", "a/.hidden", "x/"] do
      refute GitRef.valid?(bad), "ref #{inspect(bad)} should be rejected (git check-ref-format)"
    end

    for ok <- ["deliverables/engineer/m-42", "a/b/c", "release-1.2.3"] do
      assert GitRef.valid?(ok), "ref #{inspect(ok)} should stay valid"
    end
  end

  # $ can match before a final newline; \A...\z must reject it before refs reach Git.
  test "#39: terminal newline/control-char rejected (\\A..\\z, not ^..$)" do
    for bad <- ["main\n", "main\r\n", "feature/work\n", "a\n"] do
      refute GitRef.valid?(bad), "ref #{inspect(bad)} (terminal newline) should be rejected"
    end

    for ok <- ["main", "feature/work"] do
      assert GitRef.valid?(ok)
    end
  end
end
