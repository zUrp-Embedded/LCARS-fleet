defmodule Fleet.PodRuntime.StreamParserTest do
  use ExUnit.Case, async: true

  alias Fleet.PodRuntime.StreamParser

  describe "new/0" do
    test "retourne struct vierge" do
      assert %StreamParser{
               session_id: nil,
               init_count: 0,
               buffer: "",
               events: []
             } = StreamParser.new()
    end
  end

  describe "parse_chunk/2 — line-buffering" do
    test "ligne complète → décodée + buffer reset" do
      state = StreamParser.new()
      chunk = ~s({"type":"text","text":"hello"}\n)
      assert {:ok, [%{"type" => "text"}], new_state} = StreamParser.parse_chunk(state, chunk)
      assert new_state.buffer == ""
    end

    test "chunk fragmenté (line incomplete) → garde residual buffer" do
      state = StreamParser.new()
      chunk1 = ~s({"type":"text",)
      assert {:ok, [], state1} = StreamParser.parse_chunk(state, chunk1)
      assert state1.buffer == chunk1

      chunk2 = ~s("text":"hello"}\n)

      assert {:ok, [%{"type" => "text", "text" => "hello"}], state2} =
               StreamParser.parse_chunk(state1, chunk2)

      assert state2.buffer == ""
    end

    test "multiples lignes en un chunk → décodées toutes" do
      state = StreamParser.new()

      chunk =
        ~s({"type":"text","text":"a"}\n) <>
          ~s({"type":"tool_use","name":"Read"}\n) <>
          ~s({"type":"text","text":"b"}\n)

      assert {:ok, events, _} = StreamParser.parse_chunk(state, chunk)
      assert length(events) == 3
      assert [%{"type" => "text"}, %{"type" => "tool_use"}, %{"type" => "text"}] = events
    end

    test "ligne JSON invalide silencieusement skippée" do
      state = StreamParser.new()
      chunk = ~s(garbage line\n{"type":"text","text":"ok"}\n)
      assert {:ok, [%{"type" => "text"}], _} = StreamParser.parse_chunk(state, chunk)
    end

    test "chunk vide → no-op" do
      state = StreamParser.new()
      assert {:ok, [], ^state} = StreamParser.parse_chunk(state, "")
    end
  end

  describe "parse_chunk/2 — init récurrent (PoC-1 finding F1)" do
    test "1er init capture session_id + init_count = 1" do
      state = StreamParser.new()
      chunk = ~s({"type":"init","session_id":"sess-abc"}\n)
      assert {:ok, [%{"type" => "init"}], new_state} = StreamParser.parse_chunk(state, chunk)
      assert new_state.session_id == "sess-abc"
      assert new_state.init_count == 1
    end

    test "init répété même session_id intra-session → init_count incremente, pas reboot" do
      state = StreamParser.new()
      same_init = ~s({"type":"init","session_id":"sess-abc"}\n)
      {:ok, _, state1} = StreamParser.parse_chunk(state, same_init)
      {:ok, _, state2} = StreamParser.parse_chunk(state1, same_init)
      {:ok, _, state3} = StreamParser.parse_chunk(state2, same_init)

      assert state3.session_id == "sess-abc"
      assert state3.init_count == 3
    end

    test "init avec session_id différent → reset session_id + init_count = 1 (reboot)" do
      state = StreamParser.new()
      first = ~s({"type":"init","session_id":"sess-A"}\n)
      second = ~s({"type":"init","session_id":"sess-B"}\n)

      {:ok, _, state1} = StreamParser.parse_chunk(state, first)
      assert state1.session_id == "sess-A"

      {:ok, _, state2} = StreamParser.parse_chunk(state1, second)
      assert state2.session_id == "sess-B"
      assert state2.init_count == 1
    end
  end

  describe "validate_init/1 — F-INIT-VALIDATE 9 champs + G24" do
    @full_init %{
      "tools" => ["Read"],
      "model" => "claude-sonnet-4-6",
      "permission_mode" => "ask",
      "api_key_source" => "oauth",
      "cwd" => "/tmp/pod",
      "claude_code_version" => "0.36.3",
      "mcp_servers" => [],
      "slash_commands" => [],
      "agents" => []
    }

    test ":ok quand tous les 9 champs présents + api_key_source=oauth" do
      assert :ok = StreamParser.validate_init(@full_init)
    end

    test "champ manquant → {:error, [missing]}" do
      missing_init = Map.delete(@full_init, "model")
      assert {:error, [:model]} = StreamParser.validate_init(missing_init)
    end

    test "plusieurs champs manquants → {:error, list}" do
      missing_init = @full_init |> Map.delete("model") |> Map.delete("agents")
      assert {:error, missing} = StreamParser.validate_init(missing_init)
      assert :model in missing
      assert :agents in missing
    end

    test "G24 invariant : api_key_source != oauth → :api_key_source dans missing" do
      bad_init = Map.put(@full_init, "api_key_source", "anthropic")
      assert {:error, [:api_key_source]} = StreamParser.validate_init(bad_init)
    end

    test "frame init complètement vide → tous les 9 champs manquants" do
      assert {:error, missing} = StreamParser.validate_init(%{})
      assert length(missing) == 9
    end
  end
end
