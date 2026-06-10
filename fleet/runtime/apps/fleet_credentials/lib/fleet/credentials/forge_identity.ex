defmodule Fleet.Credentials.ForgeIdentity do
  @moduledoc """
  Z4 (forge-identité B') — résout l'identité git d'un livrable : **author = l'humain
  du mandat**, le rôle LCARS étant porté par un trailer **vérifié** `Co-authored-by:
  LCARS-<role>` (non-négo #1 : l'identité n'est JAMAIS aplatie sur un compte partagé ;
  la signature machine est un trailer vérifié, pas l'auteur).

  ## D'où vient l'humain

  L'humain du mandat = **l'user du process runtime** (`id -un`). Décision 2026-06-09
  (cf. `Fleet.Spawner.Pod` : « sur cette instance les SEULS users sont les users fleet
  → l'user courant EST l'humain » ; le pod hérite de cet UID). Pas de défaut littéral
  (un défaut masque un trou de câblage — I-CBC) : irrésoluble → fail-loud.

  ## D'où vient son name/email git

  D'un **catalogue** `settings_users.yaml` provisionné à l'install LCARS (onboarding
  live — DN installeur déférée). Format :

      users:
        <login>:
          name:  "Prénom Nom"
          email: "addr@exemple.tld"

  Chemin : `opts[:catalog_path]` > `config :fleet_credentials, :users_catalog_path`
  (env `LCARS_USERS_CATALOG`) > placeholder `runtime/settings_users.yaml`. Le path est
  un **knob** : le remplir/déplacer à l'install n'exige pas de recompiler. Humain absent
  du catalogue OU fichier illisible → **fail-loud** (pas d'identité devinée).

  ## Trailer rôle

  `Co-authored-by: LCARS-<role> <<role>@lcars.local>` — l'email `<role>@lcars.local`
  matche l'ancienne identité role-based (compat F-01) ; le trailer est ce que la gate
  F-01 vérifie (présence + rôle ↔ stage). Pure string, vérifiable mécaniquement.

  ## allowed_emails (gate F-01)

    * `git_native` — le pod commite EN TANT QUE l'humain → author=committer=humain →
      `[human_email]`.
    * `payload` — le SYSTÈME commite (author=humain, committer=système, D-04) →
      `[human_email, "system@lcars.local"]`.
  """

  @placeholder_catalog "runtime/settings_users.yaml"
  @role_email_domain "lcars.local"
  @system_email "system@lcars.local"

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
  Identité git complète pour un `role` (author=humain + trailer rôle). `opts` :
  `:human` (override, défaut `id -un`), `:catalog_path` (override), `:catalog`
  (map injectée directement — tests, court-circuite la lecture fichier).

  `{:ok, identity}` | `{:error, reason}` (fail-loud : humain/catalogue irrésoluble).
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

  @doc "Trailer machine vérifiable du rôle (Co-authored-by canon)."
  @spec coauthor_trailer(String.t()) :: String.t()
  def coauthor_trailer(role) when is_binary(role) do
    "Co-authored-by: LCARS-#{role} <#{role}@#{@role_email_domain}>"
  end

  @doc """
  Emails d'identité acceptés par la gate F-01 selon le mode. `git_native` → l'humain
  seul (il commite) ; `payload` → l'humain (author) + système (committer).
  """
  @spec allowed_emails(:git_native | :payload, String.t()) :: [String.t()]
  def allowed_emails(:git_native, human_email), do: [human_email]
  def allowed_emails(:payload, human_email), do: [human_email, @system_email]

  @doc """
  Identité système (committer en mode payload). Le système N'EST PAS l'humain : il
  matérialise le commit, l'author reste l'humain (D-04).
  """
  @spec system_email() :: String.t()
  def system_email, do: @system_email

  # ── internals ──

  defp resolve_human(opts) do
    case Keyword.get(opts, :human) do
      h when is_binary(h) and h != "" ->
        {:ok, h}

      _ ->
        case System.cmd("id", ["-un"], stderr_to_stdout: true) do
          {out, 0} -> {:ok, String.trim(out)}
          other -> {:error, {:human_unresolved, other}}
        end
    end
  end

  # Résout {name, email, human}. Override config `:forge_identity_override` (map
  # %{name, email, human?}) court-circuite TOUT (seam test : `id -un` varie par runner,
  # le catalogue n'existe pas en test) → tous les callers (pod.ex/hop_consumer/executor)
  # obtiennent une identité fixe. Sinon : humain (`id -un`) → lookup catalogue.
  defp resolve_identity(opts) do
    override = Application.get_env(:fleet_credentials, :forge_identity_override)
    # un `:catalog`/`:catalog_path` explicite (forge_identity_test teste la VRAIE résolution)
    # désactive l'override — sinon l'override gagne (seam test pour les callers réels).
    explicit_catalog? = Keyword.has_key?(opts, :catalog) or Keyword.has_key?(opts, :catalog_path)

    case override do
      %{name: name, email: email} = ov
      when is_binary(name) and is_binary(email) and not explicit_catalog? ->
        {:ok, %{name: name, email: email, human: Map.get(ov, :human, "override")}}

      _ ->
        with {:ok, human} <- resolve_human(opts),
             {:ok, %{name: name, email: email}} <- lookup(human, opts) do
          {:ok, %{name: name, email: email, human: human}}
        end
    end
  end

  defp lookup(human, opts) do
    with {:ok, catalog} <- load_catalog(opts),
         %{} = users <- Map.get(catalog, "users", %{}),
         %{} = entry <- Map.get(users, human) do
      name = entry["name"]
      email = entry["email"]

      if is_binary(name) and name != "" and is_binary(email) and email != "" do
        {:ok, %{name: name, email: email}}
      else
        {:error, {:catalog_entry_invalid, human}}
      end
    else
      nil -> {:error, {:human_not_in_catalog, human}}
      {:error, _} = err -> err
      _ -> {:error, {:catalog_malformed, human}}
    end
  end

  # `:catalog` injecté (tests) court-circuite le fichier. Sinon lecture YAML fail-loud.
  defp load_catalog(opts) do
    case Keyword.get(opts, :catalog) do
      %{} = c ->
        {:ok, c}

      _ ->
        path = catalog_path(opts)

        case YamlElixir.read_from_file(path) do
          {:ok, %{} = data} -> {:ok, data}
          {:ok, _} -> {:error, {:catalog_malformed, path}}
          {:error, reason} -> {:error, {:catalog_unreadable, path, reason}}
        end
    end
  end

  defp catalog_path(opts) do
    Keyword.get(opts, :catalog_path) ||
      Application.get_env(:fleet_credentials, :users_catalog_path) ||
      @placeholder_catalog
  end
end
