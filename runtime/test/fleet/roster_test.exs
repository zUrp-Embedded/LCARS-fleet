defmodule Fleet.RosterTest do
  @moduledoc """
  The grouping rule of `Fleet.Roster.tfvars/1`, confronted with the bundled canon catalogue.

  `tfvars/1` says its rule "lives HERE rather than in a shell so it can be tested": externals are
  the ReservedSeats, judges are the `brief_kind: judge` roles without a structural capability,
  writers are everything else, and `roles` / `system_roles` split the same roster by lifetime.
  This file is that test. It reads the roster the same way the function does
  (`Fleet.CapProfile.forge_roster/0` under the swapped root), so the expectation and the subject
  share their source and cannot drift apart silently.
  """
  # `tfvars/1` swaps the global `:catalogue_root` for its duration — not async.
  use ExUnit.Case, async: false

  alias Fleet.Roster

  setup do
    root = Fleet.Catalogue.root()
    prev = Application.fetch_env(:lcars_fleet, :catalogue_root)
    Application.put_env(:lcars_fleet, :catalogue_root, root)
    {:ok, roster} = Fleet.CapProfile.forge_roster()

    login = fn name ->
      {:ok, l} = Fleet.CapProfile.forge_login(name)
      l
    end

    case prev do
      {:ok, v} -> Application.put_env(:lcars_fleet, :catalogue_root, v)
      :error -> Application.delete_env(:lcars_fleet, :catalogue_root)
    end

    {:ok, tf} = Roster.tfvars(root)
    %{tf: tf, roster: roster, login: login}
  end

  test "writers, judges and externals PARTITION the account roster", %{tf: tf} do
    accounts = Enum.sort(tf["roles"] ++ tf["system_roles"])
    grouped = Enum.sort(tf["writers"] ++ tf["judges"] ++ tf["externals"])

    assert accounts == grouped, "a login is in no team, or in two"
    assert accounts == Enum.uniq(accounts), "a login appears twice in the roster"
  end

  test "externals are exactly the seats; judges the judges that are not seats; writers the rest",
       %{tf: tf, roster: roster, login: login} do
    seats = roster |> Enum.filter(& &1.seat?) |> Enum.map(&login.(&1.name)) |> Enum.sort()

    judges =
      roster
      |> Enum.filter(&(&1.judge? and not &1.seat?))
      |> Enum.map(&login.(&1.name))
      |> Enum.sort()

    writers =
      roster |> Enum.reject(&(&1.seat? or &1.judge?)) |> Enum.map(&login.(&1.name)) |> Enum.sort()

    assert Enum.sort(tf["externals"]) == seats
    assert Enum.sort(tf["judges"]) == judges
    assert Enum.sort(tf["writers"]) == writers
    # The canon carries at least one of each, otherwise this test proves nothing about the rule.
    assert seats != [] and judges != [] and writers != []
  end

  test "roles / system_roles split by LIFETIME: the `system_` prefix decides", %{tf: tf} do
    assert Enum.all?(tf["system_roles"], &String.starts_with?(&1, "system_"))
    refute Enum.any?(tf["roles"], &String.starts_with?(&1, "system_"))
    assert tf["system_roles"] != []
  end

  test "role_names maps every login back to its role; org and system_account are received, not restated",
       %{tf: tf} do
    assert tf["role_names"] |> Map.keys() |> Enum.sort() ==
             Enum.sort(tf["roles"] ++ tf["system_roles"])

    assert is_binary(tf["org"]) and tf["org"] != ""
    assert tf["system_account"] == Fleet.Credentials.ForgeIdentity.system_identity().name
  end
end
