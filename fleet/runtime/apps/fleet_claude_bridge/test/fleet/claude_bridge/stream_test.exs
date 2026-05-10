defmodule Fleet.ClaudeBridge.StreamTest do
  use ExUnit.Case, async: true

  alias Fleet.ClaudeBridge.Stream, as: BridgeStream

  doctest Fleet.ClaudeBridge.Stream

  describe "text_content/2" do
    test "filtre uniquement les events type=text" do
      events = [
        %{"type" => "text", "text" => "a"},
        %{"type" => "tool_use", "name" => "Read"},
        %{"type" => "text", "text" => "b"},
        %{"type" => "result"}
      ]

      assert [%{"type" => "text", "text" => "a"}, %{"type" => "text", "text" => "b"}] =
               BridgeStream.text_content(events)
    end

    test "retourne liste vide si aucun text" do
      assert [] = BridgeStream.text_content([%{"type" => "init"}, %{"type" => "result"}])
    end
  end

  describe "tool_uses/2" do
    test "filtre uniquement les events type=tool_use" do
      events = [
        %{"type" => "text"},
        %{"type" => "tool_use", "name" => "Read"},
        %{"type" => "tool_use", "name" => "Glob"}
      ]

      assert [
               %{"type" => "tool_use", "name" => "Read"},
               %{"type" => "tool_use", "name" => "Glob"}
             ] = BridgeStream.tool_uses(events)
    end
  end

  describe "filter_type/2" do
    test "filtre par type arbitraire" do
      events = [%{"type" => "init"}, %{"type" => "text"}, %{"type" => "init"}]
      assert [%{"type" => "init"}, %{"type" => "init"}] = BridgeStream.filter_type(events, "init")
    end

    test "type inconnu → liste vide" do
      assert [] = BridgeStream.filter_type([%{"type" => "text"}], "unknown")
    end
  end

  describe "until_result/2" do
    test "prend events jusqu'à la première frame result inclus" do
      events = [
        %{"type" => "init"},
        %{"type" => "text"},
        %{"type" => "result", "stop_reason" => "end_turn"},
        %{"type" => "after_result"}
      ]

      assert [
               %{"type" => "init"},
               %{"type" => "text"},
               %{"type" => "result", "stop_reason" => "end_turn"}
             ] = BridgeStream.until_result(events)
    end

    test "stream sans result → retourne tous les events" do
      events = [%{"type" => "init"}, %{"type" => "text"}]
      assert ^events = BridgeStream.until_result(events)
    end

    test "result en première position → liste avec une seule frame" do
      assert [%{"type" => "result"}] =
               BridgeStream.until_result([%{"type" => "result"}, %{"type" => "extra"}])
    end

    test "stream vide → liste vide" do
      assert [] = BridgeStream.until_result([])
    end
  end
end
