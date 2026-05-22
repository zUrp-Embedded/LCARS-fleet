defmodule Fleet.ClaudeBridgeTest do
  @moduledoc """
  Lot 5 inc3 — `Fleet.ClaudeBridge.session_start/1` routeur de modes
  (DN ring1/fleet_claude_bridge.md §amendement, tests conformance 5/6 +
  routing explicite + propagation F-ADP-2). Test-seams `:rc_available`,
  `:port_opener`, `:claude_bin`.
  """
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog

  alias Fleet.ClaudeBridge

  defmodule FakeAdapter do
    def can_use_tool(_t, _i, _c), do: %{"behavior" => "deny", "reason" => "test"}
  end

  defp rc_opts(extra \\ []) do
    [
      system_prompt_file: "/sp.md",
      permission_adapter: FakeAdapter,
      claude_bin: "/usr/bin/claude",
      port_opener: fn _b, _a -> {:fake_port, make_ref()} end
    ] ++ extra
  end

  test "mode :remote_control → RCMode (ref :lcars_port)" do
    assert {:ok, %{adapter: :lcars_port}} =
             ClaudeBridge.session_start([mode: :remote_control] ++ rc_opts())
  end

  test "mode :print → SessionWrapper (NotWiredYet MVP → {:error,:not_wired_yet})" do
    assert {:error, :not_wired_yet} = ClaudeBridge.session_start(mode: :print)
  end

  test "mode :auto + rc_available true → RC (DN test 5 : pods permanents/éphémères RC)" do
    assert {:ok, %{adapter: :lcars_port}} =
             ClaudeBridge.session_start([mode: :auto, rc_available: true] ++ rc_opts())
  end

  test "mode :auto + rc_available false → fallback :print + warning (DN test 6)" do
    log =
      capture_log(fn ->
        assert {:error, :not_wired_yet} =
                 ClaudeBridge.session_start(mode: :auto, rc_available: false)
      end)

    assert log =~ "RC indisponible"
    assert log =~ "fallback :print"
  end

  test "mode inconnu → {:error,{:unknown_mode,_}}" do
    assert {:error, {:unknown_mode, :bogus}} = ClaudeBridge.session_start(mode: :bogus)
  end

  test "session_start_rc/1 → RCMode direct" do
    assert {:ok, %{adapter: :lcars_port}} = ClaudeBridge.session_start_rc(rc_opts())
  end

  test "rc_available?/1 : test-seam forcé" do
    assert ClaudeBridge.rc_available?(rc_available: true)
    refute ClaudeBridge.rc_available?(rc_available: false)
  end

  test "F-ADP-2 propagé : mode RC sans :permission_adapter → raise" do
    assert_raise RuntimeError, ~r/F-ADP-2/, fn ->
      ClaudeBridge.session_start(
        mode: :remote_control,
        system_prompt_file: "/sp.md",
        claude_bin: "/x",
        port_opener: fn _b, _a -> :noop end
      )
    end
  end
end
