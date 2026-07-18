defmodule Fleet.Spawner.TestEnv do
  @moduledoc """
  Application-env helper for this app's tests (harness dedup B6).

  Replaces the idiom rewritten in every file: "save `prev = Application.get_env`;
  `on_exit` → `put_env(prev)` or `delete_env`". The capture goes through `Application.fetch_env/2`
  (not `get_env`): an ABSENT key is re-deleted on restore, a SET key — even set to `nil` or
  `false` — is put back as-is. The old idiom conflated the two via `get_env`'s `nil`.

  Call from `setup`/`test` (the test process): the restoration is registered via
  `ExUnit.Callbacks.on_exit/1`. `on_exit` callbacks run LIFO → nested puts
  (module setup then describe setup) unwind in the right order.

  Each app carries ITS copy of this module (same body, module prefixed by the app):
  test/support files are not visible across apps and no cross-app test dependency is created.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  @doc """
  Puts `value` under `{app, key}` and registers restoration of the PREVIOUS value
  (put back, or deletion if the key was absent) at the end of the test. Put + restore
  in one call — the use site no longer writes `prev` nor `on_exit`.
  """
  def put_env_restoring(app, key, value) do
    restore_env_on_exit(app, key)
    Application.put_env(app, key, value)
  end

  @doc """
  Captures the current value of `{app, key}` and registers its restoration at the end of the
  test, WITHOUT putting anything. For setups whose tests then mutate the key themselves
  (free-form `put_env`/`delete_env` in the test body).
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
