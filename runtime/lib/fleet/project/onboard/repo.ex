defmodule Fleet.Project.Onboard.Repo do
  @moduledoc """
  Ce que l'onboarding demande a la FORGE, et rien d'autre : l'org du catalogue, le depot, ses
  labels de protocole, son URL, son origin.

  Tout est `@doc false` : c'est le vocabulaire forge de la famille onboarding, public seulement
  parce que les gestes vivent dans des modules voisins. La seule exception est
  `classify_create_repo/3`, qui etait deja publique et testee directement — une decision PURE sur
  le resultat d'une creation, sans forge en face.

  Les trois modules de seam (`repo_mod/1`, `files_mod/1`, et le seeder de labels) se lisent des
  `opts` : c'est ainsi qu'un temoin substitue la forge sans que rien ici ne connaisse un double.
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

  # L'ORG DU CATALOGUE EXISTE-T-ELLE SUR CETTE FORGE ? C'est la SEULE question que cette porte pose,
  # et elle la pose DIRECTEMENT.
  #
  # ⚠ ELLE NE VERIFIE PAS L'HUMAIN, et ce n'est pas un trou : l'admission est tenue UNE FOIS au
  # lancement — le BEAM refuse de demarrer sous un uid systeme et herite de cet uid pour ses pods.
  # Le verifier ici exigerait de l'humain un droit qu'il a deja et n'utilise pas : l'org est
  # publique donc il LIT, et ce n'est pas lui qui ecrit mais le JETON SYSTEME.
  #
  # ⚠ ET LE 404 NE SE DEDUIT PAS D'UNE AUTRE QUESTION : porte par la branche d'erreur d'un test
  # voisin, il ne tombe que si CE test-la rend 404 — donc jamais quand la reponse arrive autrement.
  # La question se pose EN DIRECT.
  #
  # ⚠ `org_exists?/2` ET PAS UNE SONDE SUR LES COMPTES : dans Gitea une org est une ligne de la MEME
  # table `user`, donc un compte PERSONNEL nomme comme le catalogue fait repondre 200 a
  # `/users/<nom>` sans qu'aucune org ne porte ses projets. Demande sur les comptes, le test rendait
  # `true` et le seul message qui nomme le geste manquant retombait en erreur brute.
  @doc false
  @spec ensure_catalogue_org_on_forge(String.t(), keyword()) :: :ok | {:error, term()}
  def ensure_catalogue_org_on_forge(org, opts) do
    users = Keyword.get(opts, :forge_users, ForgeClient.Repo)

    case users.org_exists?(org, fc_opts(opts)) do
      {:ok, true} ->
        :ok

      # LE MEME FAIT QUE `catalogue_not_installed`, MESURE A SA SOURCE. Le refus local lit le
      # materiel present sur la boite ; celui-ci demande a la forge si l'org existe. Les deux ne
      # peuvent diverger qu'entre les deux moities d'un install interrompu, et c'est precisement ce
      # cas-la qu'il faut nommer : sans lui l'appelant recevrait, deux gestes plus tard, un « user
      # redirect does not exist [name: web] / GetOrgByName » dont personne ne remonte jusqu'a « le
      # materiel est ici et la forge ne porte pas son org ».
      {:ok, false} ->
        {:error, {:catalogue_not_installed, org, half_install_gesture(org)}}

      # ON N'HABILLE PAS UNE LECTURE RATEE D'UN DIAGNOSTIC INVENTE : forge injoignable, jeton mort,
      # 500 — l'erreur remonte brute, et l'appelant sait qu'il n'a pas mesure.
      {:error, reason} ->
        {:error, {:forge_preflight_failed, reason}}
    end
  end

  @doc false
  @spec half_install_gesture(String.t()) :: String.t()
  def half_install_gesture(org) do
    "the catalogue '#{org}' has its material on this box but its org does NOT exist on the forge — " <>
      "half an install. Nothing can be onboarded into it until the forge carries the org and its " <>
      "role accounts, and ONE gesture lays both: `lcars catalogue install #{org}`, played by an " <>
      "admin inside the box. Replaying it is the fix — it is convergent, and it is also how the " <>
      "material got here. `lcars catalogue list` shows what the forge actually carries."
  end

  # BL-6-33
  #
  # ⚠ LES LABELS VIENNENT DU CODE, par le seul chemin qui existe — jamais recopies d'un depot
  # template par la forge (`labels: true` de `generate_repo`) : une source, pas une copie.
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
  # F-C084
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
