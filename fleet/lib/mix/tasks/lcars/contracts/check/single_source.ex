defmodule Mix.Tasks.Lcars.Contracts.Check.SingleSource do
  # Z4 — classe dans la boundary de son sujet, comme la tache qui l'utilise.
  use Boundary, classify_to: Fleet.Application

  @moduledoc """
  Z7 — les verrous « un fait, une source », a travers les langages.

  Chacun de ces murs garde UN fait que plusieurs composants doivent connaitre et qu'aucun langage ne
  peut partager : un nom de branche, une racine de systeme de fichiers, un compte systeme. Le BEAM
  le DECLARE, le shell, le python et le terraform le RECOPIENT — et une copie que personne ne
  verifie n'est pas une source unique de verite, c'est une coincidence qui a tenu jusqu'ici.

  ⚠ LA FORME DANGEREUSE EST LE VERROU PARTIEL, et ce fichier en a porte un pendant huit jours : il
  tenait quatre copies sur cinq et sa note annoncait « plus rien de reglable ». Un verrou qui couvre
  une fraction de son fait reste vert pendant que le reste derive, et il SE LIT comme une garantie —
  strictement pire que pas de verrou, qui au moins pousse quelqu'un a aller voir. Quand un lecteur
  d'un de ces faits apparait, il entre dans la liste `mirrors` du meme geste.

  Les murs sont appeles par `run_checks/0` de la tache ; l'outillage vient de `Support`.
  """

  alias Mix.Tasks.Lcars.Contracts.Check.Support

  import Mix.Tasks.Lcars.Contracts.Check.Support

  @doc """
  The tool-request branch is named in ONE place and copied everywhere else, and the copies are
  checked here.

  Six components must agree on that name: the provisioning module that creates the branch, the
  gesture that protects it, the admiral skill that reads the letterbox, the converger that refuses
  any other head, the root executor that asks the forge for that head, and `Fleet.Toolchain` that
  declares it. Four are shell, one is python, one is the BEAM — they cannot share a literal, so
  `Toolchain` DECLARES it and the others copy. A copy nobody verifies is not a single source of
  truth; this check is what makes the claim true.

  It also refuses `LCARS_SYSADMIN_BRANCH` anywhere under `deploy/`. That variable made the name
  HALF tunable: turning it moved the shell side while the BEAM kept its own default, so the branch
  was created and protected under one name while the reconciler polled another — manifests landing
  where nobody looks, no message, a rail that looks calm.

  ⚠ A PARTIAL LOCK IS THE DANGEROUS SHAPE, AND THIS ONE WAS PARTIAL FOR EIGHT DAYS. It held four
  of five copies and its own note said "no tunable left". A lock that covers a fraction of its
  fact is green while the rest drifts, and it reads like a guarantee — strictly worse than no lock
  at all, which at least prompts someone to look. When a reader of this fact is added, it is added
  to `mirrors` in the same gesture, or this doc is a lie again.
  """
  @spec check_toolchain_branch_single_source(String.t()) :: Support.result()
  def check_toolchain_branch_single_source(root) do
    mirrors = [
      "deploy/modules.d/52-ops-branch.sh",
      "services/forge-gestures.sh",
      "deploy/admiral/skills/system-issues/list.sh",
      # ⚠ QUATRIEME MIROIR, et il est le seul qui porte une BORNE DE SECURITE : le convergeur
      # refuse tout SHA qui n'est pas la tete de cette branche, et c'est ce refus qui empeche
      # un membre du groupe de faire installer en root un manifeste que personne n'a signe.
      "bin/lcars-toolchain-converge",
      # FIFTH MIRROR, and it is the OTHER half of that security bound. The converger refuses any
      # SHA that is not the head of the branch IT names; the root executor ASKS the forge for the
      # head of the branch IT names. The bound only holds while both names agree — and until
      # 2026-08-27 this wall watched the second and not the first. Measured: renaming the literal
      # here alone left the check green, with the only root process on this machine converging on
      # a branch nobody else writes to.
      "services/privileged-executor.py"
    ]

    # ⚠ SCOPE IS DECIDED PER MIRROR, AND IT USED TO BE DECIDED BY ONE TREE FOR ALL FIVE. The guard
    # asked `is deploy/ here?` and, on a miss, declared the whole check "NOT CHECKED" — including
    # `services/` and `bin/`, which the image's build stage DOES carry (it excludes only `deploy`,
    # `git-hooks`, `system-prompt`). So in the artifact where this gate runs most often, three
    # readable mirrors went unread and the check reported a clean skip. A blanket scope is a
    # coverage hole that answers "not my business" on files it is holding.
    {checked, skipped} =
      Enum.split_with(mirrors, fn rel ->
        tree_scope(Path.expand(hd(Path.split(rel)), root)) == :required
      end)

    id = "toolchain.branch_single_source"

    remediation =
      "copy the literal from `Fleet.Toolchain.branch/0` into the copy, and never reintroduce " <>
        "`LCARS_SYSADMIN_BRANCH` — a name half of the rail can retune is a rail that splits in " <>
        "silence"

    expected =
      case File.read(Path.expand("lib/fleet/toolchain.ex", root)) do
        {:ok, src} ->
          # ⚠ ANCRE EN FIN DE LIGNE, ET SANS CA LE FAIL-CLOSED ETAIT UN FAUX. Sans `\s*$`, la regex
          # accepte un PREFIXE : `do: "tool_" <> "request"` se lit `"tool_"`, et le check compare
          # alors les miroirs a une valeur TRONQUEE au lieu de declarer l'autorite illisible. Il
          # rougit — donc le defaut ne passe pas — mais il rougit en accusant dix fichiers sains
          # d'un ecart qu'ils n'ont pas, et le lecteur cherche au mauvais endroit. Mesure du
          # 2026-08-27, sur le jumeau `forge.system_account_single_source`, en jouant la mutation.
          case Regex.run(~r/def\s+branch,\s*do:\s*"([^"]+)"\s*$/m, src) do
            [_, name] -> name
            _ -> nil
          end

        _ ->
          nil
      end

    case checked do
      [] ->
        out_of_scope(id, "no mirror tree present", skipped)

      _ ->
        if is_nil(expected) do
          unreadable_authority(
            id,
            remediation,
            "lib/fleet/toolchain.ex",
            "Fleet.Toolchain.branch/0"
          )
        else
          bad =
            Enum.flat_map(checked, fn rel ->
              case File.read(Path.expand(rel, root)) do
                {:ok, body} ->
                  cond do
                    # ⚠ LA FORME, PAS UN NOM. Cette clause a epingle le litteral
                    # `LCARS_SYSADMIN_BRANCH` — donc un quatrieme lecteur qui a nomme sa
                    # variable AUTREMENT est passe au vert en rendant la borne reglable.
                    # Un mur qui refuse UN nom n'interdit pas le GESTE : ce qui se refuse
                    # est qu'un nom de branche vienne d'une expansion, quel que soit son nom.
                    Regex.match?(~r/\$\{[A-Za-z_]*BRANCH[A-Za-z_]*[\}:]/, body) ->
                      [
                        {rel,
                         "derives the branch from an expansion — the name is frozen, not tunable"}
                      ]

                    # THE SAME REFUSAL, WRITTEN IN THE OTHER LANGUAGE THIS LIST NOW HOLDS. The
                    # clause above refuses a shell expansion; a python mirror cannot produce one,
                    # so on its own it would have watched a file against a shape that file can
                    # never take. The tunable gesture in python is a read from the environment —
                    # and in `privileged-executor.py` the line above the branch is exactly that
                    # (`os.environ.get("LCARS_OPS_REPO", …)`), so the half-tunable this wall
                    # exists to refuse is one copy-paste away.
                    Regex.match?(
                      ~r/os\.(?:environ\.get|getenv)\(\s*["'][^"']*BRANCH|os\.environ\[\s*["'][^"']*BRANCH/,
                      body
                    ) ->
                      [
                        {rel,
                         "reads the branch from the environment — the name is frozen, not tunable"}
                      ]

                    String.contains?(body, "LCARS_SYSADMIN_BRANCH") ->
                      [{rel, "carries LCARS_SYSADMIN_BRANCH — the name is frozen, not tunable"}]

                    not String.contains?(body, "\"#{expected}\"") ->
                      [{rel, "does not carry the literal #{inspect(expected)}"}]

                    true ->
                      []
                  end

                _ ->
                  [{rel, "unreadable"}]
              end
            end)

          if bad == [] do
            %{
              id: id,
              remediation: "—",
              status: :pass,
              evidence: checked,
              note:
                "#{inspect(expected)} declared by Fleet.Toolchain.branch/0 and copied by the " <>
                  "#{length(checked)} readers that carry it; no tunable left" <>
                  skipped_note(skipped)
            }
          else
            %{
              id: id,
              remediation: remediation,
              status: :fail,
              evidence: Enum.map(bad, &elem(&1, 0)),
              note:
                "authority says #{inspect(expected)} — " <>
                  Enum.map_join(bad, " · ", fn {f, why} -> "#{f}: #{why}" end) <>
                  skipped_note(skipped)
            }
          end
        end
    end
  end

  @doc """
  The two catalogue roots are declared ONCE in `Fleet.Layout` and copied into the shell, and the
  copies are checked here.

  `catalogues_shipped_dir/0` (`@platform_root` + `@catalogues_dirname`) is where the IMAGE deposits
  its seeds; `catalogues_installed_dir/0` (`@installed_catalogues_root`) is the cache the forge
  restores into. Nine files carry one of the two: the BEAM declares them, the Dockerfile CREATES
  the shipped tree, the manifest creates the installed one, and five shell/CLI readers copy them.
  They cannot share a literal across the language boundary, so `Layout` DECLARES and the rest copy.

  ⚠ `bin/lcars` ALREADY NAMED THIS LOCK, AND THE LOCK DID NOT EXIST. Its comment reads: *"C'est un
  fait ecrit deux fois, dans deux langages qui ne peuvent pas s'appeler — la meme forme que les
  listes de roles verrouillees par `mix lcars.contracts.check`"*. It named the pattern, named the
  tool, and nothing held it. Naming a cost is not paying it.

  ⚠ AND TWO WITNESSES PINNED THE LITERAL WITHOUT KNOWING THE AUTHORITY.
  `forge_host_reach.bats` asserts the exact strings `/opt/lcars/catalogues/web-demo` and
  `COPY catalogues /opt/lcars/catalogues`. Move `@platform_root` and both stay GREEN on the old
  value — a witness that pins a literal defends the literal, not the agreement.

  What breaks without this: the fleet reads seeds where the image never wrote them. `bin/lcars`
  says when it hurts most — the CLI shows the cache in DEGRADED mode, release unreachable, which
  is precisely the moment the operator has no second source to cross-check against.
  """
  @spec check_catalogue_roots_single_source(String.t()) :: Support.result()
  def check_catalogue_roots_single_source(root) do
    id = "layout.catalogue_roots_single_source"

    remediation =
      "copy the value from `Fleet.Layout.catalogues_shipped_dir/0` / `catalogues_installed_dir/0` " <>
        "into the shell copy — the BEAM and the shell cannot call each other, so the agreement is " <>
        "what makes the single source true"

    src =
      case File.read(Path.expand("lib/fleet/layout.ex", root)) do
        {:ok, s} -> s
        _ -> nil
      end

    attr = fn name ->
      with true <- is_binary(src),
           # Ancre de fin de ligne : une valeur composee (`"/opt/" <> "lcars"`) doit rendre
           # l'autorite ILLISIBLE, pas un prefixe silencieusement tronque.
           [_, v] <- Regex.run(~r/@#{name}\s+"([^"]+)"\s*$/m, src) do
        v
      else
        _ -> nil
      end
    end

    platform = attr.("platform_root")
    dirname = attr.("catalogues_dirname")
    installed = attr.("installed_catalogues_root")

    if is_nil(platform) or is_nil(dirname) or is_nil(installed) do
      # Fail-closed, same rule as its sibling: an unreadable authority is not "nothing to compare",
      # it is the one case where every mirror passes by default.
      %{
        id: id,
        remediation: remediation,
        status: :fail,
        evidence: ["lib/fleet/layout.ex"],
        note:
          "Fleet.Layout no longer reads as three frozen literals (@platform_root, " <>
            "@catalogues_dirname, @installed_catalogues_root) — nothing was compared"
      }
    else
      shipped = Path.join(platform, dirname)

      mirrors = [
        {"bin/lcars", ~r/CAT_SHIPPED="\$\{LCARS_CATALOGUES_SHIPPED:-#{Regex.escape(shipped)}\}"/,
         "the CLI's shipped-catalogue default"},
        {"bin/lcars", ~r/CAT_DIR="\$\{LCARS_CATALOGUES_DIR:-#{Regex.escape(installed)}\}"/,
         "the CLI's installed-catalogue default"},
        {"services/forge-gestures.sh", ~r/\$\{LCARS_DEMO_CATALOGUE:-#{Regex.escape(shipped)}\//,
         "the demo catalogue the forge gesture publishes"},
        {"services/forge-gestures.sh", ~r/\$\{LCARS_CATALOGUES_DIR:-#{Regex.escape(installed)}\}/,
         "the installed root the forge gesture reads"},
        # ⚠ LE CREATEUR, PAS UN LECTEUR — et c'est le miroir qui compte le plus. Si le `COPY` ne
        # suit pas l'autorite, la fleet lit un arbre que l'image n'a jamais ecrit.
        {"deploy/docker/Dockerfile", ~r/^COPY\s+catalogues\s+#{Regex.escape(shipped)}\s*$/m,
         "the image COPY that creates the shipped tree"},
        {"deploy/system.manifest", ~r/^dir\s+#{Regex.escape(installed)}\s/m,
         "the manifest row that creates the installed tree"},
        {"deploy/lib/provision-lib.sh",
         ~r/:\s*"\$\{PROV_CATALOGUES_DIR:=#{Regex.escape(installed)}\}"/,
         "the provisioning default"}
      ]

      # ⚠ LE PERIMETRE SE DIT PAR MIROIR. `bin/` et `services/` partent avec l'image, `deploy/` non
      # (le stage `build` l'exclut explicitement). Un perimetre decide sur un seul arbre declarerait
      # « NOT CHECKED » sur quatre fichiers presents — la faute corrigee le meme jour sur les deux
      # verrous voisins.
      {checked, skipped} =
        Enum.split_with(mirrors, fn {rel, _rx, _what} ->
          tree_scope(Path.expand(hd(Path.split(rel)), root)) == :required
        end)

      bad =
        Enum.flat_map(checked, fn {rel, rx, what} ->
          case File.read(Path.expand(rel, root)) do
            {:ok, body} ->
              if Regex.match?(rx, code_of(body)), do: [], else: [{rel, what}]

            _ ->
              [{rel, "unreadable"}]
          end
        end)

      skipped_labels = skipped |> Enum.map(&elem(&1, 0)) |> Enum.uniq()

      if bad == [] do
        %{
          id: id,
          remediation: "—",
          status: :pass,
          evidence: checked |> Enum.map(&elem(&1, 0)) |> Enum.uniq(),
          note:
            "shipped=#{inspect(shipped)} installed=#{inspect(installed)} declared by Fleet.Layout " <>
              "and carried by the #{length(checked)} checked copies" <>
              skipped_note(skipped_labels)
        }
      else
        %{
          id: id,
          remediation: remediation,
          status: :fail,
          evidence: Enum.map(bad, &elem(&1, 0)),
          note:
            "authority says shipped=#{inspect(shipped)} installed=#{inspect(installed)} — " <>
              Enum.map_join(bad, " · ", fn {f, why} -> "#{f}: #{why}" end) <>
              skipped_note(skipped_labels)
        }
      end
    end
  end

  @doc """
  The secrets directory is DECLARED in five places and created in a sixth, and they must agree.

  ## No authority is designated, and that is deliberate

  Its four siblings in this section read ONE declaration and compare copies against it. This fact
  has no such declaration to read: it is named by `@default_dir` in `Fleet.Credentials.RoleToken`,
  by `PROV_TOKENS_DIR` in `provision-lib.sh`, by `LCARS_PRIVATE_DIR` in `deploy/accept`, and twice
  more inside the box entrypoint's file paths. **Nobody has said which one prevails**, and choosing
  here would be inventing an arbitration rather than checking one.

  The manifest cannot serve as the authority either, and the reason is worth writing down: its row
  is `dir <path> <mode> <owner> <rail>` — there is no NAME to ask. You cannot query it for "the
  secrets directory"; you can only confirm that a path you already know is created there. A creator
  is not a declaration.

  So this check states the weaker claim that is actually true: **whatever the authority turns out
  to be, the declarations agree, and the machine creates exactly the directory they name.** A
  designation can be added later and this check keeps holding; a designation invented today would
  be a decision no one made, written into a wall.

  ## What breaks without it

  `/home/private` is the most copied fact in the corpus. It holds the forge master token, the seed,
  the role tokens and the uid map, in `0710 lcars-authority:fleet`. A declaration that drifts from
  the created directory does not fail loudly: the daemon reads an empty directory and reports the
  credential as absent — the same output as a machine that was never provisioned.
  """
  @spec check_private_dir_single_source(String.t()) :: Support.result()
  def check_private_dir_single_source(root) do
    id = "layout.private_dir_single_source"

    remediation =
      "make every declaration of the secrets directory name the same path, and the manifest " <>
        "create exactly that path — no authority is designated, so agreement IS the invariant"

    # Chaque porteur : {fichier, regex de capture, ce qu'il est}. Le PERIMETRE se dit par fichier —
    # `lib/` part avec l'image, `deploy/` non.
    holders = [
      # Ancre de fin de ligne, meme raison que les trois voisins : une valeur composee doit rendre
      # la declaration ILLISIBLE, jamais un prefixe.
      {"lib/fleet/credentials/role_token.ex", ~r/@default_dir\s+"([^"]+)"\s*$/m,
       "the BEAM's role-token directory"},
      {"deploy/lib/provision-lib.sh", ~r/:\s*"\$\{PROV_TOKENS_DIR:=([^}]+)\}"/,
       "the provisioning default"},
      {"deploy/accept", ~r/PRIVATE_DIR="\$\{LCARS_PRIVATE_DIR:-([^}]+)\}"/,
       "the acceptance gate's default"},
      # ⚠ CES DEUX-LA GRAVENT LE REPERTOIRE DANS UN CHEMIN DE FICHIER au lieu de le composer depuis
      # une variable. C'est pour ca qu'ils comptent : ils ne suivraient AUCUN renommage, et rien
      # d'autre ne les regarde. Le repertoire se capture en retirant le dernier segment.
      {"deploy/docker/entrypoint.sh", ~r/LCARS_UID_MAP_FILE:-([^}]+)\/[^}\/]+\}/,
       "the box's uid-map path"},
      {"deploy/docker/entrypoint.sh", ~r/LCARS_MASTER_TOKEN_FILE:-([^}]+)\/[^}\/]+\}/,
       "the box's master-token path"}
    ]

    # ⚠ UNE DECLARATION DERIVEE EST UNE DECLARATION, PAS UN DESACCORD. Le shell nomme desormais sa
    # racine UNE fois (`PROV_ROOT`) et compose le reste ; comparer `$PROV_ROOT/var/tokens` au
    # litteral des quatre autres porteurs rendrait « 2 chemins pour un repertoire » sur un corpus
    # parfaitement d'accord — et la seule facon de faire taire ce faux rouge serait de RECOPIER le
    # littéral dans provision-lib, c'est-a-dire de reintroduire la copie que ce mur existe pour
    # interdire. Un mur qui punit la forme correcte pousse a la forme fausse.
    #
    # La resolution est DELIBEREMENT bornee aux defauts `: "${VAR:=valeur}"` de provision-lib, une
    # seule passe, sans recursion : ce n'est pas un interpreteur shell. Une variable qu'on ne sait
    # pas resoudre reste telle quelle et le desaccord se voit — c'est le comportement d'avant.
    prov_defauts =
      case File.read(Path.expand("deploy/lib/provision-lib.sh", root)) do
        {:ok, src} ->
          ~r/:\s*"\$\{([A-Z_][A-Z0-9_]*):=([^}"]*)\}"/
          |> Regex.scan(src)
          |> Map.new(fn [_, nom, val] -> {nom, val} end)

        _ ->
          %{}
      end

    resoudre = fn v ->
      Regex.replace(~r/\$\{?([A-Z_][A-Z0-9_]*)\}?/, v, fn entier, nom ->
        Map.get(prov_defauts, nom, entier)
      end)
    end

    read_holder = fn {rel, rx, what} ->
      case File.read(Path.expand(rel, root)) do
        {:ok, body} ->
          # Les deux corrections se composent et aucune ne suffit seule : `code_of/1` ecarte les
          # declarations qui ne vivent que dans un commentaire, `resoudre/1` rend sa valeur a une
          # declaration derivee. L'une repond a « ou lit-on ? », l'autre a « que vaut ce qu'on lit ? ».
          case Regex.run(rx, code_of(body)) do
            [_, v] -> {:ok, rel, what, resoudre.(v)}
            _ -> {:unreadable, rel, what}
          end

        _ ->
          {:absent, rel, what}
      end
    end

    {in_scope, out} =
      Enum.split_with(holders, fn {rel, _, _} ->
        tree_scope(Path.expand(hd(Path.split(rel)), root)) == :required
      end)

    results = Enum.map(in_scope, read_holder)
    values = for {:ok, rel, what, v} <- results, do: {rel, what, v}

    broken =
      for {:unreadable, rel, what} <- results, do: {rel, "#{what}: declaration not readable"}

    skipped = out |> Enum.map(&elem(&1, 0)) |> Enum.uniq()

    cond do
      # Moins de DEUX declarations lisibles : il n'y a pas d'accord a verifier. On le DIT, on ne
      # rend pas un vert muet — c'est la regle de tout ce fichier.
      length(values) < 2 and broken == [] ->
        out_of_scope(id, "fewer than two declarations present", skipped)

      broken != [] ->
        %{
          id: id,
          remediation: remediation,
          status: :fail,
          evidence: Enum.map(broken, &elem(&1, 0)),
          note:
            "a declaration no longer reads as a frozen literal — " <>
              Enum.map_join(broken, " · ", fn {f, why} -> "#{f}: #{why}" end) <>
              skipped_note(skipped)
        }

      true ->
        distinct = values |> Enum.map(fn {_, _, v} -> v end) |> Enum.uniq()
        [expected | _] = distinct

        manifest_rel = "deploy/system.manifest"
        manifest_scoped? = tree_scope(Path.expand("deploy", root)) == :required

        manifest_ok? =
          not manifest_scoped? or
            case File.read(Path.expand(manifest_rel, root)) do
              {:ok, m} -> Regex.match?(~r/^dir\s+#{Regex.escape(expected)}\s/m, m)
              _ -> false
            end

        cond do
          length(distinct) > 1 ->
            %{
              id: id,
              remediation: remediation,
              status: :fail,
              evidence: Enum.map(values, fn {rel, _, _} -> rel end),
              note:
                "#{length(distinct)} different paths declared for one directory — " <>
                  Enum.map_join(values, " · ", fn {f, what, v} -> "#{f} (#{what}): #{v}" end) <>
                  skipped_note(skipped)
            }

          not manifest_ok? ->
            %{
              id: id,
              remediation: remediation,
              status: :fail,
              evidence: [manifest_rel],
              note:
                "every declaration says #{inspect(expected)} but the manifest creates no such " <>
                  "directory — the box would come up without it" <> skipped_note(skipped)
            }

          true ->
            %{
              id: id,
              remediation: "—",
              status: :pass,
              evidence: values |> Enum.map(fn {rel, _, _} -> rel end) |> Enum.uniq(),
              note:
                "#{length(values)} declaration(s) agree on #{inspect(expected)}" <>
                  if(manifest_scoped?, do: ", and the manifest creates it", else: "") <>
                  skipped_note(skipped)
            }
        end
    end
  end

  @doc """
  The SYSTEM forge account is named ONCE, in `Fleet.Credentials.ForgeIdentity`, and copied ten
  times. This is what makes the ten agree.

  ## Why this account, and why an authority had to be designated

  `system_starfleet` is not a service among others. It is in the `Owners` team of the `fleet` org
  (it owns every project repo), its email is in `allowed_emails/2` of the commit-identity gate (a
  commit it signs passes the door), it is the default `forge_push_account`, and it sits in the
  `push_whitelist_usernames` of protected branches. It is also the writing hand of the `starfleet`
  role, which carries `forge_identity: false` in the canon precisely because every write of its own
  goes through this account.

  THREE INDEPENDENT DECLARATIONS EXISTED and none was designated: `@system_name` here,
  `PROV_SYSTEM_ACCOUNT` in `provision-lib.sh`, and — the sharpest — `variable "system_account"` in
  `forge.tf`, whose default is what actually CREATES the account and which nothing derives and
  nothing compared. `roles.provisioning_locked` holds `roles`/`system_roles`/`writers`/`judges`/
  `externals`; this name is in none of those lists, so the account that owns the org was created
  from a literal outside every lock.

  ⚖ user, 2026-08-27: the BEAM declaration prevails. The reason is structural, not a preference —
  the account's IDENTITY derives from this literal (`@system_email`, `allowed_emails/2`,
  `system_identity/0`) and cannot be moved without moving what the fleet signs as.

  ## Why the value is not plumbed through to tofu

  The obvious follow-up — emit `system_account` in `Fleet.Roster.tfvars/1` so tofu consumes it
  instead of holding a literal — would make `Fleet.Application` reference `Fleet.Credentials`,
  which is NOT in the root boundary's deps. That is an API change of a domain, a decision to be
  argued on its own, not a side effect of writing a wall. So this check does what
  `toolchain.branch_single_source` does for the branch name: one side DECLARES, the others copy,
  and the copies are verified. Fewer copies would be better; copies nobody compares are the defect.
  """
  @spec check_system_account_single_source(String.t()) :: Support.result()
  def check_system_account_single_source(root) do
    id = "forge.system_account_single_source"

    remediation =
      "copy the literal from `Fleet.Credentials.ForgeIdentity` `@system_name` — it is the " <>
        "designated authority (user, 2026-08-27): the account's email, its signature and the " <>
        "commit-identity gate all derive from it"

    expected =
      case File.read(Path.expand("lib/fleet/credentials/forge_identity.ex", root)) do
        {:ok, src} ->
          # Ancre de fin de ligne : voir la cicatrice du jumeau `toolchain.branch_single_source`.
          case Regex.run(~r/@system_name\s+"([^"]+)"\s*$/m, src) do
            [_, name] -> name
            _ -> nil
          end

        _ ->
          nil
      end

    if is_nil(expected) do
      unreadable_authority(
        id,
        remediation,
        "lib/fleet/credentials/forge_identity.ex",
        "@system_name"
      )
    else
      e = Regex.escape(expected)

      # Chaque miroir est ancre sur SON GESTE, pas sur la simple presence du nom : un commentaire,
      # une phrase de doc ou un nom de fichier voisin ne doivent pas pouvoir satisfaire ce mur.
      # `MUR 4 bis` d'`adminite_walls` a coute exactement cette lecon le meme jour — il etait
      # satisfait par `lcars-authority-ask`, puis par un commentaire.
      mirrors = [
        # ⚠ LE CREATEUR. Ce defaut est ce qui fait naitre le compte sur la forge, et rien ne
        # l'alimente : aucun `.tfvars` ne pose `system_account`. C'est le miroir qui compte le plus.
        # ⚠ CE MIROIR A CHANGE DE NATURE LE JOUR MEME OU IL A ETE ECRIT, et c'est un progres :
        # `forge.tf` ne porte plus le litteral, il RECOIT la valeur par `roles.auto.tfvars.json`,
        # projetee depuis l'autorite. Ce qui se garde ici n'est donc plus « la copie s'accorde »
        # mais « il n'y a PLUS de copie » — un `default =` reintroduit rendrait a tofu le pouvoir
        # de creer le compte sous un nom que personne n'a choisi, en silence, et c'est exactement
        # ce que la suppression a ferme.
        {"deploy/deps/forge.tf", ~r/variable\s+"system_account"\s*\{(?:(?!\}).)*?default\s*=/s,
         "carries a `default =` again — the name must arrive from roles.auto.tfvars.json, not from the recipe",
         :forbidden},
        {"deploy/lib/provision-lib.sh", ~r/:\s*"\$\{PROV_SYSTEM_ACCOUNT:=#{e}\}"/,
         "the provisioning default (its token file derives from it)"},
        {"deploy/deps/provision-forge-charte.sh", ~r/"#{e}:[A-Za-z0-9_.-]+"/,
         "the avatar map key"},
        {"services/human-converger.sh", ~r/LCARS_SYSTEM_ACCOUNT:-#{e}\}/,
         "the human converger's fallback"},
        {"services/forge-gestures.sh", ~r/PROV_SYSTEM_ACCOUNT:-#{e}\}/,
         "the forge gesture's fallback"},
        {"etc/provision-role-tokens.sh", ~r/LCARS_SYSTEM_ACCOUNT:-#{e}\}/,
         "the token minter's fallback"},
        {"deploy/admiral/skills/system-issues/list.sh", ~r/PROV_SYSTEM_ACCOUNT:-#{e}\}/,
         "the admiral skill's fallback"},
        {"bin/lcars", ~r/FORGE_BOT_LOGIN:-#{e}\}/, "the CLI's push-account fallback"},
        {"bin/publish-transform.sh", ~r/LCARS_SYSTEM_ACCOUNT:-#{e}\}@/,
         "the publish rewrite's system email"},
        {"config/runtime.exs", ~r/FORGE_BOT_LOGIN"\)\s*\|\|\s*"#{e}"/,
         "the runtime's push-account fallback"}
      ]

      {checked, skipped} =
        Enum.split_with(mirrors, fn m ->
          rel = elem(m, 0)
          tree_scope(Path.expand(hd(Path.split(rel)), root)) == :required
        end)

      bad =
        Enum.flat_map(checked, fn
          # Miroir INVERSE : ce qui est verifie est une ABSENCE. Un miroir qui doit porter le
          # litteral et un miroir qui ne doit plus rien porter sont deux formes du meme invariant —
          # « le nom vit a un seul endroit » — et le moteur les traite ensemble plutot que dans deux
          # boucles qui deriveraient.
          {rel, rx, what, :forbidden} ->
            case File.read(Path.expand(rel, root)) do
              {:ok, body} -> if Regex.match?(rx, code_of(body)), do: [{rel, what}], else: []
              _ -> [{rel, "unreadable"}]
            end

          {rel, rx, what} ->
            case File.read(Path.expand(rel, root)) do
              {:ok, body} -> if Regex.match?(rx, code_of(body)), do: [], else: [{rel, what}]
              _ -> [{rel, "unreadable"}]
            end
        end)

      skipped_labels = skipped |> Enum.map(&elem(&1, 0)) |> Enum.uniq()

      cond do
        checked == [] ->
          out_of_scope(id, "no copy present", skipped_labels)

        bad == [] ->
          %{
            id: id,
            remediation: "—",
            status: :pass,
            evidence: checked |> Enum.map(&elem(&1, 0)) |> Enum.uniq(),
            note:
              "#{inspect(expected)} declared by ForgeIdentity @system_name; #{length(checked)} " <>
                "sites checked (tofu RECEIVES it, it no longer copies it)" <>
                skipped_note(skipped_labels)
          }

        true ->
          %{
            id: id,
            remediation: remediation,
            status: :fail,
            evidence: Enum.map(bad, &elem(&1, 0)),
            note:
              "authority says #{inspect(expected)} — " <>
                Enum.map_join(bad, " · ", fn {f, why} -> "#{f}: #{why}" end) <>
                skipped_note(skipped_labels)
          }
      end
    end
  end

  @doc """
  The platform root is declared ONCE, in `Fleet.Layout`, and 121 literals in the corpus repeat it.
  This makes them agree.

  ## Why an allow-list of OTHER roots, and not a list of mirrors

  Its four siblings name their mirrors. Here the mirrors are 22 files and growing — a hand-kept
  list of that size is the defect, not the guard: it goes stale, and a stale list is a wall that
  is green about files it no longer holds. So the check is INVERTED. It does not ask "do these 22
  files carry the root"; it asks **"is there any OTHER LCARS-shaped root under `/opt`?"**

  `/opt` is not ours alone — the image also carries `/opt/homebrew`, `/opt/elixir-*`, `/opt/node-*`,
  `/opt/bin`, `/opt/skills`, `/opt/token-saver` and the vendor launcher. Those are DECLARED below,
  by name, each one a decision a reviewer can see — the same shape as
  `no_check_passes_on_nothing`'s exemption list, and for the same reason: matching on a pattern
  would let any new root earn its exemption by looking plausible.

  What this catches, and nothing else did: `@platform_root` moves, the 22 literals do not, and the
  set of roots in use no longer contains the authority's value. Measured 2026-08-28 as part of
  redoing §21 from a derived sweep — `/opt/lcars` is the single most copied fact of the corpus
  (121 occurrences, 22 files) and it had no lock at all.
  """
  @spec check_platform_root_single_source(String.t()) :: Support.result()
  def check_platform_root_single_source(root) do
    id = "layout.platform_root_single_source"

    remediation =
      "every `/opt/...` path of LCARS derives from `Fleet.Layout` `@platform_root` — a second " <>
        "root means half the box installs somewhere the other half never looks"

    # ⚠ CHAQUE ENTREE EST UNE DECISION ECRITE, PAS UN MOTIF. Ce sont les racines de `/opt` qui
    # n'appartiennent PAS a LCARS et vivent dans la meme image.
    etrangeres = [
      # la frontiere vendor N1 : le launcher de Claude, pose par le Dockerfile
      "/opt/claude_launch",
      # outillage du substrat, hors LCARS
      "/opt/homebrew",
      "/opt/bin",
      "/opt/skills",
      "/opt/my",
      "/opt/token-saver",
      # ⚠ DECOR DE TEMOIN, PAS UNE RACINE DE LA MACHINE. `deploy/tests/audit_machine.bats` fabrique
      # ces deux-la pour mesurer que l'audit ne laisse PAS un prefixe commun couvrir un objet voisin
      # (« /opt/decor couvrirait /opt/decor-autre »). Elles n'existent sur aucune image et ne sont
      # posees par aucun module ; les taire par un motif `^/opt/decor` masquerait aussi une vraie
      # racine qui s'appellerait ainsi un jour, donc elles sont nommees une par une, comme les autres.
      "/opt/decor",
      "/opt/decor-autre"
    ]

    expected =
      case File.read(Path.expand("lib/fleet/layout.ex", root)) do
        {:ok, src} ->
          case Regex.run(~r/@platform_root\s+"([^"]+)"\s*$/m, src) do
            [_, v] -> v
            _ -> nil
          end

        _ ->
          nil
      end

    if is_nil(expected) do
      unreadable_authority(id, remediation, "lib/fleet/layout.ex", "@platform_root")
    else
      # ⚠ LES VERSIONNEES SONT ECARTEES PAR LEUR FORME, PAS PAR LEUR NOM : `/opt/elixir-1.18.4` et
      # `/opt/node-20` portent leur version, donc les nommer serait une liste a maintenir a chaque
      # montee de version — exactement le genre d'entretien qu'on ne fait pas.
      # ⚠ ET LA FORME SE MESURE APRES TRONCATURE, pas avant — ma premiere ecriture l'ignorait et
      # rendait CINQ fausses accusations. `/opt/elixir-${ELIXIR_VERSION}` laisse `/opt/elixir-` dans
      # le code (la version est une expansion), et une ellipse de prose `/opt/lcars/...` laisse
      # `/opt/...`. Une racine qui se termine par `-` est donc une racine CONSTRUITE, et une racine
      # qui porte un point n'est pas une racine.
      # ⚠ delimiteur `{}` : le sigil `~r|…|` prend `|` pour sa borne, et l'alternance le coupe.
      versionnee = ~r{^/opt/\.?[a-z]+-([0-9]|$)}
      pas_une_racine = ~r|^/opt/\.?[a-z0-9][a-z0-9_-]*$|

      # ⚠ LE REJET PORTE SUR LE CHEMIN RELATIF, ET C'EST UNE CORRECTION, PAS UN GOUT. Applique au chemin
      # ABSOLU, ce motif rejetait TOUT le corpus des que le depot vivait sous un dossier nomme `tmp`,
      # `deps` ou `_build` — mesure le 2026-08-31 : 4328 fichiers vus, 0 retenus, depuis un worktree
      # pose sous `/tmp/`. Le check ne mentait pas pour autant (sa garde d'instrument rendait
      # « INSTRUMENT BROKEN — measured nothing » plutot qu'un vert creux), mais il ne mesurait rien,
      # et l'emplacement du clone n'a pas a decider de ce qu'un mur regarde.
      {racines, fichiers} =
        corpus_files(root)
        |> Enum.reduce({MapSet.new(), 0}, fn path, {acc, n} ->
          case File.read(path) do
            {:ok, body} ->
              vus =
                body
                |> String.split("\n")
                |> Enum.map(&Regex.replace(~r/#.*/, &1, ""))
                |> Enum.flat_map(&Regex.scan(~r|/opt/\.?[A-Za-z0-9_.-]+|, &1))
                |> Enum.map(&hd/1)
                |> Enum.map(&Regex.replace(~r|(/opt/\.?[A-Za-z0-9_-]+).*|, &1, "\\1"))
                |> MapSet.new()

              {MapSet.union(acc, vus), if(MapSet.size(vus) > 0, do: n + 1, else: n)}

            _ ->
              {acc, n}
          end
        end)

      inconnues =
        racines
        |> Enum.reject(&(&1 == expected))
        |> Enum.reject(&(&1 in etrangeres))
        |> Enum.reject(&Regex.match?(versionnee, &1))
        |> Enum.reject(&(not Regex.match?(pas_une_racine, &1)))
        |> Enum.sort()

      cond do
        # Garde d'instrument : l'autorite DOIT figurer parmi les racines vues. Si elle n'y est pas,
        # le balayage n'a pas lu le corpus — et un ensemble vide n'accuse personne.
        not MapSet.member?(racines, expected) ->
          broken_result(id, "occurrence of #{expected} in the corpus")

        inconnues == [] ->
          %{
            id: id,
            remediation: "—",
            status: :pass,
            evidence: [],
            note:
              "#{inspect(expected)} declared by Fleet.Layout @platform_root is the ONLY LCARS root " <>
                "under /opt (#{fichiers} files carry a /opt path; #{length(etrangeres)} foreign " <>
                "roots declared, versioned toolchains excluded by shape)"
          }

        true ->
          %{
            id: id,
            remediation: remediation,
            status: :fail,
            evidence: inconnues,
            note:
              "authority says #{inspect(expected)} — #{length(inconnues)} other root(s) under " <>
                "/opt are neither the authority nor declared foreign: " <>
                Enum.join(inconnues, ", ")
          }
      end
    end
  end

  @doc """
  The runtime state root is declared ONCE, in `Fleet.Layout`, and fourteen literals repeat it.

  `/run/lcars` carries the sockets of the authority, the privileged executor, MCP, egress and the
  consoles — the whole surface by which a pod talks to the rest of the machine — plus the boot
  markers (`/run/lcars-provision.rc`, `/run/lcars-humans.rc`) and the converger's refusal lock.
  The derived sweep of 2026-08-28 ranked it SECOND of the corpus, with no source at all. The
  authority (`@runtime_root`) was created that day; this check is what makes it true.

  ## Two shapes, one rule

  The tree (`/run/lcars/...`) and its flat siblings (`/run/lcars-provision.rc`) are both LCARS
  runtime state, and both begin with the authority's value as a STRING. So one rule covers both:
  every `/run` path that names LCARS must start with `@runtime_root`.

  ## Where the value is derived, and where it cannot be

  `Fleet.Spawner` has `Fleet.Layout` in its boundary deps, so `Pod.Egress` DERIVES its default and
  its literal is gone. `Fleet.MCP` does NOT have Layout in its deps: `PodSocketSupervisor` keeps a
  literal, because deriving it would widen a domain's API — a decision to argue on its own, not a
  side effect of writing a wall. The shell and the manifest cannot call the BEAM at all. What this
  check buys is that all of them AGREE, and the ones that can derive, do.
  """
  @spec check_runtime_root_single_source(String.t()) :: Support.result()
  def check_runtime_root_single_source(root) do
    id = "layout.runtime_root_single_source"

    remediation =
      "every `/run` path of LCARS starts with `Fleet.Layout` `@runtime_root` — a second runtime " <>
        "root means a socket written where nobody listens, on a tmpfs that forgets between boots"

    expected =
      case File.read(Path.expand("lib/fleet/layout.ex", root)) do
        {:ok, src} ->
          case Regex.run(~r/@runtime_root\s+"([^"]+)"\s*$/m, src) do
            [_, v] -> v
            _ -> nil
          end

        _ ->
          nil
      end

    if is_nil(expected) do
      unreadable_authority(id, remediation, "lib/fleet/layout.ex", "@runtime_root")
    else
      {vus, porteurs} =
        corpus_files(root)
        |> Enum.reduce({MapSet.new(), 0}, fn path, {acc, n} ->
          case File.read(path) do
            {:ok, body} ->
              # ⚠ ON NE RETIENT QUE CE QUI NOMME LCARS. `/run/user`, `/run/systemd`, `/run/sshd`
              # appartiennent au systeme : les compter ferait accuser la machine hote.
              vus =
                body
                |> String.split("\n")
                |> Enum.map(&Regex.replace(~r/#.*/, &1, ""))
                |> Enum.flat_map(&Regex.scan(~r|/run/[A-Za-z0-9_.-]*lcars[A-Za-z0-9_.-]*|, &1))
                |> Enum.map(&hd/1)
                |> MapSet.new()

              {MapSet.union(acc, vus), if(MapSet.size(vus) > 0, do: n + 1, else: n)}

            _ ->
              {acc, n}
          end
        end)

      # ⚠ UN PREFIXE N'EST PAS UNE APPARTENANCE, ET LA MUTATION L'A MONTRE. `String.starts_with?`
      # seul laisse passer `/run/lcarsx/...` : il commence bien par `/run/lcars`. C'est la TROISIEME
      # coincidence de sous-chaine de la journee — `MUR 4 bis` etait satisfait par
      # `lcars-authority-ask`, un nom de binaire. Le prefixe doit etre suivi d'une FRONTIERE : `/`
      # pour l'arbre, `-` ou `.` pour les fichiers freres (`/run/lcars-provision.rc`), ou la fin.
      sous_la_racine? = fn v ->
        String.starts_with?(v, expected) and
          (byte_size(v) == byte_size(expected) or
             String.at(v, byte_size(expected)) in ["/", "-", "."])
      end

      orphelins = vus |> Enum.reject(sous_la_racine?) |> Enum.sort()

      cond do
        # Garde d'instrument : sans une seule occurrence de l'autorite, le balayage n'a rien lu et
        # un ensemble vide n'accuse personne.
        not Enum.any?(vus, sous_la_racine?) ->
          broken_result(id, "occurrence of #{expected} in the corpus")

        orphelins == [] ->
          %{
            id: id,
            remediation: "—",
            status: :pass,
            evidence: [],
            note:
              "every LCARS path under /run starts with #{inspect(expected)}, declared by " <>
                "Fleet.Layout @runtime_root (#{MapSet.size(vus)} distinct ROOTS — the scan stops " <>
                "at the first `/`, so `/run/lcars/authority/roles.sock` counts as `/run/lcars` — " <>
                "across #{porteurs} files)"
          }

        true ->
          %{
            id: id,
            remediation: remediation,
            status: :fail,
            evidence: orphelins,
            note:
              "authority says #{inspect(expected)} — #{length(orphelins)} LCARS path(s) under " <>
                "/run do not start with it: " <> Enum.join(orphelins, ", ")
          }
      end
    end
  end

  @doc """
  The three project faces are declared ONCE, in `Fleet.Layout`, and this makes every `/home/projects`
  root in the corpus agree with them.

  `face_root/1` names three faces — `code`, `workshop`, `ops` — and RAISES on a fourth, so the
  BEAM side cannot invent one. The shell, the Dockerfile and the manifest have no such door: they
  write the paths as literals, twenty-nine times across the corpus. This check is what stops a
  fourth root appearing there without passing through the declaration.

  ⚠ ITS SIBLING `layout.face_roots_provisioned` CHECKS A DIFFERENT THING and the two are not
  redundant: that one asks whether the machine CREATES the faces the code declares; this one asks
  whether the corpus NAMES any root the code does not declare. Creation and agreement fail apart —
  a face can be created under a name nobody reads, and a name can be read that nothing creates.

  ## The one non-face tree, declared by name

  `/home/projects.work` is the agents' work tree — six carriers, all under `.claude/hooks/`. It is
  not a project face and has no business being derived from one; naming it here is the decision,
  visible to a reviewer, rather than a pattern that would let any future `/home/projects.*` pass.
  """
  @spec check_face_roots_single_source(String.t()) :: Support.result()
  def check_face_roots_single_source(root) do
    id = "layout.face_roots_single_source"

    remediation =
      "every `/home/projects*` root is a face declared by `Fleet.Layout.face_root/1` — a root the " <>
        "declaration does not know is a tree the runtime will never look at"

    src =
      case File.read(Path.expand("lib/fleet/layout.ex", root)) do
        {:ok, s} -> s
        _ -> nil
      end

    # Les faces se lisent par leurs CLAUSES, pas par une liste : `face_root("code"), do: @code_root`
    # dit a la fois le nom de la face et l'attribut qui porte sa racine.
    faces =
      if src do
        ~r/def face_root\("([a-z]+)"\), do: @([a-z_]+)/
        |> Regex.scan(src)
        |> Enum.map(fn [_, face, attr] ->
          case Regex.run(~r/@#{attr}\s+"([^"]+)"\s*$/m, src) do
            [_, v] -> {face, v}
            _ -> {face, nil}
          end
        end)
      else
        []
      end

    racines = faces |> Enum.map(&elem(&1, 1)) |> Enum.reject(&is_nil/1)

    # ⚠ DECLARE PAR SON NOM, pas par un motif : l'arbre de travail des agents.
    hors_face = ["/home/projects.work"]

    cond do
      length(faces) < 3 or Enum.any?(faces, fn {_, v} -> is_nil(v) end) ->
        %{
          id: id,
          remediation: remediation,
          status: :fail,
          evidence: ["lib/fleet/layout.ex"],
          note:
            "the faces no longer read as frozen literals in Fleet.Layout " <>
              "(#{length(faces)} clause(s) found, #{length(racines)} with a readable root) — " <>
              "nothing was compared"
        }

      true ->
        # `..` : ce check porte sur le depot ENTIER, pas sur `fleet/` seul. Le filtre residuel
        # ne garde que ce que `@corpus_skip` ne couvre pas — et il porte sur le chemin relatif a
        # la base REELLE du scan, pas a `root`, sans quoi tout ce qui vit hors de `fleet/` y
        # echappe.
        base = Path.expand(Path.join(root, ".."))

        vues =
          corpus_files(base)
          |> Enum.reject(
            &String.match?("/" <> Path.relative_to(&1, base), ~r"/(\.expert|tests?)/")
          )
          |> Enum.reduce(MapSet.new(), fn path, acc ->
            case File.read(path) do
              {:ok, body} ->
                if String.contains?(body, <<0>>) do
                  acc
                else
                  body
                  |> String.split("\n")
                  |> Enum.map(&Regex.replace(~r/#.*/, &1, ""))
                  |> Enum.flat_map(&Regex.scan(~r|/home/projects[A-Za-z0-9_.-]*|, &1))
                  |> Enum.map(&hd/1)
                  # ⚠ LE POINT FINAL D'UNE PHRASE N'EST PAS UNE RACINE. « … sous /home/projects. »
                  # rendait `/home/projects.`, une quatrieme face inexistante. Deuxieme fois qu'une
                  # ponctuation pollue un extracteur aujourd'hui — `/opt/...` etait la premiere.
                  |> Enum.map(&Regex.replace(~r/[.\-]+$/, &1, ""))
                  |> MapSet.new()
                  |> MapSet.union(acc)
                end

              _ ->
                acc
            end
          end)

        inconnues =
          vues
          |> Enum.reject(&(&1 in racines or &1 in hors_face))
          |> Enum.sort()

        cond do
          not Enum.all?(racines, &MapSet.member?(vues, &1)) ->
            broken_result(id, "occurrence of every declared face root in the corpus")

          inconnues == [] ->
            %{
              id: id,
              remediation: "—",
              status: :pass,
              evidence: [],
              note:
                "the #{length(racines)} faces declared by Fleet.Layout.face_root/1 " <>
                  "(#{Enum.join(racines, ", ")}) are the only /home/projects roots in the corpus, " <>
                  "plus #{length(hors_face)} declared non-face tree"
            }

          true ->
            %{
              id: id,
              remediation: remediation,
              status: :fail,
              evidence: inconnues,
              note:
                "Fleet.Layout declares #{Enum.join(racines, ", ")} — " <>
                  "#{length(inconnues)} other /home/projects root(s) are neither a face nor " <>
                  "declared: " <> Enum.join(inconnues, ", ")
            }
        end
    end
  end

  @doc """
  The ops repository is named by `Fleet.Toolchain.ops_repo/0` and copied by the two services that
  reach it without the BEAM. This makes the copies agree.

  ⚠ ITS TWIN `toolchain.branch_single_source` LOCKS THE BRANCH OF THE SAME REPOSITORY AND NOT THE
  REPOSITORY. The pair `<org>/<repo>` and the branch name are two halves of one address: the
  converger refuses any SHA that is not the head of `<repo>@<branch>`, and the root executor asks
  the forge for that head. Locking one half and not the other leaves the address half-guarded —
  the exact shape §22 found for the branch itself, one field over.

  `services/forge-gestures.sh` and `services/privileged-executor.py` carry the literal because they
  run as CHILD processes of modules and cannot call the BEAM: measured, `provision-lib` exports
  nothing and `deploy/provision` exports only its CLI flags. Their fallback is their only source —
  it is not removed, it is held equal.
  """
  @spec check_ops_repo_single_source(String.t()) :: Support.result()
  def check_ops_repo_single_source(root) do
    id = "toolchain.ops_repo_single_source"

    remediation =
      "copy the literal from `Fleet.Toolchain.ops_repo/0` — the repository and its branch are two " <>
        "halves of one address, and the branch is already locked"

    expected =
      case File.read(Path.expand("lib/fleet/toolchain.ex", root)) do
        {:ok, src} ->
          case Regex.run(
                 ~r/def ops_repo, do: Application\.get_env\([^,]+,\s*[^,]+,\s*"([^"]+)"\)/,
                 src
               ) do
            [_, v] -> v
            _ -> nil
          end

        _ ->
          nil
      end

    if is_nil(expected) do
      unreadable_authority(
        id,
        remediation,
        "lib/fleet/toolchain.ex",
        "Fleet.Toolchain.ops_repo/0",
        "default"
      )
    else
      e = Regex.escape(expected)

      mirrors = [
        {"services/forge-gestures.sh", ~r/LCARS_OPS_REPO:-#{e}\}/,
         "the forge gesture's ops-repo fallback"},
        {"services/privileged-executor.py", ~r/os\.environ\.get\("LCARS_OPS_REPO",\s*"#{e}"\)/,
         "the root executor's ops-repo fallback"}
      ]

      {checked, skipped} =
        Enum.split_with(mirrors, fn {rel, _, _} ->
          tree_scope(Path.expand(hd(Path.split(rel)), root)) == :required
        end)

      bad =
        Enum.flat_map(checked, fn {rel, rx, what} ->
          case File.read(Path.expand(rel, root)) do
            {:ok, body} -> if Regex.match?(rx, code_of(body)), do: [], else: [{rel, what}]
            _ -> [{rel, "unreadable"}]
          end
        end)

      labels = skipped |> Enum.map(&elem(&1, 0)) |> Enum.uniq()

      cond do
        checked == [] ->
          out_of_scope(id, "no copy present", labels)

        bad == [] ->
          %{
            id: id,
            remediation: "—",
            status: :pass,
            evidence: Enum.map(checked, &elem(&1, 0)),
            note:
              "#{inspect(expected)} declared by Fleet.Toolchain.ops_repo/0 and copied by the " <>
                "#{length(checked)} services that cannot call the BEAM" <> skipped_note(labels)
          }

        true ->
          %{
            id: id,
            remediation: remediation,
            status: :fail,
            evidence: Enum.map(bad, &elem(&1, 0)),
            note:
              "authority says #{inspect(expected)} — " <>
                Enum.map_join(bad, " · ", fn {f, why} -> "#{f}: #{why}" end) <>
                skipped_note(labels)
          }
      end
    end
  end

  # UNE CLEF DE CONFIGURATION, UN SEUL REPLI — le pendant intra-BEAM des verrous ci-dessus.
  #
  # Les huit murs de ce module gardent un fait recopie D'UN LANGAGE A L'AUTRE, parce que le shell ne
  # peut pas appeler le BEAM. Entre deux modules Elixir, rien ne regardait : on suppose qu'ils
  # s'appellent. Mesure du 2026-09-02 : DEUX clefs etaient lues a deux endroits avec deux replis
  # ecrits separement.
  #
  #   · `:mcp_pod_resolver`  — `Delegation.default_pod_resolver/1` et `Probe.default_resolver/1`,
  #     corps identiques au nom pres, alors que le commentaire de `Probe` exigeait DEJA le contraire :
  #     « deux resolveurs de la meme identite de canal donneraient deux avis » ;
  #   · `:mcp_forge_client`  — `@default_writer` et `@default_client`, tous deux `Fleet.Forge.Client`.
  #
  # ⚠ CE QUI REND CE DEFAUT PARTICULIEREMENT SOURNOIS : UN REPLI NE S'EXERCE QUE QUAND LA CLEF EST
  # ABSENTE. En test, elle est presque toujours posee — le seam existe pour ca. Les deux replis ne
  # divergent donc QU'EN PRODUCTION, sur le chemin que personne ne joue.
  #
  # Le mur compare les expressions de repli, pas leur valeur : deux ecritures differentes du meme
  # module resteraient deux ecritures a maintenir. Une lecture SANS repli (`get_env/2`) ne compte
  # pas — elle ne declare rien, elle accepte `nil`.
  @doc false
  @spec check_config_single_default(String.t()) :: Support.result()
  def check_config_single_default(root) do
    lectures =
      root
      |> Path.join("lib/**/*.ex")
      |> Path.wildcard()
      |> Enum.flat_map(fn path ->
        rel = Path.relative_to(path, root)

        path
        |> File.read!()
        |> Code.string_to_quoted!()
        |> collect(fn
          {{:., _, [{:__aliases__, _, [:Application]}, verbe]}, _, [_app, cle, defaut]}
          when verbe in [:get_env, :compile_env] and is_atom(cle) ->
            {cle, Macro.to_string(defaut), rel}

          _ ->
            nil
        end)
      end)

    divergentes =
      lectures
      |> Enum.group_by(&elem(&1, 0))
      |> Enum.filter(fn {_cle, v} ->
        v |> Enum.map(&elem(&1, 1)) |> Enum.uniq() |> length() > 1
      end)
      |> Enum.sort()

    if measured_nothing?(lectures) do
      broken_result("config.single_default", "Application.get_env/3 call under lib/")
    else
      %{
        id: "config.single_default",
        remediation:
          "une clef de configuration porte UN repli — que le module qui declare le contrat le " <>
            "porte, et que les autres l'appellent (cf. `Delegation.ForgeClient.resolved/0`). Deux " <>
            "replis pour une clef ne divergent qu'en l'absence de configuration, donc jamais en " <>
            "test et toujours en production",
        status: if(divergentes == [], do: :pass, else: :fail),
        evidence:
          Enum.map(divergentes, fn {cle, v} ->
            "#{inspect(cle)} : " <>
              (v
               |> Enum.map(fn {_c, d, rel} -> "#{rel} -> #{d}" end)
               |> Enum.uniq()
               |> Enum.join(" · "))
          end),
        note:
          "#{length(lectures)} lecture(s) avec repli sur " <>
            "#{lectures |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> length()} clef(s) distincte(s)"
      }
    end
  end

  # UNE AUTORITE ILLISIBLE N'EST PAS « RIEN A COMPARER » — c'est le seul cas ou chaque copie
  # passerait par DEFAUT, donc le seul ou un verrou vert serait un mensonge complet. Cinq des huit
  # verrous rendent ce verdict, et ils recopiaient la meme phrase cinq fois : une situation, une
  # phrase, et le fail-closed enonce a un seul endroit.
  @spec unreadable_authority(String.t(), String.t(), String.t(), String.t(), String.t()) ::
          Support.result()
  defp unreadable_authority(id, remediation, source, autorite, forme \\ "literal") do
    %{
      id: id,
      remediation: remediation,
      status: :fail,
      evidence: [source],
      note:
        "`#{autorite}` no longer reads as a frozen #{forme} — the authority is unreadable, so " <>
          "nothing was compared"
    }
  end

  # « RIEN A VERIFIER ICI » N'EST PAS UN VERT ORDINAIRE : c'est un `pass` qui DIT qu'il n'a rien
  # mesure, et dont la note NOMME ce qu'il n'a pas vu — la seule forme de vert que ce depot accepte
  # sur une population absente.
  #
  # ⚠ QUATRE VERROUS LE RENDAIENT, AVEC TROIS FORMULATIONS POUR UNE SEULE SITUATION. Trois
  # contournaient de surcroit l'assemblage de la liste, chacun avec son propre `Enum.join`. Une
  # situation, une phrase : le SUJET reste une donnee (un arbre miroir, une copie, deux
  # declarations), la phrase ne se recopie plus.
  @spec out_of_scope(String.t(), String.t(), [String.t()]) :: Support.result()
  defp out_of_scope(id, sujet, absents) do
    %{
      id: id,
      remediation: "—",
      status: :pass,
      evidence: [],
      note:
        "NOT CHECKED here — #{sujet} in this artifact (runtime-only context)" <>
          if(absents == [], do: "", else: ": " <> Enum.join(absents, ", "))
    }
  end
end
