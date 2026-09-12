defmodule Fleet.Roster do
  # Own boundary so roster projection carries its Credentials dependency rather than the OTP root.
  use Boundary,
    deps: [Fleet.CapProfile, Fleet.Catalogue, Fleet.Credentials, Fleet.ReleaseDoor],
    exports: []

  @moduledoc """
  Reads catalogue forge-role names and projects provisioning data without starting a fleet.
  CapProfile owns metadata.forge_identity (absent defaults true) and forge-login derivation.
  Derivation avoids hand-maintained role lists drifting, as eng_doc/scribe did with
  role_token_unavailable, and supports catalogues beyond the bundled one.

  The catalogue selects names; the tofu recipe retains account permissions, org/team layout
  and restrictions on hooks/imports. This module emits data, never a recipe granting authority.
  """

  @doc """
  Forge-identity role names of the catalogue at `root`, sorted.

  Temporarily changes :lcars_fleet/:catalogue_root and restores it in after.
  This is global application state, not isolated from concurrent readers/writers.
  """
  @spec list(Path.t()) :: {:ok, [String.t()]} | {:error, term()}
  def list(root) when is_binary(root) do
    prev = Application.fetch_env(:lcars_fleet, :catalogue_root)
    Application.put_env(:lcars_fleet, :catalogue_root, root)

    try do
      # Require a catalogue name first: merged system roles alone could mask a missing root.
      with {:ok, _name} <- catalogue_name() do
        Fleet.CapProfile.forge_identity_roles()
      end
    after
      restore(prev)
    end
  end

  @doc """
  Forge recipe inputs from root, using the same temporary global-root swap as list/1.

      %{"roles" => [...], "system_roles" => [...],
        "writers" => [...], "judges" => [...], "externals" => [...],
        "role_names" => %{login => role}, "org" => name, "system_account" => login}

  CapProfile's seat?/judge? flags partition externals, non-seat judges and remaining writers.
  Logins beginning system_ form system_roles; other logins form roles. role_names supplies account
  full_name, org is the catalogue name, and system_account comes from ForgeIdentity.
  Login projection errors can raise despite the error-return spec.
  """
  @spec tfvars(Path.t()) :: {:ok, map()} | {:error, term()}
  def tfvars(root) when is_binary(root) do
    prev = Application.fetch_env(:lcars_fleet, :catalogue_root)
    Application.put_env(:lcars_fleet, :catalogue_root, root)

    try do
      with {:ok, roster} <- Fleet.CapProfile.forge_roster(),
           {:ok, cat} <- catalogue_name(),
           {:ok, login_of} <- login_projection() do
        names = Map.new(roster, fn r -> {login_of.(r.name), r.name} end)

        {system_logins, business_logins} =
          roster
          |> Enum.map(&login_of.(&1.name))
          |> Enum.split_with(&String.starts_with?(&1, "system_"))

        {:ok,
         %{
           # Instance-wide system accounts must not be recreated for each catalogue enrollment.
           "roles" => business_logins,
           "system_roles" => system_logins,
           "writers" =>
             roster |> Enum.reject(&(&1.seat? or &1.judge?)) |> Enum.map(&login_of.(&1.name)),
           "judges" =>
             roster
             |> Enum.filter(&(&1.judge? and not &1.seat?))
             |> Enum.map(&login_of.(&1.name)),
           "externals" => roster |> Enum.filter(& &1.seat?) |> Enum.map(&login_of.(&1.name)),
           # Lets DEFAULT_SHOW_FULL_NAME display the role while API/URLs retain the login prefix.
           "role_names" => names,
           "org" => cat,
           # Keep the recipe's owner account aligned with commit identity and default push account.
           "system_account" => Fleet.Credentials.ForgeIdentity.system_identity().name
         }}
      end
    after
      restore(prev)
    end
  end

  # Share CapProfile.forge_login with runtime readers: tier prefix survives profile overrides
  # (architect remains system_architect). That authority checks role syntax and login length.
  defp login_projection do
    with {:ok, _} <- catalogue_name() do
      {:ok,
       fn role ->
         case Fleet.CapProfile.forge_login(role) do
           {:ok, login} ->
             login

           {:error, reason} ->
             raise "Fleet.Roster: no forge login for #{role}: #{inspect(reason)}"
         end
       end}
    end
  end

  defp catalogue_name do
    case Fleet.Catalogue.name() do
      n when is_binary(n) -> {:ok, n}
      _ -> {:error, :catalogue_declares_no_name}
    end
  end

  @doc """
  Prints tfvars JSON on stdout and halts 0; returned errors or empty business roles halt 1
  with stderr diagnostics (even if system_roles is nonempty).

      bin/lcars_fleet eval 'Fleet.Roster.eval_tfvars("/cat")'
  """
  @spec eval_tfvars(Path.t()) :: no_return()
  def eval_tfvars(root) when is_binary(root) do
    # Keep logs out of JSON consumed by roles.auto.tfvars.json and provision-lib's jq.
    Fleet.ReleaseDoor.claim_stdout!()

    case tfvars(root) do
      {:ok, %{"roles" => []}} ->
        IO.puts(
          :stderr,
          "catalogue #{root}: no role declares a forge identity — nothing to enroll"
        )

        System.halt(1)

      {:ok, vars} ->
        IO.puts(Jason.encode!(vars, pretty: true))
        System.halt(0)

      {:error, reason} ->
        IO.puts(:stderr, "catalogue #{root}: roster unreadable (#{inspect(reason)})")
        System.halt(1)
    end
  end

  @doc """
  Prints one role per line and halts 0; returned errors or an empty roster halt 1 on stderr.

      bin/lcars_fleet eval 'Fleet.Roster.eval_main("/cat")'

  Stdout is captured as role names by shell provisioning; diagnostics there could become accounts.
  """
  @spec eval_main(Path.t()) :: no_return()
  def eval_main(root) when is_binary(root) do
    Fleet.ReleaseDoor.claim_stdout!()

    case list(root) do
      {:ok, []} ->
        IO.puts(
          :stderr,
          "catalogue #{root}: no role declares a forge identity — nothing to enroll"
        )

        System.halt(1)

      {:ok, roles} ->
        for role <- roles, do: IO.puts(role)
        System.halt(0)

      {:error, reason} ->
        IO.puts(:stderr, "catalogue #{root}: roster unreadable (#{inspect(reason)})")
        System.halt(1)
    end
  end

  defp restore(:error), do: Application.delete_env(:lcars_fleet, :catalogue_root)
  defp restore({:ok, value}), do: Application.put_env(:lcars_fleet, :catalogue_root, value)
end
