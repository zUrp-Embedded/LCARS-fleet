defmodule Mix.Tasks.Lcars.ProjectTemplate.SyncTest do
  # async: false — mutates global Application env (the git-runner seam + :forge_auth).
  use ExUnit.Case, async: false

  alias Mix.Tasks.Lcars.ProjectTemplate.Sync

  @token "s3cr3t-forge-token-should-never-touch-argv"

  test "the forge token rides the git ENV, never the push argv (no secret in /proc/<pid>/cmdline)" do
    test_pid = self()

    # Capture every git invocation instead of running git.
    Application.put_env(:lcars_fleet, :template_sync_git_runner, fn args, opts ->
      send(test_pid, {:git, args, opts})
      {:ok, {"", 0}}
    end)

    on_exit(fn ->
      Application.delete_env(:lcars_fleet, :template_sync_git_runner)
      Application.delete_env(:fleet_credentials, :forge_auth)
    end)

    assert :ok =
             Sync.push_template("fleet/project-template",
               base_url: "https://forge.test",
               token: @token
             )

    calls = drain_git_calls([])
    # 4 ops (init/add/commit/push) × 2 faces (main + ops).
    assert length(calls) == 8

    push_calls = Enum.filter(calls, fn {args, _opts} -> "push" in args end)
    assert length(push_calls) == 2

    for {args, opts} <- push_calls do
      # The secret is NOWHERE in the argv — no token-in-URL, no `-c extraheader` arg.
      refute Enum.any?(args, &String.contains?(&1, @token)),
             "forge token leaked into the git push argv: #{inspect(args)}"

      # The remote is the PLAIN url (no userinfo / oauth2:), matched by git on the url_prefix.
      assert "https://forge.test/fleet/project-template.git" in args
      refute Enum.any?(args, &String.contains?(&1, "oauth2:"))
      refute Enum.any?(args, &String.contains?(&1, "@forge.test"))

      # The token DOES ride the env (owner-only /proc/<pid>/environ), via the ForgeAuth single source.
      env = Keyword.fetch!(opts, :env)
      header = Enum.find_value(env, fn {k, v} -> if k == "GIT_CONFIG_VALUE_0", do: v end)
      assert header == "Authorization: token #{@token}"

      # …and the network push is BOUNDED (no infinite deploy hang).
      assert is_integer(Keyword.get(opts, :timeout_ms))
    end
  end

  defp drain_git_calls(acc) do
    receive do
      {:git, args, opts} -> drain_git_calls([{args, opts} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
