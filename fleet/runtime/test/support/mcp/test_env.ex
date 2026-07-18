defmodule Fleet.MCP.TestEnv do
  @moduledoc """
  Application-env helper for this app's tests (harness B6 dedup).

  Replaces the idiom rewritten in every file: "save `prev = Application.get_env`;
  `on_exit` → `put_env(prev)` or `delete_env`". The capture goes through `Application.fetch_env/2`
  (not `get_env`): an ABSENT key is re-deleted on return, a SET key — even to `nil` or
  `false` — is restored as-is. The old idiom conflated the two via `get_env`'s `nil`.

  Call from `setup`/`test` (the test's process): restoration registers via
  `ExUnit.Callbacks.on_exit/1`. The `on_exit` callbacks run LIFO → nested sets
  (module setup then describe setup) unwind in the right order.

  Each umbrella app carries ITS copy of this module (same body, app-prefixed module name):
  test/support files are invisible across apps and no cross-app test dependency is created.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  @doc """
  Sets `value` under `{app, key}` and registers restoration of the PREVIOUS value
  (restore, or deletion if the key was absent) at the end of the test. Set + restore
  in one call — the use site no longer writes `prev` nor `on_exit`.
  """
  def put_env_restoring(app, key, value) do
    restore_env_on_exit(app, key)
    Application.put_env(app, key, value)
  end

  @doc """
  Captures the current value of `{app, key}` and registers its restoration at the end of the
  test, WITHOUT setting anything. For setups whose tests then mutate the key themselves
  (free `put_env`/`delete_env` in the test body).
  """
  def restore_env_on_exit(app, key) do
    prev = Application.fetch_env(app, key)

    on_exit(fn ->
      case prev do
        {:ok, value} -> Application.put_env(app, key, value)
        :error -> Application.delete_env(app, key)
      end
    end)
  end
end
