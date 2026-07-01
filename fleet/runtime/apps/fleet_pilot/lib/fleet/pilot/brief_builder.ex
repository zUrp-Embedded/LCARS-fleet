defmodule Fleet.Pilot.BriefBuilder do
  @moduledoc """
  Autorité du FORMAT des briefs : worker / judge / brief-review / rework / conflit, plus les
  instructions de voix de l'eng. `StageDispatcher` APPELLE (il choisit QUEL brief selon l'état forge),
  il ne FORME plus le brief lui-même.

  La judge-ness (et la cible d'un juge) est une propriété de SÉCURITÉ : elle ne s'infère JAMAIS par
  omission de clause. `build_brief/9` est une somme TOTALE et fail-loud sur `brief_kind`/`judge_target`
  hors-vocab (raise) — un juge ne doit JAMAIS recevoir un corps d'issue exécutable. Le brief d'un juge est
  DÉSAMORCÉ (`Fleet.Pipeline.GateBrief` : `request` rendu comme contexte, pas comme instruction exécutable).

  `forge` est un ARG injecté (seam) — jamais câblé en dur. Les autres deps (`Fleet.CapProfile`,
  `Fleet.Pipeline.GateBrief`, `Fleet.Credentials.ForgeIdentity`) sont appelées telles quelles.
  """

  # Brief de rework : le PRODUCTEUR (engineer) reprend sur une PR REQUEST_CHANGES.
  # PORTE LA MÊME instruction git-native que `build_worker_brief` (sinon `:no_deliverable_commit` : le
  # rework « re-pousse » mais le pod est FORGE-AVEUGLE et sans l'ordre de COMMITTER il ne livre rien —
  # jumeau du brief producteur). Le pod corrige + commite EN LOCAL ; le SYSTÈME pousse (frontière
  # forge). Trailer obligatoire (gate de push).
  #
  # FAMINE D'INFO, moitié rework : sans le BODY des reviews REQUEST_CHANGES,
  # « corrige selon la review » est creux — le pod forge-aveugle ne voit PAS la review → il devine à
  # l'aveugle (un eng prudent refuse de deviner → `blocked_dep` → wedge). On lit le feedback sur la forge
  # (le runtime, pas le pod : frontière forge préservée) et on l'injecte. Si la lecture échoue / aucun body,
  # on retombe sur l'instruction générique (le pod a quand même la PR clonée + son code).
  def rework_brief(role, forge, repo, pr, forge_opts, _route) do
    [
      "REWORK — une review REQUEST_CHANGES a été déposée sur la PR ##{pr}. Corrige ton code selon le " <>
        "feedback de la review ci-dessous.",
      render_rework_feedback(forge, repo, pr, forge_opts),
      "**Livraison (git-native)** : applique tes corrections dans ton workspace, puis `git add` + `git commit`. " <>
        "Le SYSTÈME pousse ton commit (forge-aveugle, toi tu ne push pas). `submit_result` clôt la tâche : le " <>
        "LIVRABLE = ton COMMIT (ne RE-mets PAS les fichiers dans le payload). Le payload porte ta voix ↓.",
      eng_voice_instruction(:rework),
      Fleet.Credentials.ForgeIdentity.coauthor_instruction(role)
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n\n")
  end

  # Brief de RÉSOLUTION DE CONFLIT : la PR est APPROUVÉE mais `main` a avancé (un
  # autre issue parallèle a fusionné) → conflit. Le PRODUCTEUR (git_native, il a écrit le contenu) RÉCONCILIE :
  # rebase sur `main` + résolution en gardant TOUT (le sien + main). Pas un re-code. Le système pousse ;
  # le push rebasé invalide les vieilles reviews (head_sha) → les juges re-valident le fusionné, gatekeeper scelle.
  def resolve_conflict_brief(role, _forge, _repo, pr, _forge_opts, _route) do
    [
      "RÉSOLUTION DE CONFLIT — ta PR ##{pr} a été APPROUVÉE, mais `main` a avancé depuis (un autre issue " <>
        "parallèle a été fusionné) et ta branche **conflicte** avec `main`. On ne te demande PAS de re-coder : " <>
        "juste de RÉCONCILIER les deux versions.",
      "**Procédure (git-native)** : dans ton workspace, `git fetch origin` puis `git rebase origin/main`. Pour " <>
        "CHAQUE fichier en conflit, résous en **gardant TOUT le contenu utile** — le tien ET celui arrivé sur " <>
        "`main` (ex. un README partagé : garde les DEUX sections, ne supprime rien). `git add` les fichiers " <>
        "résolus puis `git rebase --continue` (et `git commit` si besoin). Le SYSTÈME pousse (forge-aveugle, tu " <>
        "ne push pas). `submit_result` clôt : le LIVRABLE = tes COMMIT(s) rebasés (ne RE-mets PAS les fichiers " <>
        "dans le payload). Le payload porte ta voix ↓.",
      eng_voice_instruction(:rework),
      Fleet.Credentials.ForgeIdentity.coauthor_instruction(role)
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n\n")
  end

  # VOIX DE L'ENG (info SORTANTE, jumeau de la famine d'info entrante) : le `summary` rendu dans
  # `submit_result` est POSTÉ sur la PR par le système (forge-aveugle, `as_role` engineer) → l'eng
  # a une voix pour l'humain. Sans ça il est muet sur la forge (un diagnostic même excellent ne serait
  # jamais vu) ; feedback verbeux, descriptif, traçable.
  defp eng_voice_instruction(:build) do
    "**Ta voix — le `payload` de `submit_result` DOIT contenir un champ `summary`** " <>
      "(ex. `submit_result` avec `payload = {\"summary\": \"Implémenté X ; choisi Y parce que Z\"}`). Le " <>
      "`summary` (markdown COURT) = ce que tu as réalisé + décisions/hypothèses notables. ⚠ ce N'EST PAS du " <>
      "contenu de fichier (ça, c'est ton COMMIT) — c'est ta NARRATION. Le SYSTÈME la poste en commentaire sur " <>
      "la PR : c'est ta SEULE voix pour l'humain qui review. **Si tu es BLOQUÉ** (dépendance/info manquante) " <>
      "et ne peux PAS livrer : NE devine PAS — ajoute `\"blocked\": true` au payload (à côté de `summary` = le " <>
      "motif PRÉCIS, ce qui te manque). Le système ESCALADE à l'humain (aucun commit attendu de toi), jamais un " <>
      "wedge silencieux. Ex. `payload = {\"blocked\": true, \"summary\": \"Manque la spec du protocole X — ...\"}`."
  end

  defp eng_voice_instruction(:rework) do
    "**Ta voix — le `payload` de `submit_result` DOIT contenir un champ `summary`** " <>
      "(ex. `payload = {\"summary\": \"Corrigé le point A en faisant B ; pour le point C, ...\"}`). Le " <>
      "`summary` = COMMENT tu as répondu à CHAQUE point de la review (ce que tu as corrigé). C'est ta " <>
      "NARRATION (pas le code — déjà committé). Le SYSTÈME le poste sur la PR : ta réponse traçable au reviewer."
  end

  # Rend le feedback des reviews REQUEST_CHANGES (body du verdict de chaque juge) en bloc actionnable.
  # `""` si rien (lecture KO ou aucun body) → le brief retombe sur l'instruction générique (Enum.reject).
  defp render_rework_feedback(forge, repo, pr, forge_opts) do
    case forge.change_request_feedback(repo, pr, forge_opts) do
      {:ok, [_ | _] = feedbacks} ->
        sections =
          Enum.map_join(feedbacks, "\n\n", fn fb ->
            "### Review de `#{fb["login"]}`\n#{fb["body"]}"
          end)

        "## Feedback de review à traiter (REQUEST_CHANGES)\n\n#{sections}"

      _ ->
        ""
    end
  end

  # La forme du brief est une propriété du rôle (cap-profile `brief_kind`), PAS un nom
  # magique en ring2. `judge` → GateBrief désamorcé ; tout le reste (`worker`, défaut) → corps d'issue.
  def build_brief(
        profile,
        role,
        forge,
        repo,
        number,
        issue,
        forge_opts,
        route,
        stage_spec
      ) do
    # Le `brief_kind` du STAGE (carte) PRIME sur celui du profil (override per-stage) — réutilise
    # un profil worker (consultant) en JUGE sans profil-doublon. ABSENT au stage → défaut profil
    # (lui-même "worker" par défaut, fail-safe) via le `||` : l'absence n'est PAS une anomalie. Ce
    # qui suit traite la valeur PRÉSENTE-mais-hors-vocab, distincte de l'absence.
    kind = Map.get(stage_spec, "brief_kind") || Fleet.CapProfile.brief_kind(profile)

    # Somme TOTALE et fail-loud. La judge-ness (et la cible d'un juge) est une propriété de
    # SÉCURITÉ : elle ne s'infère JAMAIS par omission de clause. Un kind/target hors-vocab (typo, ou
    # valeur d'un futur vocabulaire) NE DOIT PAS retomber silencieusement sur worker — sinon un rôle
    # juge recevrait un corps d'issue EXÉCUTABLE (brief actif) au lieu d'un brief désamorcé. On
    # rejette bruyamment (raise) plutôt que de construire un brief dangereux en silence.
    case {kind, Map.get(stage_spec, "judge_target")} do
      # Juge de BRIEF (judge_target:brief) → juge le issue.body (exécutable ?), PAS un livrable
      # (pas de code en amont).
      {"judge", "brief"} ->
        build_brief_review_brief(role, issue, forge, repo, number, forge_opts, route)

      # Juge de LIVRABLE : judge_target ABSENT (nil → défaut canon) ou "deliverable" explicite →
      # juge un livrable (PR), brief inchangé.
      {"judge", target} when target in [nil, "deliverable"] ->
        build_judge_brief(role, forge, repo, number, forge_opts, route)

      # judge_target PRÉSENT mais hors {brief, deliverable} → anomalie : on ne devine pas la cible.
      {"judge", other} ->
        raise ArgumentError,
              "judge_target #{inspect(other)} hors vocabulaire {brief, deliverable} — la cible d'un juge ne s'infère pas"

      {"worker", _} ->
        build_worker_brief(role, issue)

      # kind ∉ {worker, judge} (brief_kind présent mais hors-vocab) → fail-loud.
      {other, _} ->
        raise ArgumentError,
              "brief_kind #{inspect(other)} hors vocabulaire {worker, judge} — la judge-ness ne s'infère pas"
    end
  end

  # Brief producteur = le brief de l'issue + l'instruction de LIVRAISON git-native. Sans elle,
  # le pod « submit les contenus » au lieu de
  # COMMITTER → la publish git_native ne trouve aucun commit (`:no_deliverable_commit`).
  # Le pod commite en LOCAL ; le SYSTÈME pousse + ouvre la PR (forge-aveugle). Le trailer
  # est obligatoire (gate de push, source unique `ForgeIdentity.coauthor_instruction`).
  defp build_worker_brief(role, issue) do
    [
      issue["body"] || "",
      "---",
      "**Livraison (git-native)** : réalise le travail dans ton workspace, puis `git add` + `git commit`. " <>
        "Le SYSTÈME pousse ton commit et ouvre la PR — toi tu ne push pas (forge-aveugle). `submit_result` " <>
        "clôt la tâche : le LIVRABLE = ton COMMIT (ne RE-mets PAS le code/les fichiers dans le payload, ils " <>
        "sont déjà committés). Le payload, lui, N'EST PAS vide : il porte ta voix ↓.",
      eng_voice_instruction(:build),
      Fleet.Credentials.ForgeIdentity.coauthor_instruction(role)
    ]
    |> Enum.join("\n\n")
  end

  # Un pod **juge** doit savoir QUOI
  # juger ET comment rendre son verdict. On réutilise le brief canonique `Fleet.Pipeline.GateBrief`
  # (contexte + livrable + question + **contrat `gate-decision-v1.json` + options canon**) — le même
  # que le modèle RAM. Le `result_K` à juger est lu du comment du hop précédent (gravé par
  # HopCompleter) ; le pod reste forge-aveugle (le runtime lit le comment, pas de
  # clone).
  defp build_judge_brief(role, forge, repo, number, forge_opts, route) do
    predecessor =
      case forge.get_predecessor_result(repo, number, forge_opts) do
        {:ok, result} when is_map(result) and map_size(result) > 0 -> result
        _ -> nil
      end

    # GIT-NATIVE (predecessor vide) : le livrable N'EST PAS un payload — c'est le CODE de la
    # branche. Le juge clone la feature-branch + a `Bash(git diff/log/show)` → on le POINTE sur son
    # workspace au lieu de lui donner `{}` (sur quoi il fail-closerait `halt_wait_input`). Sinon il juge
    # du vide → rework infini (le Reviewer ne peut JAMAIS dire `continue` sur `{}`).
    outputs =
      predecessor ||
        %{
          "livrable" =>
            "git-native — le code à juger est checkout dans TON workspace. Le clone est mono-branche : " <>
              "la base est `origin/main` (le ref local `main` N'EXISTE PAS). Le diff de la PR = " <>
              "`git diff origin/main...HEAD` (trois points — point de divergence auto). `git log origin/main..HEAD` " <>
              "pour les commits, `git show <sha>` pour le détail. Juge ces changements contre le critère ci-dessous."
        }

    # CRITÈRE de réussite = le body de l'issue (le brief). Passé via `:request` → GateBrief le rend
    # DÉSAMORCÉ (contexte, pas instruction exécutable → l'état exécutable est rendu irreprésentable) → le juge sait CONTRE QUOI juger.
    request =
      case forge.get_issue(repo, number, forge_opts) do
        {:ok, issue} -> Map.get(issue, "body")
        _ -> nil
      end

    {pipeline, stage} =
      case route do
        {p, s} -> {p, s}
        _ -> {nil, role}
      end

    # Le brief du juge ne doit contenir AUCUNE instruction exécutable (état exécutable rendu
    # irreprésentable en amont). Le `request` (body de l'issue = critère) est rendu par GateBrief DÉSAMORCÉ
    # (blockquote « CONTEXTE — déjà traité, NE PAS exécuter » + bannière « JUGER, PAS PRODUIRE »). Le risque
    # vise un juge **base-worker** (profile noop, gatekeeper) qui RE-exécuterait le build même quoté : ce
    # juge-là reçoit son brief par `dispatch_gatekeeper` (hop_consumer) qui NE passe PAS `request` — il
    # n'est pas affecté ici. `build_judge_brief` ne sert que les juges À PERSONA (qualifier/reviewer,
    # `subagent_template` spec-reviewer/code-quality-reviewer) — le cas réputé SÛR
    # (un juge à vraie persona : GateBrief sait rendre `request` désamorcé). En pratique
    # ces juges fail-closent `halt_wait_input` sur livrable vide, ils ne RE-buildent pas.
    # Sans le critère (`request`) ET le livrable (diff via `outputs`), le juge jugerait du `{}` → rework
    # infini (le Reviewer ne peut JAMAIS `continue` sur du vide) — c'est la famine d'info.
    Fleet.Pipeline.GateBrief.build(%{
      stage: stage,
      pipeline_id: pipeline,
      gate: nil,
      outputs: outputs,
      request: request
    })
  end

  # Brief d'un juge de BRIEF (brief-review, judge_target:brief). Le consultant juge le BRIEF
  # (issue.body rédigé par l'arch) AVANT que l'engineer ne parte : exécutable sans nouvelle question ? On
  # réutilise le MÊME GateBrief (contrat gate-decision-v1 + options canon) que les autres juges — seul le
  # `subject: :brief` recadre le « truc à juger ». Le BRIEF va dans `outputs` (le truc À JUGER ; ≠
  # build_judge_brief où outputs = le livrable/code) ; pas de `request` (le critère d'exécutabilité est
  # porté par le cadrage :brief). Le juge est PRÉ-PR (aucun clone, aucun livrable) → cohérent N0.
  defp build_brief_review_brief(role, issue, forge, repo, number, forge_opts, route) do
    # Le brief = body de l'ISSUE, DÉJÀ en main (le poller a listé l'issue ; brief-review est
    # toujours issue-path). On l'utilise → pas de `get_issue` redondant. Fallback fetch si body absent (robustesse).
    brief = issue_body_in_hand_or_fetch(issue, forge, repo, number, forge_opts)

    {pipeline, stage} =
      case route do
        {p, s} -> {p, s}
        _ -> {nil, role}
      end

    Fleet.Pipeline.GateBrief.build(%{
      stage: stage,
      pipeline_id: pipeline,
      gate: nil,
      subject: :brief,
      outputs: %{"brief" => brief}
    })
  end

  # Body de l'issue DÉJÀ listée par le poller → utilisé direct ; fetch SEULEMENT en fallback
  # (body absent/vide — défensif ; brief-review est toujours issue-path, l'issue est en main).
  defp issue_body_in_hand_or_fetch(issue, forge, repo, number, forge_opts) do
    case Map.get(issue, "body") do
      body when is_binary(body) and body != "" ->
        body

      _ ->
        case forge.get_issue(repo, number, forge_opts) do
          {:ok, fetched} -> Map.get(fetched, "body") || ""
          _ -> ""
        end
    end
  end
end
