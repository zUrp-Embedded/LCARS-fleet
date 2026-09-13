defmodule Fleet.Project.Onboard.Repo do
  @moduledoc """
  Forge adapters for onboarding: org/repository probes, creation, labels and URLs.
  Callers can supply forge_repo, forge_files, forge_users and ensure_labels seams.
  API calls take nested forge_opts; repository URL construction uses top-level base_url
  or pilot_forge configuration.
  """

  alias Fleet.Forge.Client, as: ForgeClient
  alias Fleet.Project.GitOps

  @doc false
  @spec require_forge_absent(String.t(), keyword()) :: :ok | {:error, term()}
  def require_forge_absent(full_name, opts) do
    case repo_mod(opts).default_branch(full_name, fc_opts(opts)) do
      {:ok, _branch} -> {:error, {:repo_already_exists, full_name}}
      {:error, {:http, 404, _}} -> :ok
      {:error, reason} -> {:error, {:forge_unverifiable, reason}}
    end
  end

  @doc false
  @spec create_empty_repo(String.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def create_empty_repo(name, org, opts) do
    desc = Keyword.get(opts, :description, "")

    result =
      repo_mod(opts).create_repo(
        name,
        Keyword.merge(opts, org: org, description: desc, auto_init: false)
      )

    classify_create_repo(result, org, name)
  end

  @doc false
  @spec origin_full_name(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def origin_full_name(dir, _opts) do
    case GitOps.read(["-C", dir, "config", "--get", "remote.origin.url"]) do
      {:ok, url} -> {:ok, origin_to_full_name(url)}
      {:error, _} = err -> err
    end
  end

  @doc false
  @spec origin_to_full_name(String.t()) :: String.t()
  def origin_to_full_name(url) do
    url
    |> String.trim()
    |> String.trim_trailing("/")
    |> String.replace_suffix(".git", "")
    |> String.split("/")
    |> Enum.take(-2)
    |> Enum.join("/")
  end

  @doc false
  @spec delete_forge(String.t(), keyword()) ::
          {:ok, :absent | :deleted} | {:error, term()}
  def delete_forge(full_name, opts) do
    repo_mod = repo_mod(opts)
    fc = fc_opts(opts)

    case repo_mod.default_branch(full_name, fc) do
      {:error, {:http, 404, _}} ->
        {:ok, :absent}

      {:error, reason} ->
        {:error, {:forge_check_failed, reason}}

      {:ok, _branch} ->
        with :ok <- repo_mod.delete_repo(full_name, fc), do: {:ok, :deleted}
    end
  end

  @doc false
  @spec fc_opts(keyword()) :: keyword()
  def fc_opts(opts), do: Keyword.get(opts, :forge_opts, [])

  @doc false
  @spec repo_mod(keyword()) :: module()
  def repo_mod(opts), do: Keyword.get(opts, :forge_repo, ForgeClient.Repo)

  @doc false
  @spec files_mod(keyword()) :: module()
  def files_mod(opts), do: Keyword.get(opts, :forge_files, ForgeClient.Files)

  # Probe org existence directly: a same-name personal account is not a catalogue org.
  # This does not authenticate the human or verify org membership.
  @doc false
  @spec ensure_catalogue_org_on_forge(String.t(), keyword()) :: :ok | {:error, term()}
  def ensure_catalogue_org_on_forge(org, opts) do
    users = Keyword.get(opts, :forge_users, ForgeClient.Repo)

    case users.org_exists?(org, fc_opts(opts)) do
      {:ok, true} ->
        :ok

      # Distinguish missing forge org from installed local material: interrupted install can leave both apart.
      {:ok, false} ->
        {:error, {:catalogue_not_installed, org, half_install_gesture(org)}}

      # An unreadable forge is not evidence of a missing org.
      {:error, reason} ->
        {:error, {:forge_preflight_failed, reason}}
    end
  end

  @doc false
  @spec half_install_gesture(String.t()) :: String.t()
  def half_install_gesture(org) do
    "the catalogue '#{org}' has its material on this container but its org does NOT exist on the forge — " <>
      "half an install. Nothing can be onboarded into it until the forge carries the org and its " <>
      "role accounts, and ONE gesture lays both: `lcars catalogue install #{org}`, played by an " <>
      "admin inside the container. Replaying it is the fix — it is convergent, and it is also how the " <>
      "material got here. `lcars catalogue list` shows what the forge actually carries."
  end

  # Seed protocol labels from code, not a copied forge template.
  @doc false
  @spec seed_protocol_labels(String.t(), keyword()) :: :ok | {:error, term()}
  def seed_protocol_labels(full_name, opts) do
    seeder =
      Keyword.get(opts, :ensure_labels, &ForgeClient.ensure_protocol_labels/2)

    case seeder.(full_name, fc_opts(opts)) do
      :ok -> :ok
      {:error, reason} -> {:error, {:protocol_labels, reason}}
    end
  end

  @doc false

  @spec classify_create_repo(
          {:ok, String.t() | :already_exists} | {:error, term()},
          String.t(),
          String.t()
        ) :: {:ok, String.t()} | {:error, term()}
  def classify_create_repo({:ok, full_name}, _org, _name) when is_binary(full_name),
    do: {:ok, full_name}

  def classify_create_repo({:ok, :already_exists}, org, name),
    do: {:error, {:repo_already_exists, "#{org}/#{name}"}}

  def classify_create_repo({:error, _} = err, _org, _name), do: err

  @doc false
  @spec repo_url(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def repo_url(full_name, opts) do
    base =
      Keyword.get(opts, :base_url) ||
        Application.get_env(:lcars_fleet, :pilot_forge, [])[:base_url]

    case base do
      b when is_binary(b) and b != "" ->
        {:ok, String.trim_trailing(b, "/") <> "/" <> full_name <> ".git"}

      _ ->
        {:error, {:config, {:missing, :base_url}}}
    end
  end
end
