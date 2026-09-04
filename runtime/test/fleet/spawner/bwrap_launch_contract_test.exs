defmodule Fleet.Spawner.BwrapLaunchContractTest do
  # P1/C9 — anti-regression net on the bwrap launcher CONTRACT (bin/bwrap_launch.sh).
  #
  # Binding the human's `.claude` dir brings ALL of it into the pod, hooks included
  # (session-startup.sh, agent-guard…). Since cwd=HOME=POD_DIR, the project/local settings tiers
  # (root=cwd, allowed by `--setting-sources project,local`) resolve inside that bound `.claude`
  # → the human's settings.json loads as project settings → hooks execute. The flag is powerless
  # (the leak goes through project/local, not the user tier it excludes). See JOURNAL-P1-hooks.md.
  # The fix: bind ONLY `.credentials.json` (native OAuth refresh preserved, written in place);
  # `.claude/` stays pod-owned → 0 human settings.json → 0 hooks. This test locks that contract.
  use ExUnit.Case, async: true

  @script_rel "bin/bwrap_launch.sh"

  defp umbrella_root do
    # Walks up from this file until bin/bwrap_launch.sh is found (umbrella root).
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
    # The creds bind source = CLAUDE_DIR/.credentials.json (via HUMAN_CREDS).
    assert src =~ ~r/HUMAN_CREDS="\$CLAUDE_DIR\/\.credentials\.json"/,
           "HUMAN_CREDS must point to $CLAUDE_DIR/.credentials.json"

    # The bind targets .credentials.json inside the pod-owned .claude, not the directory. #monde-propre
    # Stage B: the target lives under SANDBOX_HOME (= $POD_DIR when not relocated, /home/.pod
    # otherwise) — always ONE file.
    assert src =~
             ~r/--bind\s+"\$HUMAN_CREDS"\s+"\$SANDBOX_HOME\/\.claude\/\.credentials\.json"/,
           "AUTH_BIND_ARGS must bind $HUMAN_CREDS → $SANDBOX_HOME/.claude/.credentials.json"

    # The whole-DIR bind (the hooks leak) must not exist.
    refute src =~ ~r/--bind\s+"\$CLAUDE_DIR"\s+"\$POD_DIR\/\.claude"/,
           "binding the human's ENTIRE .claude is forbidden (hooks leak — C9)"
  end

  test "guard: creds file presence checked in bind mode", %{src: src} do
    # Never bind a nonexistent file (bwrap would fail at mount time without a clear message).
    assert src =~ ~r/\[\[ -f "\$HUMAN_CREDS" \]\] \|\|.*exit 1/,
           "the launcher must guard $HUMAN_CREDS presence before the bind (clear failure otherwise)"
  end
end
