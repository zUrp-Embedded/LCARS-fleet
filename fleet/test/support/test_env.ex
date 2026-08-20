defmodule Fleet.TestEnv do
  # Own boundary (same pattern as `Fleet.CapProfileFixture`): a support module used from every
  # domain's tests is not the property of any one domain. It touches `Application` and
  # `ExUnit.Callbacks` — plus `Fleet.Credentials`, for the ONE fixture that must not spell a path
  # the runtime owns: a role token's file name is derived (`RoleIdentity.token_path/1`), and a fixture
  # writing it by hand is a fixture that keeps passing on a scheme production has left.
  use Boundary, deps: [Fleet.Credentials], exports: []

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
  Writes `content` as `role`'s forge token, AT THE PATH THE RUNTIME READS.

  A fixture that spells `<dir>/<role>.gitea_token` itself is a fixture that keeps passing on a
  scheme the runtime no longer uses — and this scheme moved: the file is keyed by the ACCOUNT
  (`<tier>_<role>`), because a role name is only unique inside its own catalogue. Asking
  `RoleIdentity.token_path/1` is what makes a fixture follow.

  It also RAISES on a role no catalogue declares, and that is the point rather than a nuisance: the
  flat namespace let a fixture invent a role and be handed a credential for it. Two of them did.
  """
  def put_role_token!(role, content) do
    case Fleet.Credentials.RoleIdentity.token_path(role) do
      {:ok, path} ->
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, content)
        path

      :error ->
        raise "TestEnv.put_role_token!: no forge login for #{inspect(role)} — the catalogue in " <>
                "scope declares no such role, so no account and no token can exist for it. " <>
                "Name a role the fixture's catalogue actually carries."
    end
  end

  @doc """
  Removes `role`'s forge token, at the path the runtime reads.

  The inverse of `put_role_token!/2`, and it exists because provisioning EVERY signer became the
  honest default the day the seal split into two rails — the boot requires them all
  (`Pilot.Application.require_signer_tokens!`). A fixture proving a fail-closed refusal can no
  longer do it by OMISSION; it must take one away. Which is also the real shape of that failure: a
  mid-flight token loss, never a provisioning gap discovered at merge time.

  Raises on an undeclared role, exactly like its counterpart: deleting the token of a role no
  catalogue carries would assert on a world that does not exist.
  """
  def delete_role_token!(role) do
    case Fleet.Credentials.RoleIdentity.token_path(role) do
      {:ok, path} ->
        # `_ =` : `rm_rf!` rend la LISTE des chemins supprimés, et le gate refuse les retours non
        # appariés (`:unmatched_returns`). On ne l'inspecte pas — un fichier déjà absent rend `[]`,
        # ce qui est le cas nominal ici : la fixture veut l'ABSENCE, pas une suppression.
        _ = File.rm_rf!(path)
        path

      :error ->
        raise "TestEnv.delete_role_token!: no forge login for #{inspect(role)} — the catalogue " <>
                "in scope declares no such role. Name a role the fixture's catalogue carries."
    end
  end

  @doc """
  Sets `value` under `{app, key}` and registers restoration of the PREVIOUS value
  (re-set, or deletion if the key was absent) at the end of the test. Set + restore
  in one call — the call site writes neither `prev` nor `on_exit`.

  ⚠ **A TEST FILE THAT CALLS THIS IS `async: false`.** The restoration is per-test; the WRITE is
  global to the node, and no `on_exit` narrows that. Between the set and the restore, every
  concurrent test reading that key reads this one's value.

  Not a theoretical hazard — measured 2026-08-17. `CardRolesTest` pointed
  `:workflow_workflow_maps_root` at its own tmp root, and `Fleet.Pilot.ApplicationTest`, running
  concurrently, resolved its cards THERE and died on a path that was never its own and no longer
  existed. It surfaced in the image build while the host gate was green at the same commit: the
  collision needs both modules inside the same window, so it depends on core count and seed order,
  and it fires on the busiest machine.
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
