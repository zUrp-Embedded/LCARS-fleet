defmodule Fleet.Workflow.BriefArtifact do
  @moduledoc """
  Le brief comme OBJET de première classe (chantier brief-physique, cf.
  `beyond_#6/DESIGN-brief-physique-dispatch-unique-triplet-sha.md`).

  Matérialise le contenu d'un brief en artefact **content-addressé** committé dans le worktree
  work/ops du système (`<work_dir>/briefs/<sha256>.md`) et rend `{ref, sha}` — le `brief_sha` du
  triplet SLSA `(brief_sha, input_sha, livrable_sha)`. Le work_item ne porte plus la string du brief
  mais ce pointeur ; le pod lit l'objet et **vérifie le sha** avant d'agir (le pointeur peut mentir,
  l'objet non).

  **Idempotence par content-address** : même contenu ⇒ même chemin ⇒ no-op (`File.exists?`). Un
  re-brief identique (retry, reroll) ne recrée rien et ne conflit jamais ; seul un contenu DIFFÉRENT
  produit un nouvel objet, à un chemin différent → jamais de conflit de contenu sur la branche work/ops.

  `sha` = **sha256(contenu)** (pas le blob-sha git : le triplet in-toto est en sha256, et le pod le
  recalcule sur les bytes lus pour vérifier). Le commit git DURABILISE l'objet ; `sha` reste l'autorité.
  """

  require Logger

  alias Fleet.Workflow.Git

  @briefs_subdir "briefs"
  @system_author {"lcars-system", "system@lcars.local"}

  @type ok :: %{ref: String.t(), sha: String.t()}

  @doc """
  Committe le `content` du brief dans `work_dir` (worktree work/ops du projet) sous
  `briefs/<sha256>.md`, et rend `{:ok, %{ref, sha}}`. Idempotent (contenu déjà présent → no-op).

  `opts` : `:author` = `{name, email}` (défaut système) ; `:push` = `{remote, refspec}` pour publier
  l'objet sur la forge (défaut : commit LOCAL seul — la publication est une décision de l'appelant,
  comme `Deliverable` sépare commit et push).

  `{:error, term()}` : work_dir absent / non-git, échec write, échec git (propagé tel quel — fail-loud).
  """
  @spec commit(Path.t(), String.t(), keyword()) :: {:ok, ok()} | {:error, term()}
  def commit(work_dir, content, opts \\ []) when is_binary(work_dir) and is_binary(content) do
    sha = sha256_hex(content)
    ref = Path.join(@briefs_subdir, sha <> ".md")
    abs = Path.join(work_dir, ref)

    cond do
      not File.dir?(work_dir) ->
        {:error, {:work_dir_missing, work_dir}}

      File.exists?(abs) ->
        # content-addressé : l'objet existe déjà (même contenu) → rien à recommitter.
        {:ok, %{ref: ref, sha: sha}}

      true ->
        materialize(work_dir, abs, ref, sha, content, opts)
    end
  end

  @doc """
  Augmente des attrs d'enqueue (`%{brief: content, ...}`) avec l'artefact physique : committe le brief
  dans le worktree work/ops du projet `repo` (`<work_root>/<name>`) et ajoute `:brief_ref`/`:brief_sha`.
  Le funnel « même code » que les deux sites d'enqueue partagent.

  **DÉGRADE, ne casse JAMAIS le dispatch** : pas de brief / brief vide / `repo` nil / work_dir absent
  (projet non-onboardé) / échec git → attrs INCHANGÉS (brief string seule), warning LOUD. La provenance
  est désirable, pas load-bearing pour la livraison — un projet sans work/ops dispatche quand même.

  `opts[:work_root]` (défaut `Fleet.Layout.work_root/0`) — injectable pour le test.
  """
  @spec physicalize_attrs(map(), String.t() | nil, keyword()) :: map()
  def physicalize_attrs(attrs, repo, opts \\ [])

  def physicalize_attrs(%{brief: brief} = attrs, repo, opts)
      when is_binary(brief) and brief != "" and is_binary(repo) and repo != "" do
    work_root = Keyword.get(opts, :work_root, Fleet.Layout.work_root())
    work_dir = Path.join(work_root, project_name(repo))

    case commit(work_dir, brief) do
      {:ok, %{ref: ref, sha: sha}} ->
        Map.merge(attrs, %{brief_ref: ref, brief_sha: sha})

      {:error, reason} ->
        Logger.warning(
          "BriefArtifact: brief NON matérialisé (repo=#{repo}) : #{inspect(reason)} — " <>
            "string seule (dégradé, dispatch préservé)"
        )

        attrs
    end
  end

  def physicalize_attrs(attrs, _repo, _opts), do: attrs

  # `owner/name` → `name` (le work/ops est à `<work_root>/<name>`, cf. ProjectOnboard).
  defp project_name(repo), do: repo |> String.split("/") |> List.last()

  defp materialize(work_dir, abs, ref, sha, content, opts) do
    with :ok <- File.mkdir_p(Path.dirname(abs)),
         :ok <- File.write(abs, content),
         {:ok, _commit_sha} <- Git.commit(commit_opts(work_dir, ref, opts)),
         :ok <- maybe_push(work_dir, opts) do
      {:ok, %{ref: ref, sha: sha}}
    end
  end

  defp commit_opts(work_dir, ref, opts) do
    {name, email} = Keyword.get(opts, :author, @system_author)

    %{
      workspace: work_dir,
      author_name: name,
      author_email: email,
      committer_name: name,
      committer_email: email,
      message: "brief: #{ref}",
      # `add_paths` limité à l'objet — jamais `["."]` (on ne balaie pas un worktree work/ops entier
      # dans un commit de brief : un seul objet, atomique).
      add_paths: [ref]
    }
  end

  # Publication optionnelle sur la forge (l'objet devient une URL — le `configSource.uri` du triplet).
  # Défaut : pas de push (commit local). L'appelant qui veut la durabilité forge passe `:push`.
  defp maybe_push(work_dir, opts) do
    case Keyword.get(opts, :push) do
      nil -> :ok
      {remote, refspec} -> Git.push(work_dir, remote, refspec)
    end
  end

  defp sha256_hex(content), do: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
end
