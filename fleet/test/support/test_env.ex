defmodule Fleet.TestEnv do
  # Own boundary (same pattern as `Fleet.CapProfileFixture`): a support module used from every
  # domain's tests is not the property of any one domain. No deps — it only touches
  # `Application` and `ExUnit.Callbacks`.
  use Boundary, deps: [], exports: []

  @moduledoc """
  Application-env helper for the whole suite's tests (B6 harness dedup).

  Replaces the idiom rewritten in every file: "save `prev = Application.get_env`;
  `on_exit` → `put_env(prev)` or `delete_env`". The capture goes through `Application.fetch_env/2`
  (not `get_env`): an ABSENT key is re-deleted on restore, a SET key — even to `nil` or
  `false` — is re-set as-is. Capturing via `get_env` would conflate the two through its `nil`.

  Call from `setup`/`test` (the test process): the restoration registers via
  `ExUnit.Callbacks.on_exit/1`. `on_exit` callbacks run in LIFO order → nested sets
  (module setup then describe setup) unwind in the right order.

  ONE module for the whole suite. It used to be copied once per domain because umbrella apps could
  not see each other's `test/support`; the single-app collapse removed that wall —
  `elixirc_paths(:test)` compiles `test/support` as one tree, so the copies had lost their reason
  and only kept six bodies in sync by hand.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  @doc """
  Sets `value` under `{app, key}` and registers restoration of the PREVIOUS value
  (re-set, or deletion if the key was absent) at the end of the test. Set + restore
  in one call — the call site writes neither `prev` nor `on_exit`.
  """
  def put_env_restoring(app, key, value) do
    restore_env_on_exit(app, key)
    Application.put_env(app, key, value)
  end

  @doc """
  Captures the current value of `{app, key}` and registers its restoration at the end of
  the test, WITHOUT setting anything. For setups whose tests then mutate the key themselves
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
