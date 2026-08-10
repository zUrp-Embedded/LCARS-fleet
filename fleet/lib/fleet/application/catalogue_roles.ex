defmodule Fleet.Application.CatalogueRoles do
  @moduledoc """
  Reads the forge roster OF A CATALOGUE — the roles a deployment must enroll before that catalogue
  can work — without starting a fleet.

  ## The list this replaces

  The roster existed in THREE hand-held copies outside the catalogue: `forge.tf` (the accounts),
  `provision-role-tokens.sh` (the token mint) and `provision-lib.sh` (`PROV_ROLES`, which WINS on
  deploy). `mix lcars.contracts.check`'s `roles.provisioning_locked` measures their equality with
  the reference catalogue, and the comment on the third one names the exit it was waiting for:
  *"d'ici sa derivation, cette ligne se tient a la main"*.

  Held by hand, the list is wrong twice a year — the same defect landed on `eng_doc` and again on
  its rename to `scribe`, both times as a producer looping on `role_token_unavailable`. Held by
  hand against a SECOND catalogue, it is wrong by construction: nothing in the reference's roster
  describes someone else's business.

  So the catalogue answers instead. It already carries the declaration
  (`metadata.forge_identity`, absent = true) — this module only makes it readable from outside a
  running fleet, which is where a provisioning script stands.

  ## What it does NOT do, and the line matters

  It returns NAMES. It does not write the tofu recipe, and nothing about a catalogue should: the
  recipe carries what an account is ALLOWED to be — no org creation, no server-side git hooks, no
  local import, the org and team layout, the system account. Those are contract, and a catalogue is
  the one thing an operator swaps. Generating them FROM a catalogue would hand a replaceable file
  the authority to widen them, which is the exact inversion the runtime/catalogue frontier exists to
  prevent.

  The split: the catalogue says WHO exists, the recipe says what existing gets you.
  """

  @doc """
  Forge-identity role names of the catalogue at `root`, sorted.

  Swaps `:fleet_catalogue, :root` for the duration and restores it — the same borrow-and-return as
  `Fleet.Application.CatalogueVerify.verify/1`, so a caller inside a live node cannot leave the
  fleet pointed somewhere else.
  """
  @spec list(Path.t()) :: {:ok, [String.t()]} | {:error, term()}
  def list(root) when is_binary(root) do
    prev = Application.fetch_env(:fleet_catalogue, :root)
    Application.put_env(:fleet_catalogue, :root, root)

    try do
      Fleet.CapProfile.forge_identity_roles()
    after
      restore(prev)
    end
  end

  @doc """
  The four lists the forge recipe takes as input, derived from the catalogue at `root`.

      %{"roles" => [...], "writers" => [...], "judges" => [...], "externals" => [...]}

  The grouping rule, and it lives HERE rather than in a shell so it can be tested:

    * `externals` — the ReservedSeats. A seat holds a name; it never acts.
    * `judges` — `brief_kind: judge` and no structural capability. They render verdicts and put
      nothing in the repository.
    * `writers` — everything else: the producers, the delegate, the signer.

  `roles` is the union, and it is the account roster — a role in no team still needs its account.

  This is the shape tofu reads natively from a `*.auto.tfvars.json`, which is why it is emitted as
  data and not as a recipe: the recipe declares what an account is ALLOWED to be (no org creation,
  no server-side git hooks, the org and team layout), and those are contract. A catalogue names its
  people; it does not get to widen what being one of them permits.
  """
  @spec tfvars(Path.t()) :: {:ok, map()} | {:error, term()}
  def tfvars(root) when is_binary(root) do
    prev = Application.fetch_env(:fleet_catalogue, :root)
    Application.put_env(:fleet_catalogue, :root, root)

    try do
      with {:ok, roster} <- Fleet.CapProfile.forge_roster() do
        {:ok,
         %{
           "roles" => Enum.map(roster, & &1.name),
           "writers" => roster |> Enum.reject(&(&1.seat? or &1.judge?)) |> Enum.map(& &1.name),
           "judges" =>
             roster |> Enum.filter(&(&1.judge? and not &1.seat?)) |> Enum.map(& &1.name),
           "externals" => roster |> Enum.filter(& &1.seat?) |> Enum.map(& &1.name)
         }}
      end
    after
      restore(prev)
    end
  end

  @doc """
  The RELEASE door for the tfvars: print the JSON on stdout and halt 0, reason on stderr and halt 1.

      bin/lcars_fleet eval 'Fleet.Application.CatalogueRoles.eval_tfvars("/cat")'
  """
  @spec eval_tfvars(Path.t()) :: no_return()
  def eval_tfvars(root) when is_binary(root) do
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
  The RELEASE door: print one role per line and halt 0, or print the reason on stderr and halt 1.
  Called from the image entrypoint via a release eval —

      bin/lcars_fleet eval 'Fleet.Application.CatalogueRoles.eval_main("/cat")'

  One name per line, nothing else on stdout: the consumer is a shell that captures it into a
  variable. Diagnostics go to stderr precisely so that capturing stdout on a failure yields the
  EMPTY string rather than an error message parsed as a role name — a roster silently containing
  "catalogue root not readable" would create forge accounts by that name.
  """
  @spec eval_main(Path.t()) :: no_return()
  def eval_main(root) when is_binary(root) do
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

  defp restore(:error), do: Application.delete_env(:fleet_catalogue, :root)
  defp restore({:ok, value}), do: Application.put_env(:fleet_catalogue, :root, value)
end
