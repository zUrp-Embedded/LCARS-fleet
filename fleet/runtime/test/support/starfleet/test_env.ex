defmodule Fleet.Starfleet.TestEnv do
  @moduledoc """
  Application-env helper for this domain's tests (B6 harness dedup).

  Replaces the idiom rewritten in every file: "save `prev = Application.get_env`;
  `on_exit` → `put_env(prev)` or `delete_env`". The capture goes through
  `Application.fetch_env/2` (not `get_env`): an ABSENT key is deleted again on restore, a SET
  key — even set to `nil` or `false` — is put back as-is. The `nil` of `get_env` would conflate
  the two.

  Call from `setup`/`test` (the test process): the restore is registered via
  `ExUnit.Callbacks.on_exit/1`. `on_exit` callbacks run in LIFO order → nested puts
  (module setup then describe setup) unwind in the right order.

  Each domain carries ITS copy of this module (same body, module prefixed by the domain):
  test/support helpers are not shared across domains and no cross-domain test dependency
  is created.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  @doc """
  Puts `value` under `{app, key}` and registers restoration of the PREVIOUS value
  (put back, or delete if the key was absent) at the end of the test. Put + restore
  in one call — the call site no longer writes any `prev` or `on_exit`.
  """
  def put_env_restoring(app, key, value) do
    restore_env_on_exit(app, key)
    Application.put_env(app, key, value)
  end

  @doc """
  Captures the current value of `{app, key}` and registers its restoration at the end of the
  test, WITHOUT putting anything. For setups whose tests then mutate the key themselves
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
