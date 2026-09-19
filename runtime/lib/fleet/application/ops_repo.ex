defmodule Fleet.Application.OpsRepo do
  @moduledoc """
  Measures the system repository (`<system org>/_ops`) and reports what is missing.

  ⚠ THE RECIPE PLACES, THIS MEASURES. The repository, its branches and the protection of the
  manifest branch are declared in the forge recipe and placed by `forge-gestures apply`. Nothing
  here creates anything: a runtime that places its own branches is what was measured on the beta
  bench — a registry written to a branch nobody had created, 380 failures in eleven hours. What is
  missing is NAMED, and the remedy is always the same: replay the recipe.

  Each finding carries its own severity, because one pass can hold several: a missing branch is a
  drift the recipe fixes, while a forge that answers something unreadable is a failure that
  concludes nothing. The VERDICT is not computed here — the caller's protocol owns it, and the two
  rails map the same findings to their own dialect.
  """

  alias Fleet.Forge.Client.Repo, as: ForgeRepo

  @typedoc "Severity of one finding, in the vocabulary both rails share."
  @type gravite :: :ok | :drift | :fail

  @typedoc "One finding: its severity, and the sentence an operator reads."
  @type constat :: %{gravite: gravite(), phrase: String.t()}

  @remede "la recette de la forge le pose : sur un poste, « deploy/workstation up » ; pour un conteneur, « deploy/container forge-apply » depuis l'hôte"

  @doc """
  Measures the system repository and returns the findings, in reading order.

  Stops at the first finding that makes the rest unmeasurable — an absent repository says nothing
  about its branches — so an empty list never happens: silence would read as conformity. Both
  branches are measured before concluding, though: naming one missing branch and staying silent
  on the other would make the operator replay the recipe twice.

  `opts` are forwarded to the forge client, minus `:repo` (the repository under test) and
  `:forge_repo` (the client module, a test seam).
  """
  @spec mesure(keyword()) :: [constat()]
  def mesure(opts \\ []) do
    depot = Keyword.get(opts, :repo, Fleet.Toolchain.ops_repo())

    # La couture de test remplace une dep DECLAREE par un double ; elle ne monte pas d'un etage.
    # Boundary ne voit pas un appel par variable, d'ou la dep declaree sur `Fleet.Forge`.
    fc = %{
      mod: Keyword.get(opts, :forge_repo, ForgeRepo),
      opts: Keyword.drop(opts, [:repo, :forge_repo])
    }

    case fc.mod.server_version(fc.opts) do
      {:ok, _v} ->
        depot_present(depot, fc)

      {:error, raison} ->
        [
          drift(
            "forge injoignable (#{inspect(raison)}) — état du dépôt #{depot} INCONNU " <>
              "(ce geste ne conclut pas sans mesure)"
          )
        ]
    end
  end

  defp depot_present(depot, fc) do
    case fc.mod.repo_exists?(depot, fc.opts) do
      {:ok, true} ->
        branches(depot, fc)

      {:ok, false} ->
        [
          drift(
            "dépôt #{depot} ABSENT — sans lui aucune demande d'outillage, aucun registre " <>
              "d'incidents, aucune escalade ; #{@remede}"
          )
        ]

      {:error, raison} ->
        [
          fail(
            "#{depot} : la forge ne dit pas s'il existe (#{inspect(raison)}) — rien n'est conclu"
          )
        ]
    end
  end

  # Les deux branches se mesurent TOUTES LES DEUX avant de conclure : dire « tool_request manque »
  # puis se taire sur `incidents` ferait rejouer la recette pour redécouvrir la seconde.
  defp branches(depot, fc) do
    constats =
      Enum.flat_map([branche_manifeste(), branche_incidents()], &branche(depot, &1, fc))

    if constats == [], do: protection_manifeste(depot, fc), else: constats
  end

  defp branche(depot, b, fc) do
    case fc.mod.branch_exists?(depot, b, fc.opts) do
      {:ok, true} ->
        []

      {:ok, false} ->
        [drift("#{depot}:#{b} ABSENTE — #{pourquoi(b)} ; #{@remede}")]

      {:error, raison} ->
        [fail("#{depot}:#{b} : la forge ne dit pas si elle existe (#{inspect(raison)})")]
    end
  end

  # Sans la protection, une demande d'outillage se merge sans signature — un manifeste appliqué par
  # root sur le conteneur, que personne n'a lu.
  defp protection_manifeste(depot, fc) do
    b = branche_manifeste()

    case fc.mod.branch_protection(depot, b, fc.opts) do
      {:ok, :absent} ->
        [
          drift(
            "#{depot}:#{b} SANS protection — une PR d'outillage se mergerait sans signature ; " <>
              "#{@remede}"
          )
        ]

      {:ok, regle} ->
        regle_conforme(depot, regle, fc)

      {:error, raison} ->
        [
          fail(
            "protection de #{depot}:#{b} illisible (#{inspect(raison)}) — rien n'est conclu " <>
              "(le compte système lit la protection en tant que propriétaire de l'org)"
          )
        ]
    end
  end

  # ⚠ UNE WHITELIST ACTIVÉE ET VIDE EST UN PIÈGE, PAS UNE PROTECTION OUVERTE : plus aucune signature
  # ne compte, donc plus aucune demande d'outillage ne passe.
  #
  # ⚠ ET ELLE SE LIT SUR LES TEAMS, PAS SUR LES NOMS. Gitea n'accepte dans une whitelist QUE les
  # membres d'une team de l'org : un compte nommé là, fût-il site-admin et collaborateur en `write`,
  # en est écarté EN SILENCE (mesuré le 2026-09-18 sur le banc VIERGE 2004). Lire les noms ici
  # rendrait « aucun » sur une protection parfaitement posée.
  defp regle_conforme(depot, regle, fc) do
    b = branche_manifeste()
    ra = regle["required_approvals"]
    ds = regle["dismiss_stale_approvals"]
    teams = Enum.filter(List.wrap(regle["approvals_whitelist_teams"]), &is_binary/1)

    if ra == 1 and ds == true and teams != [] do
      team_peuplee(depot, hd(teams), fc)
    else
      [
        drift(
          "#{depot}:#{b} protégée AUTREMENT que la recette ne le dit (approbations " <>
            "« #{affiche(ra)} », réapprobation « #{affiche(ds)} », teams approbatrices " <>
            "« #{if teams == [], do: "aucune", else: Enum.join(teams, " ")} ») ; #{@remede}"
        )
      ]
    end
  end

  # UNE TEAM VIDE NE SIGNE PAS DAVANTAGE QU'UNE LISTE VIDE. La protection nomme la team ; ce qui la
  # rend vraie, c'est qu'elle ait au moins un membre — et ses membres sont les site-admins.
  defp team_peuplee(depot, team, fc) do
    org = depot |> String.split("/") |> hd()

    case fc.mod.team_members(org, team, fc.opts) do
      {:ok, []} ->
        [
          drift(
            "#{depot}:#{branche_manifeste()} nomme la team « #{team} », qui n'a AUCUN membre — " <>
              "aucune demande d'outillage ne peut être signée ; #{@remede}"
          )
        ]

      {:ok, membres} ->
        autres_protections(depot, team, membres, fc)

      {:error, raison} ->
        [
          fail(
            "membres de la team « #{team} » illisibles (#{inspect(raison)}) — rien n'est conclu " <>
              "sur qui peut signer une demande d'outillage"
          )
        ]
    end
  end

  # `main` et `incidents` : le `write` qu'un approbateur reçoit pour SIGNER ne doit pas devenir un
  # droit d'écrire partout. Sans ces deux protections, il l'est — et rien ne le dirait.
  defp autres_protections(depot, team, membres, fc) do
    etats =
      Enum.map(["main", branche_incidents()], &{&1, fc.mod.branch_protection(depot, &1, fc.opts)})

    illisibles =
      for {b, {:error, raison}} <- etats,
          do:
            fail("protection de #{depot}:#{b} illisible (#{inspect(raison)}) — rien n'est conclu")

    libres = for {b, {:ok, :absent}} <- etats, do: b

    cond do
      illisibles != [] ->
        illisibles

      libres != [] ->
        [
          drift(
            "#{depot} : #{Enum.join(libres, ", ")} SANS protection — les approbateurs de " <>
              "#{branche_manifeste()} ont « write » sur ce dépôt pour pouvoir signer, et sans ces " <>
              "protections ce droit devient un push libre ; #{@remede}"
          )
        ]

      true ->
        [
          ok(
            "#{depot} : dépôt, branches #{branche_manifeste()} et #{branche_incidents()}, " <>
              "protection de #{branche_manifeste()} (une approbation de la team « #{team} » : " <>
              "#{Enum.join(membres, " ")}, réapprobation à chaque push), main et " <>
              "#{branche_incidents()} protégées"
          )
        ]
    end
  end

  defp pourquoi(b) do
    cond do
      b == branche_manifeste() ->
        "un pod qui demande un outil n'a pas de base de PR, et le réconciliateur échoue à chaque tick sur son head"

      b == branche_incidents() ->
        "le pilote ne peut pas écrire son registre d'incidents, et le dira à chaque synchronisation"

      true ->
        "cette branche est déclarée par la recette"
    end
  end

  # Les deux noms viennent de leur declaration unique, jamais d'un litteral pose ici.
  defp branche_manifeste, do: Fleet.Toolchain.branch()
  defp branche_incidents, do: Fleet.Pilot.incident_registry_branch()

  defp affiche(nil), do: "?"
  defp affiche(v), do: to_string(v)

  defp ok(phrase), do: %{gravite: :ok, phrase: phrase}
  defp drift(phrase), do: %{gravite: :drift, phrase: phrase}
  defp fail(phrase), do: %{gravite: :fail, phrase: phrase}

  @doc """
  Release door that MEASURES: one `<severity>\\t<sentence>` line per finding, and exit 0 whatever
  the state — a measure is not a verdict, and the caller's protocol owns the mapping.

  ⚠ SILENCE WOULD READ AS CONFORMITY, so this door never prints nothing: every path of `mesure/1`
  ends on at least one finding, and the type checker holds that today (a clause guarding the empty
  case is refused as unreachable). A witness pins it per path, for the day it stops being provable.
  Starts the HTTP pool alone, never a second fleet.
  """
  @spec eval_check() :: no_return()
  def eval_check do
    Fleet.ReleaseDoor.claim_stdout!()
    {:ok, _sup} = Supervisor.start_link([Fleet.Forge.finch_spec()], strategy: :one_for_one)

    for %{gravite: g, phrase: p} <- mesure(), do: IO.puts("#{g}\t#{p}")
    System.halt(0)
  end
end
