defmodule Fleet.Project.Onboard.Card do
  @moduledoc """
  La CARTE d'un projet : la reviser, et remettre son rail CI dans l'etat que la carte decrit.

  Une carte decide comment un projet est traite — quel jury, quelle exigence de CI. La changer sur
  un projet vivant demande donc d'ecrire la declaration ET de faire converger ce qui en depend,
  sans quoi la boite juge selon l'ancienne carte en affichant la nouvelle.
  """

  alias Fleet.Project.GitOps
  alias Fleet.Project.Onboard
  alias Fleet.Project.Onboard.Faces
  alias Fleet.Project.Onboard.Repo
  alias Fleet.Project.Onboard.Scaffold
  alias Fleet.Project.Roles

  require Logger

  # ─── LE RAIL CI D'UN DEPOT QUI VIENT D'AILLEURS ─────────────────────────────────────────────────
  #
  # La protection de `main` exige un statut `CI / *`. Un depot sans `.gitea/workflows/` n'en produit
  # AUCUN, jamais : aucune PR ne peut fusionner, et la chaine de livraison est morte avant son
  # premier ticket. `CIGate` lit deja cette impasse et la nomme (`{:ci_impossible, :no_workflow}`),
  # mais la NOMMER laisse quelqu'un ecrire le fichier — et c'est ainsi qu'il atterrit avec un
  # `runs-on:` qu'aucun runner ne sert, en attente pour toujours au lieu d'echouer.
  #
  # SEULES LES PORTES QUI FONT ENTRER DU CONTENU ETRANGER l'appellent. `import/2` RAPATRIE un depot
  # deja dans l'org : il y est arrive par la creation, l'adoption ou l'import externe, donc il porte
  # deja ses workflows par construction.
  #
  # ⚠ `Scaffold.main/3` NE POUVAIT PAS SERVIR : il ecrit la face ENTIERE (README, CLAUDE.md,
  # .gitignore), ce qui est juste pour un depot que la fleet vient de creer et destructeur pour un
  # depot qu'elle importe. Cette porte-ci n'ajoute que ce qui MANQUE.
  # LA POSTURE DU RAIL SE LIT SUR LA CARTE, ET LE DEFAUT EST L'INVITATION A PROUVER. Une carte
  # illisible, absente, ou un catalogue casse rendent `:required` : le projet recoit un rail qui
  # l'invite a poser sa suite. La dispense ne s'obtient que d'une carte qui la DECLARE.
  @doc """
  RÉÉCRIT le rail CI de `full_name` sur `main` depuis le template livré, et le pousse.

  ⚠ **LA SORTIE DE SECOURS DU PLANCHER, ET RIEN D'AUTRE.** `protect_main` exige un statut `CI / *`
  de tout le monde ; un `ci.yml` cassé — image sans `node`, `runs-on:` qu'aucun runner ne sert,
  workflow renommé hors de `CI` — n'en produit plus. Aucune PR ne fusionne, et **personne ne peut le
  réparer côté forge** : les humains y sont en `read`. Ce verbe remet le rail livré, vert par
  construction, et le pousse par le même lift ponctuel que la révision de carte.

  ⚠ **IL ÉCRASE, ET C'EST TOUT SON OBJET.** `Scaffold.ci_workflows/3` ne touche jamais un fichier
  existant — la bonne règle quand on ADOPTE. Ici on répare : le fichier existant EST le défaut.
  D'où `justification` requise, comme pour une révision de carte : ce geste remplace le travail de
  quelqu'un, il ne se joue pas par accident.

  ⚠ **SUR `main`, PAS SUR UNE BRANCHE DE PR.** Le rail de `main` est ce dont héritent les branches
  suivantes ; une PR déjà ouverte se répare par son producteur, à qui le brief de rework nomme le
  job en échec. Pousser sur la branche d'un pod vivant courserait avec lui.

  `opts` : `:justification` (requise), `:reset_by` (le rôle qui agit).
  Rend `%{repo:, outcome: :reset | :unchanged, files:}`.
  """
  @spec reset_ci_rail(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def reset_ci_rail(full_name, opts \\ []) when is_binary(full_name) do
    name = Fleet.Layout.project_name(full_name)
    proj_dir = Path.join(Faces.code_root(opts), name)

    with :ok <- Onboard.require_on_machine(full_name, proj_dir),
         :ok <- require_justification(opts),
         {:ok, url} <- Repo.repo_url(full_name, opts) do
      scratch = scratch_dir(name)

      try do
        with :ok <- Faces.clone_main(url, scratch),
             {:ok, files} <-
               Scaffold.reset_ci_workflows(scratch, name, Onboard.with_ci_stance(full_name, opts)),
             {:ok, :changed} <- revision_changed(scratch) do
          publish_ci_rail(full_name, scratch, files, opts)
        else
          {:ok, :unchanged} ->
            {:ok, %{repo: full_name, outcome: :unchanged, files: []}}

          {:error, _} = err ->
            err
        end
      after
        _ = File.rm_rf(scratch)
      end
    end
  end

  defp publish_ci_rail(full_name, scratch, files, opts) do
    msg = "ci(reset): rail CI remis a l'etat livre (#{Enum.join(files, ", ")})"

    with :ok <- Faces.commit(scratch, msg),
         :ok <- lift_protection(full_name, opts) do
      case Faces.push(scratch, "main", false) do
        :ok ->
          protection = restore_protection(full_name, opts)

          Logger.info(
            "ProjectOnboard: #{full_name} rail CI remis a l'etat livre — #{Enum.join(files, ", ")}"
          )

          {:ok,
           %{repo: full_name, outcome: :reset, files: files, protection: to_string(protection)}}

        {:error, reason} ->
          _ = restore_protection(full_name, opts)
          {:error, {:ci_rail_push_failed, reason}}
      end
    end
  end

  @doc """
  Revises the validation card of an existing project. `BL-6-29`

  The new declaration must be loadable and justified. It is committed from a disposable clone,
  pushed through a system-only protection lift, followed by restoration of the canonical rule and
  best-effort showcase synchronization. Push failure restores protection and reports an error;
  restore failure after a landed push is returned in the successful result. An identical declaration
  is an `:unchanged` no-op. Existing issues retain their engraved route.
  """
  @spec revise_card(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def revise_card(full_name, opts \\ []) when is_binary(full_name) do
    name = Fleet.Layout.project_name(full_name)
    proj_dir = Path.join(Faces.code_root(opts), name)
    card = Keyword.get(opts, :workflow_map)

    with :ok <- Onboard.require_on_machine(full_name, proj_dir),
         :ok <- require_justification(opts),
         :ok <- require_loadable_card(card, full_name, opts),
         {:ok, url} <- Repo.repo_url(full_name, opts) do
      previous = declared_card(proj_dir)
      scratch = scratch_dir(name)

      try do
        with :ok <- Faces.clone_main(url, scratch),
             :ok <-
               Onboard.write_declaration(
                 scratch,
                 full_name,
                 revision_write_opts(opts, current_declaration(proj_dir))
               ),
             {:ok, :changed} <- revision_changed(scratch) do
          publish_revision(full_name, scratch, card, previous, opts)
        else
          {:ok, :unchanged} ->
            {:ok, %{repo: full_name, card: card, previous_card: previous, outcome: :unchanged}}

          {:error, _} = err ->
            err
        end
      after
        _ = File.rm_rf(scratch)
      end
    end
  end

  defp require_justification(opts) do
    case Keyword.get(opts, :justification) do
      j when is_binary(j) and j != "" -> :ok
      _ -> {:error, :justification_required}
    end
  end

  # LA REGLE VIT CHEZ `Fleet.Project.Declaration` — l'ecrivain de la declaration — et pas ici : tenue
  # par la seule REVISION, le verbe qui CHANGE la carte d'un projet refuserait une faute de frappe
  # pendant que les verbes qui la DECLARENT en accepteraient une, et rien ne dirait que les deux
  # portes repondent differemment a la meme question (6-125).
  #
  # Ce qui reste ici est ce qui appartient a CE verbe : pour une revision la carte est REQUISE,
  # alors qu'a la creation son absence vaut « le defaut du catalogue ».
  defp require_loadable_card(card, repo, opts) when is_binary(card) and card != "",
    do: Fleet.Project.Declaration.declarable_card(card, repo, opts)

  defp require_loadable_card(_absent, _repo, _opts), do: {:error, :workflow_map_required}

  defp declared_card(proj_dir) do
    with {:ok, raw} <- File.read(Path.join(proj_dir, Fleet.Layout.project_declaration_file())),
         {:ok, %{"pipeline_default" => card}} when is_binary(card) <- Jason.decode(raw) do
      card
    else
      _ -> nil
    end
  end

  defp scratch_dir(name) do
    Path.join(
      System.tmp_dir!(),
      "lcars-card-revision-#{name}-#{System.unique_integer([:positive])}"
    )
  end

  # A REVISION REWRITES THE WHOLE DECLARATION, SO IT MUST NOT REWRITE IT FROM THE OPTS ALONE.
  # `Declaration.compose/1` is a pure function of its opts — correct for an ONBOARD, where
  # "absent" means "the human declared nothing". At a REVISION "absent" means "the reviser did not
  # mention it", and composing from the opts alone makes the two indistinguishable: a revision
  # naming only the card DELETES `max_fan` — the throughput the human chose — while `declared_by`
  # moves to the reviser.
  #
  # So the carry-forward lives HERE, at the revision's edge, and `compose/1` stays a pure function
  # of what it is handed. What the revision states wins; what it does not state survives.
  # (The schema carries no `level`/`nature` field — criticality IS the card — so `max_fan` is the
  # only framing field to carry forward.)
  #
  # ⚠ RESIDUE, NAMED: `declared_by` ends up as the reviser for the WHOLE record, including a
  # `max_fan` a human chose and this revision merely carried. It names the last writer, not the
  # origin of every field, and the schema (`lcars/declaration-v1`) has no per-field provenance. It is
  # the smaller lie: the alternative is deleting the human's declaration outright.
  defp revision_write_opts(opts, previous) do
    [
      workflow_map: Keyword.get(opts, :workflow_map),
      justification: Keyword.get(opts, :justification),
      max_fan: Keyword.get(opts, :max_fan) || Map.get(previous, "max_fan"),
      onboarded_by: Keyword.get(opts, :revised_by) || "unknown"
    ]
  end

  # The declaration currently on the machine, or `%{}` when there is none/unreadable — the caller
  # then carries nothing forward, which is exactly the old behaviour for a project that never had a
  # declaration to lose.
  defp current_declaration(proj_dir) do
    with {:ok, raw} <- File.read(Path.join(proj_dir, Fleet.Layout.project_declaration_file())),
         {:ok, %{} = decl} <- Jason.decode(raw) do
      decl
    else
      _ -> %{}
    end
  end

  defp revision_changed(scratch) do
    case GitOps.read(["-C", scratch, "status", "--porcelain"], auth: false) do
      {:ok, ""} -> {:ok, :unchanged}
      {:ok, _dirty} -> {:ok, :changed}
      {:error, _} = err -> err
    end
  end

  defp publish_revision(full_name, scratch, card, previous, opts) do
    jury_delta = jury_delta(previous, card, opts)
    msg = "card revision: #{previous || "(undeclared)"} -> #{card}#{jury_suffix(jury_delta)}"

    with :ok <- Faces.commit(scratch, msg),
         :ok <- lift_protection(full_name, opts) do
      case Faces.push(scratch, "main", false) do
        :ok ->
          sync_showcase(full_name, opts)
          protection = restore_protection(full_name, opts)
          announce_jury_delta(full_name, previous, card, jury_delta)

          {:ok,
           %{
             repo: full_name,
             card: card,
             previous_card: previous,
             outcome: :revised,
             jury_delta: jury_delta,
             protection: protection
           }}

        {:error, reason} ->
          _ = restore_protection(full_name, opts)
          {:error, {:card_push_failed, reason}}
      end
    end
  end

  # A CARD REVISION MOVES A WALL, and the record said which card, never what the card DOES. Measured:
  # `standard-qa` carries two judges, `c0-poc` carries none — so `card revision: standard-qa ->
  # c0-poc` is a line that removes the jury AND drops `required_approvals` to zero, written in the
  # vocabulary of a rename. Everything about it is auditable and nothing about it is legible.
  #
  # NOT REFUSED, and that is deliberate. The criticality level is the HUMAN's declaration (the
  # framing interview; an agent never self-assesses it), so a project that genuinely became less
  # critical must be able to say so. What a downgrade may not be is QUIET: the justification is
  # already required and recorded, this adds the consequence beside it — in the commit message that
  # lands on `main`, in the operator log, and in the payload the arch relays back.
  #
  # `nil` when either card refuses to load: a delta nobody could compute must not be reported as
  # zero, which would read as "the jury did not change".
  defp jury_delta(previous, card, opts) do
    with {:ok, before} <- jury_size(previous, opts),
         {:ok, after_} <- jury_size(card, opts) do
      after_ - before
    else
      _ -> nil
    end
  end

  defp jury_size(nil, _opts), do: :error

  defp jury_size(name, opts) do
    loader_opts = Keyword.take(opts, [:workflow_maps_root])
    {:ok, length(Roles.jury(Fleet.Workflow.Loader.load!(name, loader_opts), []))}
  rescue
    _ -> :error
  end

  defp jury_suffix(delta) when is_integer(delta) and delta < 0,
    do: " (JURY REDUIT DE #{abs(delta)} — moins de juges sur chaque livrable a venir)"

  defp jury_suffix(_not_a_reduction), do: ""

  defp announce_jury_delta(repo, previous, card, delta) when is_integer(delta) and delta < 0 do
    Logger.warning(
      "ProjectOnboard: #{repo} card revision #{previous} -> #{card} REDUCES the jury by " <>
        "#{abs(delta)} — future deliverables carry fewer judges and main-protection re-projects " <>
        "with fewer required approvals. Justified and recorded; named here because the card name " <>
        "alone does not say it."
    )

    :ok
  end

  defp announce_jury_delta(_repo, _previous, _card, _delta), do: :ok

  defp lift_protection(repo, opts) do
    rule = %{
      rule_name: "main",
      enable_push: true,
      enable_push_whitelist: true,
      push_whitelist_usernames: [Fleet.Credentials.ForgeIdentity.system_identity().name]
    }

    case Repo.repo_mod(opts).protect_branch(repo, rule, Repo.fc_opts(opts)) do
      {:ok, _outcome} -> :ok
      {:error, reason} -> {:error, {:protection_lift_failed, reason}}
    end
  end

  defp restore_protection(repo, opts) do
    case Faces.protect_main(repo, opts) do
      :ok ->
        :restored

      {:error, reason} ->
        Logger.error(
          "ProjectOnboard: card revision of #{repo} — protection restore FAILED " <>
            "(#{inspect(reason)}) — the periodic protection pass will converge the rule"
        )

        :restore_failed
    end
  end

  defp sync_showcase(repo, opts) do
    sync =
      Keyword.get(opts, :sync_showcase, fn r -> Fleet.Project.WorktreeSync.sync_now(r, "main") end)

    case sync.(repo) do
      :ok ->
        :ok

      other ->
        Logger.warning(
          "ProjectOnboard: card revision of #{repo} landed but the showcase sync degraded " <>
            "(#{inspect(other)}) — burns read the OLD card until the next worktree sync"
        )

        :ok
    end
  catch
    kind, why ->
      Logger.warning(
        "ProjectOnboard: card revision of #{repo} landed but the showcase sync degraded " <>
          "(#{inspect(kind)}: #{inspect(why)}) — burns read the OLD card until the next worktree sync"
      )

      :ok
  end
end
