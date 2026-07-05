defmodule Fleet.Workflow.Deliverable do
  @moduledoc """
  Publication unifiée du livrable d'un pod — **un seul** module, deux modes sélectionnés
  par `spec.deliverable_mode` au catalogue (condition d'entrée), PAS deux modules déguisés. Filtre
  unification : « différenciation par catalogue, pas par branche de code » (même règle que
  `lifetime_scope`).

  Frontière pod↔système. Le pod produit du CONTENU (un payload de fichiers, OU des commits git natifs) ;
  le système le transforme en livrable durable poussé sur la forge. Le pod n'a conscience NI des
  branches NI de la forge (forge-aveugle) — c'est le système qui choisit la branche cible et
  pousse. `git` donne l'isolation du livrable ; `bwrap` donne l'isolation du FS.

  ## Les trois temps (ordre fixe, identique aux 2 modes pour 2 et 3)

      1. CONTENU (seule branche du mode) :
         :payload    → `PayloadGuard.apply_files` (valide-sécurité PUIS écrit les fichiers)
                       + `Git.commit` (le SYSTÈME commite)
         :git_native → l'agent a déjà commité → on vérifie juste qu'un commit existe (base != HEAD)
      2. GATE DURCIE — PARTAGÉE : `DeliverableGate.verify` (base ancêtre, identité, secrets).
         Un livrable invalide est rendu irreprésentable au push (pas rattrapé après).
      3. PUSH borné — `Git.push(remote, local_ref:target_branch)` sinon fail-loud.

  `base_sha` est verrouillée HORS du pod (capturée par le rail forge-driven, épinglée au clone par
  `ProjectBootstrap.pin_base_sha`) — le pod ne peut pas la falsifier. La gate lit le `.git` du
  workspace en read-only et ne croit AUCUNE assertion du pod.

  Garde-fou unification : la SEULE divergence de mode est le temps 1 (qui commite). Les temps 2 et 3
  sont strictement partagés. Si un jour le `case mode` métastase (un `if` qui sépare 80 % du tronc),
  l'unification est à reconsidérer.
  """

  require Logger

  alias Fleet.Workflow.{DeliverableGate, Git, PayloadGuard}

  @type mode :: :payload | :git_native

  @type opts :: %{
          required(:mode) => mode(),
          required(:workspace) => Path.t(),
          required(:base_sha) => String.t(),
          required(:allowed_emails) => [String.t()],
          optional(:remote) => String.t(),
          optional(:target_branch) => String.t(),
          optional(:push?) => boolean(),
          optional(:local_ref) => String.t(),
          # Rôle attendu pour le trailer `Co-authored-by` ; nil/absent → skip.
          optional(:coauthor_role) => String.t() | nil,
          # mode :payload uniquement
          optional(:files) => [map()],
          optional(:identity) => map(),
          optional(:message) => String.t(),
          optional(:add_paths) => [String.t()]
        }

  @type result :: %{commit_sha: String.t(), pushed?: boolean(), mode: mode()}

  # Plus AUCUNE invocation git directe ici (X1 2026-07-04) : les rev-parse sont délégués à
  # `Fleet.Workflow.Git.read_head_sha/1` (borné, qui compose lui-même git_safe_config_args).

  @common_keys [:mode, :workspace, :base_sha, :allowed_emails]
  @payload_keys [:files, :identity, :message]
  @identity_keys [:author_name, :author_email, :committer_name, :committer_email]

  @doc """
  Publie le livrable : CONTENU (mode) → GATE (partagée) → PUSH. Retourne `{:ok, %{commit_sha,
  pushed?, mode}}` ou le PREMIER `{:error, reason}` (fail-loud à chaque temps ; aucun push si la gate
  refuse). `push?` défaut `true` ; `local_ref` défaut `"HEAD"`.
  """
  @spec publish(opts()) :: {:ok, result()} | {:error, term()}
  def publish(opts) when is_map(opts) do
    with :ok <- validate(opts),
         :ok <- materialize_content(opts),
         {:ok, :verified} <-
           DeliverableGate.verify(
             opts.workspace,
             opts.base_sha,
             opts.allowed_emails,
             Map.get(opts, :coauthor_role)
           ),
         {:ok, sha} <- head_sha(opts.workspace),
         {:ok, pushed?} <- push_deliverable(opts) do
      {:ok, %{commit_sha: sha, pushed?: pushed?, mode: opts.mode}}
    end
  end

  # ============================================================
  # Validation (fail-closed)
  # ============================================================

  defp validate(opts) do
    with :ok <- check_keys(opts, @common_keys),
         :ok <- check_mode(opts.mode),
         :ok <- check_mode_keys(opts),
         :ok <- check_push_keys(opts) do
      :ok
    end
  end

  defp check_keys(opts, keys) do
    case Enum.reject(keys, &Map.has_key?(opts, &1)) do
      [] -> :ok
      missing -> {:error, {:missing_opts, missing}}
    end
  end

  defp check_mode(m) when m in [:payload, :git_native], do: :ok
  defp check_mode(m), do: {:error, {:invalid_mode, m}}

  # Mode payload : les clés de contenu sont requises. Mode git_native : le contenu vient du pod, rien
  # à fournir (la présence du commit est vérifiée à `materialize_content`).
  defp check_mode_keys(%{mode: :payload} = opts) do
    with :ok <- check_keys(opts, @payload_keys),
         :ok <- check_keys(opts.identity, @identity_keys) do
      :ok
    end
  end

  defp check_mode_keys(_opts), do: :ok

  # Push (défaut true) requiert remote + target_branch + un refspec bien formé. Si push?
  # explicitement false (commit local), ils sont facultatifs.
  defp check_push_keys(opts) do
    if push?(opts) do
      with :ok <- check_keys(opts, [:remote, :target_branch]),
           :ok <- check_ref(opts.target_branch),
           :ok <- check_ref(local_ref(opts)) do
        :ok
      end
    else
      :ok
    end
  end

  # Validation du refspec (`<local_ref>:<target_branch>`) déléguée à l'AUTORITÉ UNIQUE
  # `Fleet.Workflow.GitRef` (la regex check-ref-format vivait ici en double avec `Git`). On garde la
  # forme d'erreur typée propre à ce module (qui porte le `ref` fautif).
  defp check_ref(ref) do
    if Fleet.Workflow.GitRef.valid?(ref), do: :ok, else: {:error, {:invalid_ref, ref}}
  end

  # ============================================================
  # Temps 1 — CONTENU (seule divergence de mode)
  # ============================================================

  # Placement + validation-sécurité du payload (path-traversal / `.git` / `.gitattributes`
  # armé / symlink) délégués à l'autorité unique `Fleet.Workflow.PayloadGuard` (filtre
  # extrait C4 2026-07-05 — le POURQUOI de chaque vecteur fermé y est documenté).
  defp materialize_content(%{mode: :payload} = opts) do
    with :ok <- PayloadGuard.apply_files(opts.workspace, opts.files),
         {:ok, _sha} <- Git.commit(commit_opts(opts)) do
      :ok
    end
  end

  # git_native : l'agent a commité dans le pod. On NE crée rien — on vérifie juste qu'un livrable
  # existe (HEAD a avancé depuis base). Range vide = le brief n'a produit aucun commit → fail-loud
  # (la gate, elle, passe sur range vide par vacuité ; la présence d'un commit est un concern mode-side).
  # Le cas « HEAD != base mais historique réécrit » passe ici (avancé) et est rattrapé par la gate
  # (`base_not_ancestor`) — pas de double check ici.
  defp materialize_content(%{mode: :git_native} = opts) do
    if head_advanced?(opts.workspace, opts.base_sha),
      do: :ok,
      else: {:error, :no_deliverable_commit}
  end

  # Lecture HEAD déléguée à l'autorité BORNÉE Fleet.Workflow.Git.read_head_sha/1 (X1 2026-07-04 :
  # ce site était un System.cmd BRUT sans deadline — un rev-parse pendu bloquait la publication).
  # Échec de lecture → false = « pas de commit détecté » → l'appelant rend
  # {:error, :no_deliverable_commit} (échec EXPLICITE, pas un silence).
  defp head_advanced?(workspace, base_sha) do
    case Fleet.Workflow.Git.read_head_sha(workspace) do
      {:ok, sha} -> sha != base_sha
      {:error, _} -> false
    end
  end

  defp commit_opts(opts) do
    opts.identity
    |> Map.take(@identity_keys)
    |> Map.merge(%{
      workspace: opts.workspace,
      message: opts.message,
      add_paths: Map.get(opts, :add_paths, ["."])
    })
  end

  # ============================================================
  # Temps 3 — PUSH (partagé)
  # ============================================================

  defp push_deliverable(opts) do
    if push?(opts) do
      refspec = "#{local_ref(opts)}:#{opts.target_branch}"
      Git.push(opts.workspace, opts.remote, refspec)
    else
      {:ok, false}
    end
  end

  defp push?(opts), do: Map.get(opts, :push?, true)
  defp local_ref(opts), do: Map.get(opts, :local_ref, "HEAD")

  # X1/D4 2026-07-04 : délégué à l'autorité bornée (même forme d'erreur {:rev_parse_failed, rc, err},
  # enrichie de {:rev_parse_timeout|:rev_parse_exit} que le System.cmd brut ne savait pas produire).
  defp head_sha(workspace), do: Fleet.Workflow.Git.read_head_sha(workspace)
end
