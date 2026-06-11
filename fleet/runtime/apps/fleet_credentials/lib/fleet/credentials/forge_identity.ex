defmodule Fleet.Credentials.ForgeIdentity do
  @moduledoc """
  Z4 (forge-identité B') — résout l'identité git d'un livrable : **author = l'humain
  du mandat**, le rôle LCARS étant porté par un trailer **vérifié** `Co-authored-by:
  LCARS-<role>` (non-négo #1 : l'identité n'est JAMAIS aplatie sur un compte partagé ;
  la signature machine est un trailer vérifié, pas l'auteur).

  ## D'où vient l'humain

  L'humain du mandat = **l'user du process runtime** (`id -un`). Doctrine 2026-06-11 :
  la fleet ENTIÈRE tourne sous l'user OS de l'humain qui la lance (`User=<humain>`) —
  chaque humain = sa fleet sous son user, isolation OS par construction ; le pod (Port
  BEAM) hérite cet UID. Donc l'user courant EST l'humain. Pas de défaut littéral
  (masquerait un trou de câblage — I-CBC) : `id -un` irrésoluble → fail-loud.

  ## D'où vient son name/email git — l'OS, pas un catalogue

  Doctrine 2026-06-11 : **si l'user existe sur le système, c'est un humain de la fleet**
  — on ne re-filtre pas par un catalogue (supprimé). L'identité git se DÉRIVE de l'OS,
  dans l'ordre :

    * **name**  : `git config --global user.name` (le daemon tourne *as* l'humain → lit
      son `~/.gitconfig`, l'identité avec laquelle il commite DÉJÀ) → sinon GECOS
      (`getent passwd`) → sinon le login.
    * **email** : `git config --global user.email` → sinon `<login>@<hostname>`
      (convention git par défaut).

  Aucune lecture de fichier, aucun knob à provisionner, aucun fail-loud « humain absent
  du catalogue » : un user OS ⇒ toujours une identité. (Seam test : `opts[:identity]`
  ou `config :fleet_credentials, :forge_identity_override` — `git config` varie par runner.)

  ## Trailer rôle

  `Co-authored-by: LCARS-<role> <<role>@lcars.local>` — le trailer est ce que la gate
  F-01 vérifie (présence + rôle ↔ stage). Pure string, vérifiable mécaniquement.

  ## allowed_emails (gate F-01)

    * `git_native` — le pod commite EN TANT QUE l'humain → author=committer=humain →
      `[human_email]`.
    * `payload` — le SYSTÈME commite (author=humain, committer=système, D-04) →
      `[human_email, "system@lcars.local"]`.
  """

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
  `:human` (override, défaut `id -un`), `:identity` (map `%{name, email}` injectée —
  tests, court-circuite la dérivation OS).

  `{:ok, identity}` | `{:error, reason}` (fail-loud uniquement si `id -un` irrésoluble).
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
  # %{name, email, human?}) court-circuite TOUT (seam test : `id -un`/`git config`
  # varient par runner). Un `:identity` explicite (forge_identity_test) désactive
  # l'override pour tester la VRAIE assemblée. Sinon : humain (`id -un`) → identité OS.
  defp resolve_identity(opts) do
    override = Application.get_env(:fleet_credentials, :forge_identity_override)
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

  # Identité OS de l'humain. `opts[:identity]` (test) court-circuite. Sinon dérive :
  # git config (l'identité de commit du humain) → GECOS → login ; email → <login>@<host>.
  # Ne FAIL JAMAIS : un user OS ⇒ toujours une identité (« on n'over-filtre pas »).
  defp os_identity(human, opts) do
    case Keyword.get(opts, :identity) do
      %{name: name, email: email} when is_binary(name) and is_binary(email) ->
        {:ok, %{name: name, email: email}}

      _ ->
        name = git_config("user.name") || gecos_name(human) || human
        email = git_config("user.email") || "#{human}@#{hostname()}"
        {:ok, %{name: name, email: email}}
    end
  end

  # `git config --global --get <key>` du humain (daemon tourne *as* lui → ~/.gitconfig).
  # git absent / clé non set → nil (→ fallback).
  defp git_config(key) do
    case System.cmd("git", ["config", "--global", "--get", key], stderr_to_stdout: true) do
      {out, 0} -> blank_to_nil(String.trim(out))
      _ -> nil
    end
  rescue
    _ -> nil
  end

  # GECOS (champ 5 de `getent passwd`, avant la 1re virgule) = nom complet, ou nil.
  defp gecos_name(human) do
    case System.cmd("getent", ["passwd", human], stderr_to_stdout: true) do
      {line, 0} ->
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

  defp hostname do
    case :inet.gethostname() do
      {:ok, h} -> List.to_string(h)
      _ -> "localhost"
    end
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(s) when is_binary(s), do: s
end
