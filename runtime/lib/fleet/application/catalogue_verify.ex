defmodule Fleet.Application.CatalogueVerify do
  @moduledoc """
  Standalone catalogue-root proof using the daemon's own verification functions in
  boot order. It proves one directory, not deployment credentials or fine-grained
  overrides, and must run in an ephemeral VM because image publication is global.
  """

  require Logger

  @typedoc "One failed check: which stage, and the raised message verbatim."
  @type finding :: %{stage: String.t(), error: String.t()}

  @typedoc """
  The verdict. `:ok` when every stage passed; `{:error, findings}` otherwise. `assumptions` is
  always returned — the root read and the fine-override blindness the header must show.
  """
  @type result ::
          {:ok, %{root: Path.t(), assumptions: [String.t()]}}
          | {:error, %{root: Path.t(), findings: [finding()], assumptions: [String.t()]}}

  @doc """
  The RELEASE door: run `verify/1`, print the same report the `mix` task prints, and halt with the
  boot's verdict (0 pass, 1 refused). Called from the image's entrypoint via a release eval —

      bin/lcars_fleet eval 'Fleet.Application.CatalogueVerify.eval_main("/cat")'

  so the entrypoint's `verify <root>` is a one-liner and the exit code is the whole contract on the
  shell side. Uses `IO.puts` + `System.halt/1` because a release has no `Mix.shell` — the ONLY
  difference from the dev door, the checks themselves being identical (they are `verify/1`).
  """
  @spec eval_main(Path.t()) :: no_return()
  def eval_main(root) when is_binary(root) do
    # Le rapport EST la sortie de cette porte, et l'entrypoint le rend a l'operateur. Meme regle que
    # les autres portes release : le logger va sur stderr, le rapport garde stdout pour lui seul.
    # Le pourquoi et la mesure vivent dans `Fleet.ReleaseDoor`.
    Fleet.ReleaseDoor.claim_stdout!()

    case verify(root) do
      {:ok, %{assumptions: assumptions}} ->
        print(assumptions)
        # ⚠ CETTE LIGNE NE DIT PAS « every check the boot runs passed » (6-008) : rien ici ne
        # tiendrait cette equivalence. Que ce verificateur rejoue UNE garde de moins que le rail de
        # boot, et un vert d'ici PRECEDE un boot rouge — le contraire de son objet. L'equivalence
        # des deux sequences est tenue par le check `boot.verifier_covers_rail`, qui les lit a
        # l'AST et refuse la divergence.
        #
        # La phrase nomme donc ce qui EST prouve. Le verificateur prouve UN REPERTOIRE avec
        # les fonctions du boot ; il ne prouve ni les credentials de deploiement, ni les surcharges
        # fines, ni l'ordre reel de demarrage — ce que la liste d'hypotheses au-dessus dit deja.
        IO.puts(
          "catalogue OK — les controles catalogue du boot passent (cf. hypotheses ci-dessus)."
        )

        System.halt(0)

      {:error, %{findings: findings, assumptions: assumptions}} ->
        print(assumptions)
        IO.puts("catalogue REFUSED — #{length(findings)} check(s) failed:")
        for %{stage: stage, error: error} <- findings, do: IO.puts("  x #{stage}: #{error}")
        System.halt(1)
    end
  end

  defp print(assumptions) do
    IO.puts("- verifier assumptions -")
    for a <- assumptions, do: IO.puts("  . #{a}")
    IO.puts("")
  end

  @doc """
  Verifies the catalogue at `root`. Sets `:lcars_fleet, :catalogue_root` to it for the duration, restores
  the previous value on the way out. Collects findings instead of raising on the first — an operator
  fixes a catalogue in one pass, not one boot-crash at a time — but keeps the boot's tiers: the
  manifest is a precondition (nothing downstream is meaningful without it), and the images are a
  precondition for the spawn proof and the card guards (both read the frozen image, so a failed
  image would cascade into noise).
  """
  @spec verify(Path.t()) :: result()
  def verify(root) when is_binary(root) do
    prev = Application.fetch_env(:lcars_fleet, :catalogue_root)
    Application.put_env(:lcars_fleet, :catalogue_root, root)

    assumptions = [
      "root read: #{root}",
      "fine per-tree overrides (LCARS_CAPPROFILES_ROOT etc.) are IGNORED — this proves the root taken whole",
      cap_profiles_assumption(root)
    ]

    try do
      case run(root, assumptions) do
        :ok ->
          {:ok, %{root: root, assumptions: assumptions}}

        {:error, findings} ->
          {:error, %{root: root, findings: findings, assumptions: assumptions}}
      end
    after
      restore(prev)
    end
  end

  # THREE STATES USED TO SHARE ONE SILENCE: a catalogue that brings no role on purpose, a
  # `cap-profiles` directory mislaid (a typo, or the pre-0.9 `canon/` level), and a directory that
  # is there. The first is legal (`Fleet.Workflow.CardRoles`: a catalogue with no profiles of its
  # own is fine as long as its cards only name system roles) and the second is the dangerous one —
  # zero role published, every stage green. Refusing would set a policy this verifier has no mandate
  # for; so the state is NAMED in the assumptions the operator reads, and a mislaid directory reads
  # as « none of its own » where they expected their roles (2026-09-04).
  defp cap_profiles_assumption(root) do
    dir = Path.join(root, Fleet.Catalogue.rel(:cap_profiles))

    if File.dir?(dir),
      do: "cap-profiles: read from #{dir}",
      else: "cap-profiles: NONE of its own (#{dir} absent) — its cards can only name system roles"
  end

  # Tier 1 — the manifest. Without a readable root and a supported api_version, nothing below can be
  # published or proved; a precondition, so it short-circuits.
  defp run(root, _assumptions) do
    case guard("catalogue manifest", fn -> Fleet.Catalogue.verify!() end) do
      [] -> after_manifest(root)
      findings -> {:error, findings}
    end
  end

  # Tier 2 — the two proven-good images. The spawn proof and the card guards read the FROZEN image,
  # so a failed publish would make them fail too, as cascade noise. If either image fails, we skip
  # those two and still prove the policies (which read their own file), then report.
  defp after_manifest(root) do
    image_findings =
      Enum.flat_map(
        [
          {"cap-profile image", fn -> Fleet.CapProfile.publish_image!() end},
          {"sp-builder image", fn -> Fleet.SPBuilder.publish_image!() end}
        ],
        fn {stage, fun} -> guard(stage, fun) end
      )

    downstream =
      if image_findings == [] do
        [
          {"canon spawn-proof", fn -> Fleet.Spawner.prove_canon!() end},
          {"cards + structural roles",
           fn -> Fleet.Pilot.Application.verify_cards_and_roles!() end},
          # L'ARETE ENTRE LES DEUX IMAGES : chaque carte nomme-t-elle des roles qui existent ?
          # Elle est jouee au boot, et elle DOIT l'etre ici — `catalogue install` appelle cette
          # porte avant de toucher la forge, et une porte qui ne couvre pas le boot rend un vert
          # suivi d'un boot rouge (6-008).
          {"cards -> roles", fn -> Fleet.Workflow.CardRoles.verify!(root) end},
          {"business catalogue advice", fn -> advise_business!(root) end}
        ]
      else
        # Images broke → the spawn proof and card guards would only echo it.
        []
      end

    findings =
      image_findings ++ Enum.flat_map(downstream, fn {stage, fun} -> guard(stage, fun) end)

    case findings do
      [] -> :ok
      errs -> {:error, errs}
    end
  end

  # What the BUSINESS half declares on its own, judged alone. One warning, and NO refusal — in
  # particular pas ces deux-la : « un role metier ne peut pas declarer une capability systeme » et
  # « un role metier ne peut pas prendre `role_index: 0` ».
  #
  # Les deux sont justes SOUS UN CATALOGUE MONO-RACINE, ou une collision de nom est elle-meme un
  # refus : rien ne peut se superposer a rien, donc declarer `project_delegate` ne peut etre qu'une
  # usurpation. Des lors que le resolveur lit un CHEMIN DE RECHERCHE ORDONNE, surcharger un role
  # systeme PAR NOM est le geste SUPPORTE — et une surcharge d'`architect.yaml` declare
  # necessairement `project_delegate`, une surcharge de `starfleet.yaml` porte necessairement le
  # slot 0. Ces deux refus cesseraient de tracer une frontiere pour INTERDIRE LA FONCTIONNALITE.
  #
  # What replaces them looks at the MERGED index instead of the files, which is what lets it tell
  # the two apart on its own: an override is ONE entry (one delegate, one claim on slot 0) and
  # passes; two different names on one slot, or two delegates, are real conflicts and are refused —
  # by `Fleet.CapProfile.Image.publish!/0` and `Fleet.Project.Roles.resolve_structural_roles!/0`,
  # at BOOT, which is also where a deployment that never runs this verifier is finally covered.
  #
  # The warning stays a warning on purpose: a catalogue with no judge is LEGITIMATE (a card may
  # declare `jury: []` and mean it), it is just almost always an oversight. Refusing it would set a
  # policy this check has no mandate for — the same restraint `validate_workshop_card!/1` applies.
  #
  # The unreadable case still raises even though the image stage above would normally reach it
  # first: this reads ONE root where the image reads the union, and a guard that relies on another
  # stage running before it is a guard with a hidden precondition.
  defp advise_business!(root) do
    cap_root = Path.join(root, "cap_profile/cap-profiles")

    case Fleet.CapProfile.index_of(cap_root) do
      # Legal, and already NAMED to the operator by `cap_profiles_assumption/1` — the advice stage
      # has nothing to judge alone when there is nothing of its own.
      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        raise "business catalogue advice: #{cap_root} unreadable (#{inspect(reason)})"

      {:ok, index} ->
        roles = Map.to_list(index)

        unless Enum.any?(roles, fn {_n, raw} -> get_in(raw, ["spec", "brief_kind"]) == "judge" end) do
          Logger.warning(
            "business catalogue advice: this catalogue declares NO judge (`brief_kind: judge`). " <>
              "Legitimate — a card may carry `jury: []` and mean it — but nothing here can " <>
              "refuse a deliverable, so check it is a choice."
          )
        end

        :ok
    end
  end

  # Runs one stage. `[]` on success, a one-element finding list on any raise/throw — the boot raises,
  # the verifier collects, so the caller sees every failure the deployment would have hit.
  defp guard(stage, fun) do
    fun.()
    []
  rescue
    e -> [%{stage: stage, error: Exception.message(e)}]
  catch
    kind, reason -> [%{stage: stage, error: "#{kind}: #{inspect(reason)}"}]
  end

  defp restore(:error), do: Application.delete_env(:lcars_fleet, :catalogue_root)
  defp restore({:ok, value}), do: Application.put_env(:lcars_fleet, :catalogue_root, value)
end
