defmodule Fleet.RosterTest do
  @moduledoc """
  Roster partition and recipe projection against the bundled catalogue.
  Expected groups share CapProfile's roster/login sources with the implementation; these tests
  do not independently verify those sources or provision accounts on a forge.
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

  test "role_names maps every login back to ITS role; org is the catalogue's declared name; system_account is received, not restated",
       %{tf: tf, roster: roster, login: login} do
    expected = Map.new(roster, fn r -> {login.(r.name), r.name} end)
    assert tf["role_names"] == expected

    {:ok, manifest} =
      YamlElixir.read_from_file(Path.join(Fleet.Catalogue.root(), "catalogue.yaml"))

    assert tf["org"] == manifest["name"]
    assert tf["system_account"] == Fleet.Credentials.ForgeIdentity.system_identity().name
  end
end
