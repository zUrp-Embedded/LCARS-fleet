defmodule Fleet.Forge.ProtocolPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  # Sample round-trips within the generators' domains; not a proof for every accepted input.
  alias Fleet.Forge.Protocol, as: ForgeProtocol

  # Excludes empty tokens, delimiters and newlines; adversarial-token behavior is outside this test.
  defp token do
    string([?a..?z, ?A..?Z, ?0..?9, ?_, ?-], min_length: 1, max_length: 40)
  end

  # Includes 1–3 character hex strings, exercising marker syntax rather than Git resolution.
  defp sha do
    string([?0..?9, ?a..?f], min_length: 1, max_length: 40)
  end

  property "step_run_marker?/1 recognizes ANY marker produced by step_run_marker/2" do
    # This checks recognition, not role extraction or author trust.
    check all(role <- token(), s <- sha()) do
      marker = ForgeProtocol.step_run_marker(role, s)
      assert ForgeProtocol.step_run_marker?(marker)
    end
  end

  property "feature_branch/2 + parse_feature_branch/1: parse . build == identity" do
    check all(n <- positive_integer(), role <- token()) do
      assert {:ok, {^n, ^role}} =
               ForgeProtocol.parse_feature_branch(ForgeProtocol.feature_branch(n, role))
    end
  end

  # Independent cutoff expectation for JSON bytes, not the entire comment's size.
  @result_fence_limit 8192

  # String keys with escaping/fence characters; atom-key conversion is outside this generator.
  defp json_key do
    one_of([
      string(:alphanumeric, min_length: 1, max_length: 6),
      member_of(["a b", "```", "k\"q", "k\\q", "cle-e", "ligne\nsuite", "emoji"])
    ])
  end

  # JSON scalars including backticks, fence-like strings and control characters.
  defp json_scalar do
    one_of([
      string(:printable, max_length: 10),
      member_of([
        "```",
        "```result",
        "\n```",
        "`",
        "\n",
        "\r\n",
        "\t",
        " ",
        "e-aigu",
        "\"",
        "\\"
      ]),
      integer(),
      float(),
      boolean(),
      constant(nil)
    ])
  end

  # Recursive JSON-compatible values; this does not exercise a production pod-to-comment path.
  defp json_value do
    tree(json_scalar(), fn child ->
      one_of([list_of(child, max_length: 3), map_of(json_key(), child, max_length: 3)])
    end)
  end

  defp outputs_gen do
    map_of(json_key(), json_value(), min_length: 1, max_length: 4)
  end

  # Exclude backticks so an earlier result fence cannot win over the generated one.
  defp body_prefix do
    filter(string(:printable, max_length: 30), &(not String.contains?(&1, "`")))
  end

  # Embedded fence-like data must survive JSON escaping without terminating the result fence.
  property "result_block/1 + parse_result_block/1: parse . build == identity (under the limit)" do
    check all(
            outputs <-
              filter(outputs_gen(), &(byte_size(Jason.encode!(&1)) <= @result_fence_limit)),
            prefix <- body_prefix(),
            max_runs: 200
          ) do
      body = prefix <> ForgeProtocol.result_block(outputs)

      assert String.contains?(body, "```result"), "under the limit, the block MUST be a fence"
      assert {:ok, ^outputs} = ForgeProtocol.parse_result_block(body)
    end
  end

  # Oversized output becomes a note, so no truncated or partial map is presented as a result.
  property "result_block/1: beyond the limit → note, no fence, and parse refuses" do
    check all(
            pad <- integer((@result_fence_limit + 8)..(@result_fence_limit + 800)),
            key <- string(:alphanumeric, min_length: 1, max_length: 6),
            prefix <- body_prefix(),
            max_runs: 30
          ) do
      outputs = %{key => String.duplicate("x", pad)}
      assert byte_size(Jason.encode!(outputs)) > @result_fence_limit

      block = ForgeProtocol.result_block(outputs)
      body = prefix <> block

      refute String.contains?(block, "```"), "beyond the limit: no fence"
      # "trop volumineux" pins the FR user-facing note rendered in the forge comment.
      assert String.contains?(block, "trop volumineux")
      assert ForgeProtocol.parse_result_block(body) == nil, "no truncated JSON may pass"
    end
  end
end
