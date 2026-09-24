defmodule Fleet.Credentials.ForgeIdentity do
  @moduledoc """
  Builds local-forge Git identities: human author/committer plus an LCARS role coauthor trailer.
  Trailer verification belongs to the commit-identity gate, not this string builder.
  Spawn and check policy share identity constants here to avoid mismatched emails.

  Normally Human.current/0 resolves the runtime OS user. Name comes from global Git config,
  then that login's GECOS, then login; email comes from global Git config, then the login's forge
  account address, `login@lcars.local` — the address every forge account is provisioned with
  (`forge-recipe/forge.tf`, `instance/accounts.tf`, `deploy/lib/forge-bootstrap.sh`). Never the
  hostname: `login@<hostname>` maps to no account, on the forge or anywhere else.
  These are bounded command reads, not a catalogue membership or user-existence check.
  An explicit human does not switch the OS user whose global Git config is read.

  Configure a stable global user.email before spawning: spawn and commit checking resolve it
  independently. Changing Git config or the hostname between those reads can reject an otherwise
  legitimate commit. OS-derived config/GECOS fields and explicit identity fields strip ASCII
  controls; human fallbacks and the application override do not receive that sanitization.

  Local identity policy is shared with the launcher and commit gate. Git-native mode admits
  the human email; payload mode also admits system_email/0 for the system committer.
  External publication is separate: bin/publish-transform.sh rewrites role trailers using
  bin/<vendor>_launch.identity and system-authored commits toward the human committer.
  """

  @role_email_domain "lcars.local"
  @system_name "system_starfleet"
  # Starfleet opts out of a separate role account; its writes use this provisioned system identity.
  @system_email "#{@system_name}@#{@role_email_domain}"

  @type identity :: %{
          author_name: String.t(),
          author_email: String.t(),
          committer_name: String.t(),
          committer_email: String.t(),
          human: String.t(),
          role: String.t(),
          coauthor_trailer: String.t()
        }

  @doc """
  Resolves human identity and role trailer for a non-empty role. :human overrides login;
  :identity supplies name/email and disables the application override. Supply both to avoid
  OS lookup: :identity alone still resolves the human. Role strings are not catalogue-validated.
  """
  @spec for_role(String.t(), keyword()) :: {:ok, identity()} | {:error, term()}
  def for_role(role, opts \\ []) when is_binary(role) and role != "" do
    with {:ok, %{name: name, email: email, human: human}} <- resolve_identity(opts) do
      {:ok,
       %{
         author_name: name,
         author_email: email,
         committer_name: name,
         committer_email: email,
         human: human,
         role: role,
         coauthor_trailer: coauthor_trailer(role)
       }}
    end
  end

  @doc """
  Resolves the runtime human's name, email and login. Options match `for_role/2`.
  """
  @spec human_identity(keyword()) ::
          {:ok, %{name: String.t(), email: String.t(), human: String.t()}} | {:error, term()}
  def human_identity(opts \\ []), do: resolve_identity(opts)

  @doc "Builds a role coauthor trailer after stripping ASCII controls; an empty cleaned role raises."
  @spec coauthor_trailer(String.t()) :: String.t()
  def coauthor_trailer(role) when is_binary(role) do
    # Sanitize at the header sink; role metadata may contain controls even outside catalogue loading.
    clean = strip_control(role)
    "Co-authored-by: LCARS-#{clean} <#{role_email(clean)}>"
  end

  @doc """
  Identity emails accepted by the commit-identity gate depending on the mode. `git_native` → the human
  alone (they commit); `payload` → the human (author) + system (committer).
  """
  @spec allowed_emails(:git_native | :payload, String.t()) :: [String.t()]
  def allowed_emails(:git_native, human_email), do: [human_email]
  def allowed_emails(:payload, human_email), do: [human_email, @system_email]

  @doc """
  System identity (committer in payload mode). The system IS NOT the human: it
  materializes the commit, the author stays the human.
  """
  @spec system_email() :: String.t()
  def system_email, do: @system_email

  @doc """
  Returns the system name/email for runtime-authored commits (for example onboarding scaffolds).
  Use this accessor so creation and commit-gate policy share the same constants.
  """
  @spec system_identity() :: %{name: String.t(), email: String.t()}
  def system_identity, do: %{name: @system_name, email: @system_email}

  @doc "The address a login's forge account is provisioned with: `login@lcars.local`."
  @spec forge_email(String.t()) :: String.t()
  def forge_email(login) when is_binary(login),
    do: "#{strip_control(login)}@#{@role_email_domain}"

  @doc """
  Builds the role trailer email after stripping ASCII controls; does not validate email syntax
  or account existence. Accepts a non-empty input even if stripping leaves an empty local part.
  """
  @spec role_email(String.t()) :: String.t()
  def role_email(role) when is_binary(role) and role != "",
    do: "#{strip_control(role)}@#{@role_email_domain}"

  defp resolve_human(opts) do
    case Keyword.get(opts, :human) do
      h when is_binary(h) and h != "" ->
        {:ok, h}

      _ ->
        Fleet.Credentials.Human.current()
    end
  end

  # The application override bypasses resolution and sanitization; any explicit :identity
  # key disables it, even if that option later falls back to OS-derived name/email.
  defp resolve_identity(opts) do
    override = Application.get_env(:lcars_fleet, :credentials_forge_identity_override)
    explicit_identity? = Keyword.has_key?(opts, :identity)

    case override do
      %{name: name, email: email} = ov
      when is_binary(name) and is_binary(email) and not explicit_identity? ->
        {:ok, %{name: name, email: email, human: Map.get(ov, :human, "override")}}

      _ ->
        with {:ok, human} <- resolve_human(opts) do
          {:ok, id} = os_identity(human, opts)
          {:ok, Map.put(id, :human, human)}
        end
    end
  end

  defp os_identity(human, opts) do
    case Keyword.get(opts, :identity) do
      %{name: name, email: email} when is_binary(name) and is_binary(email) ->
        {:ok, %{name: strip_control(name), email: strip_control(email)}}

      _ ->
        read = Keyword.get(opts, :git_config, &git_config/1)

        name =
          sanitize_identity(read.("user.name")) || sanitize_identity(gecos_name(human)) || human

        email = sanitize_identity(read.("user.email")) || forge_email(human)
        {:ok, %{name: name, email: email}}
    end
  end

  defp strip_control(s) when is_binary(s), do: String.replace(s, ~r/[\x00-\x1F\x7F]/, "")

  defp sanitize_identity(nil), do: nil

  defp sanitize_identity(s) when is_binary(s),
    do: s |> strip_control() |> String.trim() |> blank_to_nil()

  defp git_config(key) do
    case Fleet.Credentials.Shell.run("git", ["config", "--global", "--get", key],
           timeout_ms: 5_000
         ) do
      {:ok, {out, 0}} -> blank_to_nil(String.trim(out))
      _ -> nil
    end
  end

  defp gecos_name(human) do
    case Fleet.Credentials.Shell.run("getent", ["passwd", human], timeout_ms: 5_000) do
      {:ok, {line, 0}} ->
        line
        |> String.trim()
        |> String.split(":")
        |> Enum.at(4, "")
        |> String.split(",")
        |> List.first()
        |> blank_to_nil()

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(s) when is_binary(s), do: s
end
