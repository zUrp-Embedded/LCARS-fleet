defmodule Fleet.ClaudeBridge.RCModeTest do
  @moduledoc """
  Lot 5 inc1 — `Fleet.ClaudeBridge.RCMode` (DN ring1/fleet_claude_bridge.md
  §"Tests conformance amendement" 2/3/4 + chemin MVP réel : SDK absent →
  fallback Port). Surface déterministe testée (helpers purs + F-ADP-2 +
  routing fallback via test-seams `:port_opener`/`:claude_bin`).
  """
  use ExUnit.Case, async: true

  alias Fleet.ClaudeBridge.RCMode

  defmodule FakeAdapter do
    def can_use_tool(_t, _i, _c), do: %{"behavior" => "deny", "reason" => "test"}
  end

  describe "build_rc_args/1 (pur — DN test 4/7)" do
    test "base : remote-control --spawn=session --system-prompt-file" do
      assert RCMode.build_rc_args(system_prompt_file: "/sp.md") ==
               ["remote-control", "--spawn=session", "--system-prompt-file", "/sp.md"]
    end

    test "--name + --resume conditionnels" do
      assert RCMode.build_rc_args(
               system_prompt_file: "/sp.md",
               name: "architect",
               resume: "abc123"
             ) ==
               [
                 "remote-control",
                 "--spawn=session",
                 "--system-prompt-file",
                 "/sp.md",
                 "--name",
                 "architect",
                 "--resume",
                 "abc123"
               ]
    end

    test "name/resume vides ou nil → omis" do
      assert RCMode.build_rc_args(system_prompt_file: "/sp.md", name: nil, resume: "") ==
               ["remote-control", "--spawn=session", "--system-prompt-file", "/sp.md"]
    end

    test "system_prompt_file obligatoire" do
      assert_raise KeyError, fn -> RCMode.build_rc_args(name: "x") end
    end
  end

  describe "F-ADP-2 (DN test 3) — permission_adapter obligatoire" do
    test "start_session sans :permission_adapter → raise (refus-défaut, pas default-ALLOW)" do
      assert_raise RuntimeError, ~r/F-ADP-2/, fn ->
        RCMode.start_session(
          system_prompt_file: "/sp.md",
          claude_bin: "/fake/claude",
          port_opener: fn _b, _a -> :noop end
        )
      end
    end
  end

  describe "sdk_supports_rc?/0 — réalité MVP" do
    test "false : SDK guess/claude_code absent des deps chantier-8 (honnête)" do
      refute RCMode.sdk_supports_rc?()
    end
  end

  describe "start_session fallback Port (DN test 2 — SDK absent → wrap direct)" do
    test "route vers Port, ref :lcars_port, args RC corrects, hook_registry F-ADP-2" do
      parent = self()

      opener = fn bin, args ->
        send(parent, {:opened, bin, args})
        {:fake_port, make_ref()}
      end

      assert {:ok, ref} =
               RCMode.start_session(
                 system_prompt_file: "/sp.md",
                 name: "engineer",
                 resume: "r1",
                 permission_adapter: FakeAdapter,
                 claude_bin: "/usr/bin/claude",
                 port_opener: opener
               )

      assert %{adapter: :lcars_port, opaque: {:fake_port, _}, hook_registry: hr} = ref
      assert %{can_use_tool: FakeAdapter, hooks_pre: [], hooks_post: []} = hr

      assert_received {:opened, "/usr/bin/claude",
                       [
                         "remote-control",
                         "--spawn=session",
                         "--system-prompt-file",
                         "/sp.md",
                         "--name",
                         "engineer",
                         "--resume",
                         "r1"
                       ]}
    end

    test "opener qui raise → {:error, {:rc_port_open_failed, _}} (pas d'exception propagée)" do
      assert {:error, {:rc_port_open_failed, _}} =
               RCMode.start_session(
                 system_prompt_file: "/sp.md",
                 permission_adapter: FakeAdapter,
                 claude_bin: "/x",
                 port_opener: fn _b, _a -> raise "boom" end
               )
    end
  end
end
