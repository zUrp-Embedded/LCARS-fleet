defmodule Mix.Tasks.Lcars.Contracts.Check.Catalogue do
  # Z4 — classe dans la boundary de son sujet, comme la tache qui l'utilise.
  use Boundary, classify_to: Fleet.Application

  @moduledoc """
  La lecture du catalogue de roles — l'artefact que plusieurs familles de murs interrogent.

  Le catalogue est la source des roles : leur nom, leur identite forge, leur place dans le
  deploiement. Deux familles le lisent pour des raisons differentes — celle qui verifie que les
  listes de provisionnement s'accordent, celle qui verifie que la surface d'outils est accordee aux
  bons roles. Elles partagent donc le LECTEUR, jamais le contrat.

  ⚠ LES DEUX ARBRES, TOUJOURS. Les listes de provisionnement couvrent le deploiement entier — un
  role de mecanisme a besoin de son compte forge autant qu'un producteur — et ne lire que l'arbre
  metier declarerait « en trop » les roles systeme dans chaque liste, rendant rouge un deploiement
  correct.
  """

  alias Mix.Tasks.Lcars.Contracts.Check.Support

  import Mix.Tasks.Lcars.Contracts.Check.Support

  @doc false
  @spec scan_catalogue_roles(String.t()) :: [map()]
  def scan_catalogue_roles(root) do
    # BOTH catalogues. The provisioning lists cover the whole deployment — a mechanism role needs
    # its forge account exactly as much as a producer does — so scanning the business tree alone
    # would declare four roles "extra" in every list and turn a correct deployment red.
    [
      "priv/catalogue/cap_profile/canon/cap-profiles/*.yaml",
      "priv/catalogue-system/cap_profile/canon/cap-profiles/*.yaml"
    ]
    |> Enum.flat_map(&Path.wildcard(Path.join(root, &1)))
    |> Enum.reject(&String.starts_with?(Path.basename(&1), "_"))
    |> Enum.flat_map(fn path ->
      case YamlElixir.read_from_file(path) do
        {:ok, %{} = raw} ->
          [
            %{
              name: get_in(raw, ["metadata", "name"]) || Path.basename(path, ".yaml"),
              kind: Map.get(raw, "kind"),
              forge_identity: get_in(raw, ["metadata", "forge_identity"]) != false,
              role_index: get_in(raw, ["metadata", "role_index"]),
              capabilities: get_in(raw, ["spec", "capabilities"]) || [],
              allowed_tools: get_in(raw, ["spec", "scope", "allowedTools"]) || [],
              modop_default: get_in(raw, ["spec", "modop_set", "default"]) || [],
              modop_incompatible: get_in(raw, ["spec", "modop_set", "incompatible"]) || []
            }
          ]

        _ ->
          []
      end
    end)
  end

  # `Fleet.SPBuilder.filter_skills/2` must fail (fail-loud) if a whitelisted PLAIN skill is absent from
  # disk — otherwise a silent filtering would let a pod claim a nonexistent skill. BND-111: confirm the
  # EXECUTABLE tuple `{:error, {:skills_missing, ...}}` on its line (the @doc/@comment name the same tuple
  # in prose; `code_match?` excludes doc blocks, and the tuple-shape confirm excludes an inline mention).
  # Red if absent.
  @doc false
  @spec check_skills_declared_present(String.t()) :: Support.result()
  def check_skills_declared_present(root) do
    presence_check(root, %{
      id: "skills.declared_present",
      remediation:
        "make filter_skills fail-loud {:error, {:skills_missing, _}} on a missing plain skill",
      file: "lib/fleet/sp_builder.ex",
      pattern: ~r/:skills_missing/,
      confirm: [~r/:skills_missing/, ~r/\{:error, \{:skills_missing,/],
      missing:
        "filter_skills silently filters out missing skills (no executable {:error, {:skills_missing,} fail-loud)",
      note: "filter_skills must fail-loud {:error, {:skills_missing, _}} on a missing plain skill"
    })
  end

  # Z7 (F-C165 → BL-6-45) — FOUR lists declare which roles exist, and every pairwise drift has
  # bitten or nearly bitten: the canon catalogue (the SOURCE), forge.tf `local.roles` (accounts),
  # fleet/services/provision-role-tokens.sh `ROLES` (token mint default), and deploy's
  # `PROV_ROLES` (which OVERRIDES the .sh default via --roles — the list that actually wins on
  # a fresh deploy; measured: eng_doc missing there while present in the three others = the
  # BL-6-34 root-cause class resurrected). The old check covered ONE direction (.sh ⊆ canon);
  # a canon role dropped from any provisioning list looped the fleet in role_token_unavailable
  # (scoper 07-31, eng_doc 08-02 — one diagnosis session each).
  # The rule: {canon roles with forge_identity} == tf == sh == lib, STRICT EQUALITY, every
  # delta named with its own remediation. The asymmetry lives in the DATA, never in this
  # control: starfleet declares `forge_identity: false` (its forge writes go through the
  # system), a ReservedSeat (vulcan) counts as a seat = an account + a token, both inert.
  # Boundary can NEVER see any of this: three of the four lists are outside the BEAM.
  @doc false
  @spec check_roles_provisioning_locked(String.t()) :: Support.result()
  def check_roles_provisioning_locked(root) do
    # Decoded reads (kind/forge_identity are yaml fields, not greppable shapes) — the task
    # context does not start :yaml_elixir by itself; same explicit start as lcars.sp.gen.
    {:ok, _} = Application.ensure_all_started(:yaml_elixir)

    catalogue = scan_catalogue_roles(root)

    # PROJETE en LOGINS avant de comparer, parce que les trois listes en portent. Le
    # verrou ne change pas de nature — il reste l'egalite stricte des quatre — mais il compare les
    # memes objets. Meme regle que la derivation runtime : le prefixe suit le TIER, donc ou le nom
    # est declare en premier, et non le fichier qui gagne la superposition (un catalogue metier peut
    # livrer son propre `architect.yaml` sans que le compte cesse d'etre `system_architect`).
    canon =
      catalogue
      |> Enum.filter(& &1.forge_identity)
      |> Enum.map(&role_login(root, &1.name))
      |> Enum.sort()

    # Lot 6 (2026-09-04), correcting lot 1: the minter is a FORGE GESTURE of the product — the box
    # plays it at instance init — so it lives in `services/`, in this tree, always present.
    sh_path = Path.join(root, "services/provision-role-tokens.sh")

    # `deploy/deps/`: the tofu recipe is the LAST live leg of the
    # v1 tree, and this check reading it across trees is what caught the move — the wall working on
    # the gesture that touched it.
    tf_path = Path.expand("services/forge-recipe/forge.tf", root)
    lib_path = Path.expand("../deploy/lib/provision-lib.sh", root)

    # The two SIBLING-TREE lists are outside `fleet`, and one legitimate context does not
    # carry them: the image BUILD stage copies `fleet` ALONE (Dockerfile), then runs this
    # gate — a runtime-only artifact cannot prove anything about a provisioning list it does not
    # ship. So absence is read at the TREE level: no sibling tree at all = out of scope, SKIPPED
    # and named in the note (never a silent pass on unmeasured ground); tree present but file or
    # pattern unreadable = the real defect (partial checkout, renamed variable) = FAIL. The
    # `.sh` lives inside `services/` and is always present (lot 6 brought it back in-tree).
    lists =
      [
        {"provision-role-tokens.sh ROLES", :required,
         read_list(sh_path, ~r/^ROLES="([^"]*)"/m, :plain),
         "add/remove the role in ROLES=\"…\" (token mint default)"},
        # `variable "roles"` since the enroll derivation: the roster moved from a
        # `local` to a VARIABLE so a deployment can supply the roster of the catalogue it brings.
        # The DEFAULT is what this check measures, and that is the right target — it is the value
        # a deployment gets when it supplies nothing, so it is the one that must equal the canon.
        # Anchored on the variable NAME, not on a bare `default = [...]`: the recipe has other
        # list variables now, and an unanchored pattern would lock the canon against whichever
        # one happens to appear first.
        # L'UNION des deux listes : `roles` porte le metier de ce catalogue, `system_roles` l'autorite
        # d'instance partagee. Le canon ne connait pas cette coupure — il connait les comptes — donc
        # c'est ici qu'on recolle, sans quoi le verrou declarerait trois roles « manquants ».
        {"forge.tf var.roles + var.system_roles defaults",
         tree_scope(Path.expand("../deploy", root)),
         merge_lists(
           read_list(tf_path, ~r/variable\s+"roles"\s*\{.*?default\s*=\s*\[([^\]]*)\]/s, :quoted),
           read_list(
             tf_path,
             ~r/variable\s+"system_roles"\s*\{.*?default\s*=\s*\[([^\]]*)\]/s,
             :quoted
           )
         ),
         "add/remove the role in the `roles` variable default (forge account) — the canon is the " <>
           "source: a role only in forge.tf needs its cap-profile or a ReservedSeat, or loses " <>
           "its account"},
        {"provision-lib.sh PROV_ROLES", tree_scope(Path.expand("../deploy", root)),
         read_list(lib_path, ~r/\$\{PROV_ROLES:=([^}]*)\}/, :plain),
         "add/remove the role in PROV_ROLES (the list that WINS the mint on deploy — a role " <>
           "absent here gets no token on a fresh fleet)"}
      ]

    {lists, skipped} = split_out_of_scope(lists)

    {evidence, remediations} =
      Enum.reduce(lists, {[], []}, fn {label, roles, remediation}, {ev, rem} ->
        case roles do
          nil ->
            {ev ++ ["#{label}: list not readable — fail-closed (partial checkout?)"],
             rem ++ [remediation]}

          list ->
            missing = canon -- list
            extra = list -- canon
            ev2 = if missing != [], do: ["#{label}: MISSING #{inspect(missing)}"], else: []
            ev3 = if extra != [], do: ["#{label}: EXTRA #{inspect(extra)}"], else: []
            rem2 = if missing != [] or extra != [], do: [remediation], else: []
            {ev ++ ev2 ++ ev3, rem ++ rem2}
        end
      end)

    # LES TROIS LISTES DE PLACEMENT etaient hors du verrou, et c'est le meme defaut d'un cran plus
    # bas : `writers`/`judges`/`externals` sont des defauts tenus A LA MAIN pendant que la derivation
    # (`Fleet.Roster.tfvars/1`) produit deja la reponse. Rien ne les comparait, donc rien
    # n'empechait la divergence qui a coute `chief` — present dans `roles`, absent de `writers`,
    # compte sans droit d'ecriture, trouve a l'oeil sur une forge.
    #
    # La comparaison consomme la DERIVATION, pas une seconde implementation de la regle de placement
    # (siege -> externals, juge sans capacite -> judges, le reste -> writers) : la redire ici serait
    # exactement la duplication que ce verrou existe pour interdire.
    {placement, placement_note} = check_placement_defaults(root, tf_path)
    evidence = evidence ++ placement

    evidence =
      if canon == [], do: ["canon catalogue empty/not found — fail-closed"], else: evidence

    %{
      id: "roles.provisioning_locked",
      remediation:
        case remediations do
          [] -> "—"
          rems -> Enum.join(Enum.uniq(rems), " ; ")
        end,
      status: if(evidence == [] and canon != [], do: :pass, else: :fail),
      evidence: evidence,
      note:
        "four-list STRICT equality (BL-6-45)" <>
          placement_note <>
          ": canon{forge_identity} PROJECTED into " <>
          "`<catalogue>_<role>` logins (#{length(canon)} roles, seats included) == forge.tf == " <>
          "ROLES == PROV_ROLES — any delta is a defect, named" <>
          skipped_note(skipped)
    }
  end

  # role_index is the role's slot in the hexspeak UUID — the schema bounds it (0..15) per file,
  # nothing enforced uniqueness across the catalogue (BL-6-45 F7): two roles on one slot would
  # make `pkill -f '<X>badcafe'` kill classes collide. Seats included (a seat CLAIMS its slot).
  # ── sp.adresser_un_agent ───────────────────────────────────────────────────────────────────────
  # UNE SOURCE DE PROSE, DIX NOMS, UN MUR. La regle doit atteindre TOUS les roles, et elle ne peut
  # pas passer par un bloc partage : l'audit impose UNE source par role, et les roles a draft sont
  # justement les premiers concernes. Recopier le paragraphe en ferait deux exemplaires de prose —
  # et deux proses divergent en restant plausibles. Elle passe donc par l'ENVELOPPE, que chaque
  # carte NOMME.
  #
  # ⚠ CE CHECK EXISTE PARCE QU'UN NOM MANQUANT EST SILENCIEUX : un role dont la carte oublie la
  # ligne ne recoit rien, et rien ne le dit. Un drapeau peut manquer, une prose peut mentir — l'un
  # se detecte, l'autre non, et c'est tout ce que ce mur achete.
  #
  # ⚠ ET IL PORTE SUR `default`, PAS SUR LA PRESENCE : aucun appelant de production n'active un
  # bundle `optional`, donc un role qui declarerait celui-ci ainsi passerait un controle naif en ne
  # recevant RIEN. Le second volet lit `incompatible:` pour la meme raison — l'y nommer retirerait
  # legalement le bundle, et ce n'est pas un mode commutable.
  #
  # Les sieges reserves sont hors perimetre : sans `spec`, pas de SP a garnir.
  @adresser_bundle "adresser-un-agent"
  @doc false
  @spec check_sp_adresser_un_agent(String.t()) :: Support.result()
  def check_sp_adresser_un_agent(root) do
    {:ok, _} = Application.ensure_all_started(:yaml_elixir)

    profiles =
      root
      |> scan_catalogue_roles()
      |> Enum.filter(&(&1.kind == "CapabilityProfile"))

    missing =
      profiles
      |> Enum.reject(&(@adresser_bundle in &1.modop_default))
      |> Enum.map(& &1.name)
      |> Enum.sort()

    # `incompatible` est une liste de PAIRES : le bundle ne doit apparaitre dans aucune.
    #
    # ⚠ ET ON ACCEPTE AUSSI L'ENTREE PLATE, QUI EST UNE MALFORMATION. `incompatible:
    # [adresser-un-agent]` (des chaines au lieu de paires) fait echouer le `is_list(pair)` : chaque
    # element est une chaine, aucun n'est signale, et le mur passe au VERT sur un
    # profil qui retire pourtant le bundle. Le schema doit refuser cette forme en amont — mais un
    # mur qui ne tient que si un AUTRE controle a fait son travail ne tient rien par lui-meme, et
    # c'est precisement la classe de faux-vert que ce fichier existe pour interdire.
    excluded =
      profiles
      |> Enum.filter(fn p ->
        Enum.any?(p.modop_incompatible, fn entry ->
          (is_list(entry) and @adresser_bundle in entry) or entry == @adresser_bundle
        end)
      end)
      |> Enum.map(& &1.name)
      |> Enum.sort()

    bundle =
      Path.join(
        root,
        "priv/catalogue-system/cap_profile/canon/modop-bundles/#{@adresser_bundle}/sp.md"
      )

    cond do
      not File.regular?(bundle) ->
        %{
          id: "sp.adresser_un_agent",
          status: :fail,
          remediation:
            "le bundle #{@adresser_bundle} est nomme par les cartes et sa prose est ABSENTE — " <>
              "les pods recevraient un nom qui ne compose rien",
          evidence: ["source introuvable : #{Path.relative_to(bundle, root)}"],
          note: "la source unique de prose du bundle"
        }

      measured_nothing?(profiles) ->
        broken_result("sp.adresser_un_agent", "CapabilityProfile in the catalogues")

      true ->
        %{
          id: "sp.adresser_un_agent",
          status: if(missing == [] and excluded == [], do: :pass, else: :fail),
          remediation:
            "ajouter `#{@adresser_bundle}` a `spec.modop_set.default` de la carte (jamais " <>
              "`optional` : aucun appelant de production ne l'activerait ; jamais dans un " <>
              "`incompatible:` : ce n'est pas un mode commutable)",
          evidence:
            Enum.map(missing, &"#{&1} : absent de modop_set.default") ++
              Enum.map(excluded, &"#{&1} : nomme dans un incompatible: — retire au role"),
          note:
            "une seule source de prose (le bundle), un nom par carte, ce mur contre le nom " <>
              "manquant (#{length(profiles)} profil(s) mesure(s) ; les ReservedSeat sont hors perimetre)"
        }
    end
  end

  @doc false
  @spec check_roles_role_index_unique(String.t()) :: Support.result()
  def check_roles_role_index_unique(root) do
    {:ok, _} = Application.ensure_all_started(:yaml_elixir)

    indexed =
      scan_catalogue_roles(root)
      |> Enum.filter(&is_integer(&1.role_index))

    duplicates =
      indexed
      |> Enum.group_by(& &1.role_index, & &1.name)
      |> Enum.filter(fn {_idx, names} -> length(names) > 1 end)

    if measured_nothing?(indexed) do
      broken_result("roles.role_index_unique", "catalogue role carrying a role_index")
    else
      %{
        id: "roles.role_index_unique",
        remediation:
          "two catalogue entries claim the same role_index slot — reassign one (0..15, " <>
            "see each file's metadata comment for the taken slots)",
        status: if(duplicates == [], do: :pass, else: :fail),
        evidence:
          Enum.map(duplicates, fn {idx, names} ->
            "role_index #{idx} claimed by: #{Enum.join(Enum.sort(names), ", ")}"
          end),
        note: "role_index (hexspeak UUID slot) unique across the canon catalogue, seats included"
      }
    end
  end

  # A face's root must EXIST on the machine before anything can put a repo in it, and the runtime
  # cannot create it: the fleet runs as the human, `/home` belongs to root. Two creators write it,
  # each a hand-written mirror of `Fleet.Layout.face_root/1` in another language — the exact shape
  # that drifts without a word.
  #
  # TWO SITES, AND THE NARROWER ONE IS THE EASY MISS. Reading only
  # docker entrypoint alone, so it was green on a rail that recognises THREE substrates
  # (`docker`, `wsl`, `linux`) while creating the zones on one. On `wsl` they existed "by history of
  # the substrate" — by hand, one day, on the author's machine — and on a native `linux`, not at
  # all. Same failure as the `doc` face below, on the path the check did not cover.
  #
  # Measured on a fresh bench: the `doc` face was in the code AND in the image's `build`
  # stage (added so the gate could run), and NOT in the entrypoint. The box came up healthy, the
  # fleet started, and the first `project_create` died on `could not make directory (with -p)
  # "/home/projects.workshop": permission denied`. Nothing before that moment could have said it.
  #
  # FAIL-CLOSED ON THE ANCHOR: if the `install -d` line cannot be found, this check FAILS instead of
  # passing on an empty read. A renamed line would otherwise turn the guard off in silence, which is
  # worse than the drift it watches.
  @doc false
  @spec check_face_roots_provisioned(String.t()) :: Support.result()
  def check_face_roots_provisioned(root) do
    entrypoint = Path.expand("../deploy/docker/entrypoint.sh", root)
    module = Path.expand("../deploy/modules.d/25-directories.sh", root)
    expected = read_face_roots(Path.expand("lib/fleet/layout.ex", root))

    remediation =
      "add the face root to the `install -d` line of deploy/docker/entrypoint.sh — a face declared " <>
        "in Fleet.Layout with no zone on the machine makes the box look healthy and kills the " <>
        "first onboard that needs it (the runtime runs as the human; /home belongs to root)"

    case tree_scope(Path.expand("../deploy", root)) do
      :out_of_scope ->
        %{
          id: "layout.face_roots_provisioned",
          remediation: "—",
          status: :pass,
          evidence: [],
          note: "NOT CHECKED here (deploy/ absent from this artifact — runtime-only context)"
        }

      :required ->
        case {expected, read_install_zone_paths(entrypoint), read_provision_zone_paths(module)} do
          {nil, _, _} ->
            %{
              id: "layout.face_roots_provisioned",
              remediation: remediation,
              status: :fail,
              evidence: ["lib/fleet/layout.ex"],
              note: "face_root/1 unreadable in Fleet.Layout — guard fail-closed, nothing measured"
            }

          {_, nil, _} ->
            %{
              id: "layout.face_roots_provisioned",
              remediation: remediation,
              status: :fail,
              evidence: [Path.relative_to(entrypoint, root)],
              note: "the `install -d -m 2775 -g fleet` anchor is unreadable — guard fail-closed"
            }

          {_, _, nil} ->
            %{
              id: "layout.face_roots_provisioned",
              remediation: remediation,
              status: :fail,
              evidence: [Path.relative_to(module, root)],
              note:
                "the provision module's `2775` zone table is unreadable — guard fail-closed " <>
                  "(this is the creator on every substrate; the entrypoint only covers docker)"
            }

          {expected, at_boot, on_every_substrate} ->
            missing =
              Enum.map(expected -- at_boot, &"#{&1}: absent de l'entrypoint docker") ++
                Enum.map(
                  expected -- on_every_substrate,
                  &"#{&1}: absent du module provision (donc absent sur wsl et linux)"
                )

            %{
              id: "layout.face_roots_provisioned",
              remediation: remediation,
              status: if(missing == [], do: :pass, else: :fail),
              evidence: missing,
              note:
                "les #{length(expected)} racines de face de Fleet.Layout sont créées par les DEUX " <>
                  "miroirs — le module provision (tout substrat) et l'entrypoint docker (l'ordre " <>
                  "de boot l'exige avant `provision apply`) : #{Enum.join(expected, ", ")}"
            }
        end
    end
  end

  # The face roots, READ from `Fleet.Layout`'s source rather than called. This task references no
  # Fleet module at runtime — by design: a contract checker that CALLED the code would be measuring
  # the code with the code, and `Fleet.Application` (which classifies this task, Z4) does not carry
  # an edge to Layout. Same shape as `read_list/3` above: cross-language facts are read, and the
  # authority stays where it is.
  #
  # `face_root/1` has one clause per face; the body is an attribute (today) or could be the literal
  # itself. BOTH are read, and a body that is NEITHER makes the whole read nil.
  #
  # That last part is the point, and it cost a surviving mutation to find. The first version matched
  # only `do: @attr`; inlining one clause's literal made that clause invisible, and the check then
  # declared a 2-face population fully provisioned — green, with a smaller subject than it names.
  # The mutation was semantically harmless, the READER was not: any face whose body it cannot parse
  # would vanish the same way, including one whose root is genuinely missing from the machine.
  # A guard that silently narrows its population is the exact defect this check exists to close.
  defp read_face_roots(layout_path) do
    with {:ok, src} <- File.read(layout_path),
         [_ | _] = clauses <- Regex.scan(~r/^\s*def face_root\("([a-z]+)"\), do: (.+)$/m, src) do
      attrs =
        ~r/^\s*@([a-z_]+)\s+"(\/[^"]+)"$/m
        |> Regex.scan(src)
        |> Map.new(fn [_, name, value] -> {name, value} end)

      roots = Enum.map(clauses, fn [_, _face, body] -> resolve_face_root(body, attrs) end)
      if Enum.any?(roots, &is_nil/1), do: nil, else: Enum.sort(roots)
    else
      _ -> nil
    end
  end

  defp resolve_face_root(body, attrs) do
    case String.trim(body) do
      "@" <> attr -> Map.get(attrs, attr)
      ~s(") <> _ = literal -> literal |> String.trim(~s(")) |> nonempty_abs_path()
      _ -> nil
    end
  end

  defp nonempty_abs_path("/" <> _ = p), do: p
  defp nonempty_abs_path(_), do: nil

  # The paths of the entrypoint's zone-creating line. Absolute tokens only — the flags (`-d`,
  # `-m 2775`, `-g fleet`) are not paths, and matching them as such would make a missing face
  # indistinguishable from a changed mode.
  defp read_install_zone_paths(path) do
    with {:ok, content} <- File.read(path),
         [_, tail] <- Regex.run(~r/^install\s+-d\s+-m\s+2775\s+-g\s+fleet\s+(.+)$/m, content) do
      tail |> String.split() |> Enum.filter(&String.starts_with?(&1, "/"))
    else
      _ -> nil
    end
  end

  # The face zones of the PROVISION module — the substrate-agnostic creator. Read from its table
  # (`"<path> <mode> <owner>"`, one entry per line), and only the `2775` rows: the module also
  # provisions `/local` and the token dir, which are not faces.
  #
  # WHY THERE ARE TWO MIRRORS AND WHY BOTH ARE HELD HERE. The docker entrypoint creates these zones
  # too, and that is not a forgotten duplicate: it clones the source into `/home/projects/LCARS`
  # long BEFORE it calls `provision apply`, so the zones must exist earlier than the module runs.
  # Boot ordering is the reason for the second mirror. What must never happen is the two drifting
  # from `Fleet.Layout`, or from each other — so the check compares BOTH against the code, and its
  # evidence says which mirror is short. A wall that held one of two mirrors was green on a fleet
  # whose `wsl` and `linux` substrates created no zone at all.
  defp read_provision_zone_paths(path) do
    case File.read(path) do
      {:ok, content} ->
        case Regex.scan(~r/^\s*"(\/[^"\s]+)\s+2775\s/m, content) do
          [] -> nil
          rows -> rows |> Enum.map(fn [_, p] -> p end) |> Enum.sort()
        end

      _ ->
        nil
    end
  end

  # One provisioning list, read fail-closed: nil when the file or its anchor pattern is absent
  # (partial checkout / renamed variable — the caller renders the named fail, never a silent
  # empty list that would flag every canon role as missing with the wrong message).
  defp read_list(path, regex, format) do
    with {:ok, content} <- File.read(path),
         [_, inner] <- Regex.run(regex, content) do
      case format do
        :plain ->
          inner |> String.split() |> Enum.sort()

        :quoted ->
          ~r/"([^"]+)"/ |> Regex.scan(inner) |> Enum.map(fn [_, s] -> s end) |> Enum.sort()
      end
    else
      _ -> nil
    end
  end

  # The canon catalogue read ONCE for both role checks: name (metadata.name, basename fallback),
  # kind, forge_identity (absent = true), role_index. Underscore basenames = overlay fragments
  # (the `_frozen-monks` convention), excluded like name_index does; undecodable yaml = entry
  # dropped HERE (the boot's name_index fail-louds on it — this check only counts names).
  # Rendue muette quand le catalogue bundle n'est pas la (etape BUILD de l'image, fixture de test) :
  # meme regle que les listes de l'arbre frere — l'absence d'un arbre est hors-perimetre, jamais un
  # vert silencieux sur du terrain non mesure.
  defp merge_lists(nil, _), do: nil
  defp merge_lists(_, nil), do: nil
  defp merge_lists(a, b), do: Enum.sort(a ++ b)

  @placement_checked " + the THREE placement defaults against the derivation"

  defp check_placement_defaults(root, tf_path) do
    catalogue = Path.join(root, "priv/catalogue")

    # HORS-PERIMETRE quand l'arbre `deploy/` n'est pas la — MEME regle que les listes de l'arbre
    # frere juste au-dessus, et je l'avais oubliee. L'etage BUILD de l'image copie `fleet/` SANS
    # `deploy/` (COPY explicite, par choix), donc la recette n'y est pas : les listes existantes se
    # skippaient proprement pendant que celle-ci rendait « not readable — fail-closed ». Un gate vert
    # sur l'hote et rouge dans l'image, sur un artefact qui n'a jamais fait partie du perimetre.
    if File.dir?(Path.expand("../deploy", root)) and File.dir?(catalogue) do
      case Fleet.Roster.tfvars(catalogue) do
        {:ok, derived} ->
          ev =
            Enum.flat_map(~w(writers judges externals), fn key ->
              rx = ~r/variable\s+"#{key}"\s*\{.*?default\s*=\s*\[([^\]]*)\]/s
              hard = read_list(tf_path, rx, :quoted)
              want = Enum.sort(Map.get(derived, key, []))

              cond do
                hard == nil ->
                  ["forge.tf var.#{key} default: not readable — fail-closed"]

                Enum.sort(hard) == want ->
                  []

                true ->
                  [
                    "forge.tf var.#{key} default #{inspect(Enum.sort(hard))} != derivation #{inspect(want)}"
                  ]
              end
            end)

          {ev, @placement_checked}

        {:error, reason} ->
          {["placement derivation unreadable (#{inspect(reason)}) — fail-closed"],
           @placement_checked}
      end
    else
      # PAS un vert silencieux : la note le DIT. Une verification qui borne sa couverture sans le
      # dire se lit comme une couverture complete — et c'est ainsi qu'un mur devient decoratif.
      {[], " (placement defaults SKIPPED: no `deploy` tree)"}
    end
  end

  defp role_login(root, role) do
    prefix =
      if MapSet.member?(system_role_names(root), role), do: "system", else: bundled_name(root)

    "#{prefix}_#{role}"
  end

  defp system_role_names(root) do
    root
    |> Path.join("priv/catalogue-system/cap_profile/canon/cap-profiles/*.yaml")
    |> Path.wildcard()
    |> Enum.reject(&String.starts_with?(Path.basename(&1), "_"))
    |> Enum.flat_map(fn path ->
      case YamlElixir.read_from_file(path) do
        {:ok, %{} = raw} -> [get_in(raw, ["metadata", "name"]) || Path.basename(path, ".yaml")]
        _ -> []
      end
    end)
    |> MapSet.new()
  end

  defp bundled_name(root) do
    case YamlElixir.read_from_file(Path.join(root, "priv/catalogue/catalogue.yaml")) do
      {:ok, %{"name" => n}} when is_binary(n) -> n
      _ -> "fleet"
    end
  end

  # ── Catalogue install paths: ONE fact, THREE languages ───────────────────
  # `Fleet.Layout` says where the installed catalogues sit and where the image's seeds sit.
  # `bin/lcars` reads both and `deploy/lib/provision-lib.sh` WRITES one of them, and neither can
  # call Elixir — so the same paths exist three times, in languages that have no way to agree by
  # construction.
  #
  # What a divergence costs is worse than a crash, and the provisioning half is the expensive one:
  # `45-catalogues` would converge a directory the runtime never reads. Every boot would clone the
  # installed catalogues, report them converged, and the fleet would run on the bundled one alone
  # while announcing three. Nothing errors and nothing is logged. The CLI half is milder but hits
  # at the worst moment — degraded `catalogue list` (no release reachable) prints the material of a
  # cache nobody runs on, which is exactly when the operator has no second source to check it
  # against.
  #
  # Same family as the four provisioning lists locked above, and the same fix — the shells' DEFAULTS
  # are read out of the scripts and compared to what the module derives.
  #
  # The env overrides (`LCARS_CATALOGUES_*`, `PROV_CATALOGUES_DIR`) are deliberately not checked: an
  # operator pointing them elsewhere is answering for both halves themselves. What must agree is
  # what happens when nobody sets anything, which is every deployment.
  #
  # ⚠ THE PROVISIONING HALF IS A SIBLING TREE, AND ONE LEGITIMATE CONTEXT DOES NOT CARRY IT: the
  # image BUILD stage copies `fleet` ALONE and then runs this gate. Measured — adding
  # the third source turned the image build red on a file it cannot have. Absence is read at the
  # TREE level, like the provisioning lists above: no `deploy` tree = out of scope, SKIPPED and
  # NAMED in the note; tree present and the default gone = the real defect, FAIL.
  @doc false
  @spec check_catalogue_paths_locked(String.t()) :: Support.result()
  def check_catalogue_paths_locked(root) do
    layout = "lib/fleet/layout.ex"
    cli = "bin/lcars"
    lib = "../deploy/lib/provision-lib.sh"
    layout_src = read_or_empty(root, layout)
    cli_src = read_or_empty(root, cli)
    lib_src = read_or_empty(root, lib)

    # Read from the SOURCE, not by calling the module: this check is classified into
    # `Fleet.Application`, which may not reference foundation's `Fleet.Layout` — and a boundary is
    # not widened to let a lint reach across it. Reading both files is also the truer comparison:
    # the fact under test is what the two SOURCES say, and a runtime value could agree with neither.
    attrs =
      Map.new(
        ~w(platform_root catalogues_dirname installed_catalogues_root),
        &{&1, module_attribute(layout_src, &1)}
      )

    expected =
      if Enum.any?(attrs, fn {_k, v} -> is_nil(v) end) do
        nil
      else
        %{
          "LCARS_CATALOGUES_DIR" => attrs["installed_catalogues_root"],
          "LCARS_CATALOGUES_SHIPPED" => "#{attrs["platform_root"]}/#{attrs["catalogues_dirname"]}"
        }
      end

    # `${VAR:=default}` in the lib, `${VAR:-default}` in the CLI — two different shell operators for
    # the same fact. `shell_default/2` reads both, because the difference is about who ASSIGNS, not
    # about what the default IS.
    deploy? = File.dir?(Path.expand("../deploy", root))

    sources =
      [{cli, cli_src, expected || %{}}] ++
        if deploy?, do: [{lib, lib_src, lib_expected(expected)}], else: []

    mismatches =
      for {file, src, wanted} <- sources,
          {var, want} <- wanted,
          got = shell_default(src, var),
          got != want,
          do: "#{var}: #{file} defaults to #{inspect(got)}, #{layout} says #{inspect(want)}"

    missing =
      for {file, src, wanted} <- sources,
          {var, _} <- wanted,
          is_nil(shell_default(src, var)),
          do: "#{var} (#{file})"

    %{
      id: "catalogue.install_paths_locked",
      remediation:
        "make bin/lcars and deploy/lib/provision-lib.sh agree with Fleet.Layout (@platform_root, " <>
          "@catalogues_dirname, @installed_catalogues_root) — provisioning that converges a " <>
          "directory the runtime does not read reports every catalogue installed and serves none",
      status:
        if(not is_nil(expected) and mismatches == [] and missing == [], do: :pass, else: :fail),
      evidence:
        cond do
          is_nil(expected) ->
            [
              "#{layout}: INSTRUMENT BROKEN — a catalogue path attribute is gone or renamed; " <>
                "this check measured nothing"
            ]

          missing != [] ->
            [
              "no shell default for #{inspect(Enum.sort(missing))} — that half stopped carrying " <>
                "the path"
            ]

          true ->
            Enum.sort(mismatches)
        end,
      note:
        "3 catalogue paths, one fact each, agreed between #{layout} and #{cli}" <>
          if(deploy?,
            do: " and #{lib}",
            else:
              " · #{lib} NOT CHECKED here (tree absent from this artifact — runtime-only context)"
          )
    }
  end

  # The provisioning lib carries ONE of the two paths — the installed cache, which `45-catalogues`
  # writes. It has no business with the image's seeds: it never reads them.
  defp lib_expected(nil), do: %{}
  defp lib_expected(exp), do: %{"PROV_CATALOGUES_DIR" => exp["LCARS_CATALOGUES_DIR"]}

  defp read_or_empty(root, rel) do
    path = Path.join(root, rel)
    if File.regular?(path), do: File.read!(path), else: ""
  end

  # `@name "value"` — the literal as the module declares it.
  defp module_attribute(source, name) do
    case Regex.run(~r/^\s*@#{name}\s+"([^"]*)"/m, source) do
      [_, value] -> value
      nil -> nil
    end
  end

  # `VAR="${VAR:-<default>}"` — the DEFAULT only, never the override. An operator pointing the env
  # elsewhere is answering for both halves themselves; what must agree is what happens when nobody
  # sets anything, which is every deployment.
  defp shell_default(source, var) do
    case Regex.run(~r/\$\{#{var}:[-=]([^}]*)\}/, source) do
      [_, default] -> default
      nil -> nil
    end
  end
end
