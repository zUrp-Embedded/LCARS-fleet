defmodule Fleet.Workflow.Provenance do
  @moduledoc """
  Le **triplet SHA** de la doctrine : provenance SLSA/in-toto d'un livrable (chantier brief-physique,
  cf. `beyond_#6/DESIGN-brief-physique-dispatch-unique-triplet-sha.md`).

  Assemble un in-toto Statement `(brief_sha, input_sha, livrable_sha)` — QUOI a été demandé (le brief),
  DE QUOI on est parti (l'état de base), CE QUI est sorti (le livrable) — et le committe content-addressé
  dans `livrables/<livrable_sha>-provenance.json`. **bash+jq+git côté doctrine ; ici Jason + Git, ZÉRO
  tooling externe** (pas de cosign, pas de SLSA CLI).

  - `livrable_sha` = subject digest + nom de fichier (l'autorité : la provenance d'UN livrable donné).
    Le livrable est un **commit git** (ce qui a été poussé) → son digest est étiqueté `gitCommit`
    (algo in-toto honnête), PAS `sha256` : c'est un SHA-1 de commit, pas un sha256 de contenu — mentir
    l'algorithme ferait échouer un vérifieur in-toto (le triplet doit être falsifiable, donc exact).
  - `brief_sha`/`brief_ref` = `invocation.configSource` (ce qui a été demandé — l'objet brief committé).
    Le brief EST content-addressé `sha256(contenu)` (cf. `BriefArtifact`) → digest `sha256`, lui vrai.
  - `input_sha` = `buildConfig.input_sha` (le `base_sha` pinné — l'état de départ ; champ nu, sans
    prétention d'algorithme).

  **Tolérant au dégradé** : si `brief_sha` manque (brief non matérialisé, cf. `BriefArtifact`), le Statement
  omet le digest du configSource mais grave quand même input→output (2/3 vaut mieux que 0). Idempotent par
  content-address (même `livrable_sha` = même fichier = no-op).
  """

  require Logger

  alias Fleet.Workflow.Git

  @livrables_subdir "livrables"
  @system_author {"lcars-system", "system@lcars.local"}
  @build_type "lcars-fleet-pipeline-v2"

  @type attrs :: %{
          required(:livrable_sha) => String.t(),
          optional(:brief_sha) => String.t() | nil,
          optional(:brief_ref) => String.t() | nil,
          optional(:input_sha) => String.t() | nil,
          optional(:subject_name) => String.t(),
          optional(:pod_id) => String.t() | nil,
          optional(:role) => String.t() | nil,
          optional(:issue) => term(),
          optional(:started_at) => String.t() | nil,
          optional(:finished_at) => String.t() | nil
        }

  @doc """
  Grave la provenance in-toto du livrable dans `work_dir` (`livrables/<livrable_sha>-provenance.json`),
  committée. `attrs.livrable_sha` REQUIS (l'ancre) ; le reste enrichit le Statement (dégrade si absent).

  `opts` : `:author` `{name, email}` (défaut système) ; `:push` `{remote, refspec}` (défaut commit local).
  `{:error, term()}` : work_dir absent / échec write / échec git — propagé (fail-loud, non fatal côté appelant).
  """
  @spec emit(Path.t(), attrs(), keyword()) :: {:ok, %{path: String.t(), ref: String.t()}} | {:error, term()}
  def emit(work_dir, %{livrable_sha: livrable_sha} = attrs, opts \\ [])
      when is_binary(work_dir) and is_binary(livrable_sha) and livrable_sha != "" do
    ref = Path.join(@livrables_subdir, livrable_sha <> "-provenance.json")
    abs = Path.join(work_dir, ref)

    cond do
      not safe_path_segment?(livrable_sha) ->
        # BND-120: `livrable_sha` is interpolated into the provenance FILE PATH
        # (`livrables/<sha>-provenance.json`). A separator/traversal (`/`, `\`, `..`) would escape the
        # work/ops dir. It IS a git commit digest (hex) in production — a value carrying a path separator
        # is refused, never trusted as a path segment.
        {:error, {:invalid_livrable_sha, livrable_sha}}

      not File.dir?(work_dir) ->
        {:error, {:work_dir_missing, work_dir}}

      File.exists?(abs) ->
        {:ok, %{path: abs, ref: ref}}

      true ->
        write_and_commit(work_dir, abs, ref, statement(attrs), opts)
    end
  end

  # Path-SAFE segment for the provenance filename (BND-120): no separator, no traversal.
  defp safe_path_segment?(s), do: not String.contains?(s, ["/", "\\", ".."])

  @doc "Le Statement in-toto (map JSON-able) — pur, sans I/O (testable + réutilisable)."
  @spec statement(attrs()) :: map()
  def statement(%{livrable_sha: livrable_sha} = a) do
    %{
      "_type" => "https://in-toto.io/Statement/v0.1",
      "subject" => [
        # `gitCommit` (pas `sha256`) : le livrable est le commit git publié (SHA-1), pas un sha256 de
        # contenu — étiquette honnête, sans quoi un vérifieur in-toto échouerait sur l'algorithme.
        %{"name" => Map.get(a, :subject_name, "deliverable"), "digest" => %{"gitCommit" => livrable_sha}}
      ],
      "predicateType" => "https://slsa.dev/provenance/v1.0",
      "predicate" => %{
        "buildType" => @build_type,
        # configSource = ce qui a été demandé : l'objet brief committé. Digest omis si brief non matérialisé
        # (dégradé) — le triplet devient un couple input→output, jamais une provenance qui MENT un brief_sha.
        "invocation" => %{"configSource" => config_source(a)},
        "buildConfig" =>
          drop_nil(%{
            "input_sha" => Map.get(a, :input_sha),
            "pod_id" => Map.get(a, :pod_id),
            "role" => Map.get(a, :role),
            "issue" => Map.get(a, :issue)
          }),
        "metadata" =>
          drop_nil(%{
            "buildStartedOn" => Map.get(a, :started_at),
            "buildFinishedOn" => Map.get(a, :finished_at),
            "completeness" => %{"parameters" => true, "environment" => false, "materials" => true}
          })
      }
    }
  end

  defp config_source(a) do
    case Map.get(a, :brief_sha) do
      sha when is_binary(sha) and sha != "" ->
        drop_nil(%{"uri" => Map.get(a, :brief_ref), "digest" => %{"sha256" => sha}})

      _ ->
        # Brief non matérialisé : on note l'uri si connue, jamais un digest inventé.
        drop_nil(%{"uri" => Map.get(a, :brief_ref)})
    end
  end

  defp write_and_commit(work_dir, abs, ref, statement, opts) do
    with {:ok, json} <- encode(statement),
         :ok <- File.mkdir_p(Path.dirname(abs)),
         :ok <- File.write(abs, json),
         {:ok, _sha} <- Git.commit(commit_opts(work_dir, ref, opts)),
         :ok <- maybe_push(work_dir, opts) do
      {:ok, %{path: abs, ref: ref}}
    end
  end

  defp encode(statement) do
    {:ok, Jason.encode!(statement, pretty: true) <> "\n"}
  rescue
    e -> {:error, {:provenance_encode_failed, Exception.message(e)}}
  end

  defp commit_opts(work_dir, ref, opts) do
    {name, email} = Keyword.get(opts, :author, @system_author)

    %{
      workspace: work_dir,
      author_name: name,
      author_email: email,
      committer_name: name,
      committer_email: email,
      message: "provenance: #{ref}",
      add_paths: [ref]
    }
  end

  defp maybe_push(work_dir, opts) do
    case Keyword.get(opts, :push) do
      nil -> :ok
      {remote, refspec} -> Git.push(work_dir, remote, refspec)
    end
  end

  defp drop_nil(map), do: :maps.filter(fn _k, v -> not is_nil(v) end, map)
end
