defmodule Fleet.Pilot.ForgeProtocolPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  # Property-based proof of `ForgeProtocol`'s central invariant: each format has its builder and
  # its parser/predicate co-located, and `parse . build == identity`.
  # The example-based tests (forge_protocol_test.exs) pin named cases; here we bombard with
  # generated role/sha/steps to prove the invariant holds on the whole REALISTIC charset, not only
  # on the hardwired examples.
  alias Fleet.Pilot.ForgeProtocol

  # Realistic charset of a wire-protocol token (role, workflow_map name, step):
  # letters/digits + `_`/`-` (kebab and snake). Excludes by construction the marker's grave
  # delimiters (`:` and `]`) and the newline -> a generated token cannot break the format itself.
  # (Robustness to an ADVERSARIAL token containing those delimiters is a distinct concern, outside
  # this round-trip.)
  defp token do
    string([?a..?z, ?A..?Z, ?0..?9, ?_, ?-], min_length: 1, max_length: 40)
  end

  # realistic sha: short-to-long hex (git short-sha up to the full sha1).
  defp sha do
    string([?0..?9, ?a..?f], min_length: 1, max_length: 40)
  end

  property "step_run_marker?/1 recognizes ANY marker produced by step_run_marker/2" do
    # The module exposes no step_run parser (only the predicate for forge-native counting):
    # the provable round-trip is build -> predicate == true.
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

  # (route_marker/parse_route_marker property removed: the position lives in the stage/* label —
  # cf. ForgeClient.)

  # ============================================================
  # ```result — the ONLY build/parse pair that had no property.
  # ============================================================

  # Exact limit of the code (@result_fence_limit): beyond it, the block is no longer a JSON fence
  # but a NOTE. The CUTOFF property below is anchored to this number.
  @result_fence_limit 8192

  # Adversarial JSON keys: the key travels inside the JSON, it must survive escaping (backticks,
  # quote, newline, unicode) — an encoding that broke it would make the reader-side parse fail
  # (`ForgeClient.get_predecessor_result`) on a perfectly valid `outputs`.
  defp json_key do
    one_of([
      string(:alphanumeric, min_length: 1, max_length: 6),
      member_of(["a b", "```", "k\"q", "k\\q", "cle-e", "ligne\nsuite", "emoji"])
    ])
  end

  # JSON scalars, with the poisons that could break the FENCE itself: backticks, a closing fence
  # `\n``` `, a bare newline, a NUL, unicode.
  defp json_scalar do
    one_of([
      string(:printable, max_length: 10),
      member_of(["```", "```result", "\n```", "`", "\n", "\r\n", "\t", " ", "e-aigu", "\"", "\\"]),
      integer(),
      float(),
      boolean(),
      constant(nil)
    ])
  end

  # Recursive JSON value (scalars, lists, nested maps) — the real shape of an `outputs`
  # self-reported by a pod.
  defp json_value do
    tree(json_scalar(), fn child ->
      one_of([list_of(child, max_length: 3), map_of(json_key(), child, max_length: 3)])
    end)
  end

  # Non-empty `outputs` (map_size > 0 is result_block/1's guard: an empty map returns "").
  defp outputs_gen do
    map_of(json_key(), json_value(), min_length: 1, max_length: 4)
  end

  # Comment-body prefix (the block is glued AT THE END of the body). We exclude backticks: a
  # prefix carrying ITS OWN ```result fence falls under the "first block wins" semantics
  # (Regex.run = first occurrence), which is a distinct concern from the round-trip.
  defp body_prefix do
    filter(string(:printable, max_length: 30), &(not String.contains?(&1, "`")))
  end

  # INVARIANT: under the fence limit, parse_result_block(prefix <> result_block(outputs))
  # returns EXACTLY {:ok, outputs} — for any JSON-shaped outputs, including with backticks,
  # fences, newlines and unicode IN the values.
  # WHY: this pair is the channel through which a step reads its predecessor's `outputs`
  # (`ForgeClient.get_predecessor_result` → `Gates` → gate decision). A value carrying a ``` that
  # broke the fence would make the parser return `nil`: the successor would evaluate its gate on
  # EMPTY outputs → silent fail-closed, pipeline blocked on a proof that was actually provided.
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

  # INVARIANT: beyond the limit, result_block returns the NOTE (no fence) and the parser refuses
  # the body — never an accepted truncated JSON.
  # WHY: a JSON cut at 8 KB is an INVALID JSON. If it were fenced anyway, the reader would get
  # either `nil` (silent loss of the result) or — worse — a PARTIAL map if the truncation fell on
  # a valid boundary: the successor's gate would decide on amputated outputs, believing it has
  # them all.
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
