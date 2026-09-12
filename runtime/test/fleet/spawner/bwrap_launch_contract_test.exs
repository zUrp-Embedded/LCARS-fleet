defmodule Fleet.Spawner.BwrapLaunchContractTest do
  # Binding the whole human .claude directory exposes settings and hooks as project/local
  # settings when cwd=HOME=POD_DIR, bypassing --setting-sources user exclusion.
  # Bind only .credentials.json so OAuth refresh works while .claude remains pod-owned.
  use ExUnit.Case, async: true

  @script_rel "bin/bwrap_launch.sh"

  defp umbrella_root do
    Path.dirname(__ENV__.file)
    |> Stream.iterate(&Path.dirname/1)
    |> Enum.find(fn dir ->
      dir == "/" or File.exists?(Path.join(dir, @script_rel))
    end)
  end

  setup_all do
    root = umbrella_root()
    script = Path.join(root, @script_rel)
    assert File.exists?(script), "bin/bwrap_launch.sh not found from #{__ENV__.file}"
    %{src: File.read!(script)}
  end

  test "bind mode: binds ONLY .credentials.json (never the human's whole .claude dir)", %{
    src: src
  } do
    assert src =~ ~r/HUMAN_CREDS="\$CLAUDE_DIR\/\.credentials\.json"/,
           "HUMAN_CREDS must point to $CLAUDE_DIR/.credentials.json"

    # The target uses SANDBOX_HOME so the same file bind works with namespace relocation.
    assert src =~
             ~r/--bind\s+"\$HUMAN_CREDS"\s+"\$SANDBOX_HOME\/\.claude\/\.credentials\.json"/,
           "AUTH_BIND_ARGS must bind $HUMAN_CREDS → $SANDBOX_HOME/.claude/.credentials.json"

    refute src =~ ~r/--bind\s+"\$CLAUDE_DIR"\s+"\$POD_DIR\/\.claude"/,
           "binding the human's ENTIRE .claude is forbidden (hooks leak — C9)"
  end

  test "guard: creds file presence checked in bind mode", %{src: src} do
    # Check before mounting to report missing credentials clearly.
    assert src =~ ~r/\[\[ -f "\$HUMAN_CREDS" \]\] \|\|.*exit 1/,
           "the launcher must guard $HUMAN_CREDS presence before the bind (clear failure otherwise)"
  end
end
