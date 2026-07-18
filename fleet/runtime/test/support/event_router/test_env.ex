defmodule Fleet.EventRouter.TestEnv do
  @moduledoc """
  App-env helper for this domain's tests (harness dedup B6).

  Replaces the idiom rewritten in every file: "save `prev = Application.get_env`;
  `on_exit` → `put_env(prev)` or `delete_env`". Capture goes through `Application.fetch_env/2`
  (not `get_env`): an ABSENT key is deleted again on restore, a SET key — even set to `nil` or
  `false` — is put back as-is. A `get_env`-based capture would conflate the two via its `nil`.

  Call from `setup`/`test` (the test process): restoration is registered via
  `ExUnit.Callbacks.on_exit/1`. `on_exit` callbacks run LIFO → nested puts
  (module setup then describe setup) unwind in the right order.

  Each domain carries its OWN copy of this module (same body, module prefixed per domain):
  test/support helpers are not visible across domains and must not create cross-domain
  test dependencies.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  @doc """
  Puts `value` under `{app, key}` and registers restoration of the PREVIOUS value
  (put back, or deleted if the key was absent) at the end of the test. Put + restore
  in one call — the call site has no `prev` nor `on_exit` left to write.
  """
  def put_env_restoring(app, key, value) do
    restore_env_on_exit(app, key)
    Application.put_env(app, key, value)
  end

  @doc """
  Captures the current value of `{app, key}` and registers its restoration at the end of
  the test, WITHOUT putting anything. For setups whose tests then mutate the key themselves
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
