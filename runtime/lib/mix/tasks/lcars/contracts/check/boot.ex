defmodule Mix.Tasks.Lcars.Contracts.Check.Boot do
  # Z4 — classe dans la boundary de son sujet, comme la tache qui l'utilise.
  use Boundary, classify_to: Fleet.Application

  @moduledoc """
  Le verrou de topologie : l'ORDRE du demarrage.

  `boundary` tient la DIRECTION des dependances a la compilation — chaque domaine declare ses `deps`
  et le compilateur refuse les violations, ce qu'aucun grep n'egalera. Ce que `boundary` ne voit pas,
  et que ces trois murs verrouillent, c'est l'ordre dans lequel les enfants demarrent : il est porte
  par une LISTE, pas par un type, et le reordonner casse le boot SANS erreur de compilation.

  ⚠ D'OU L'ABSENCE DE MUR SUR LE GRAPHE DE DEPENDANCES ICI : il existe deja, il est dans le
  compilateur. Ajouter un grep qui refait moins bien ce que `boundary` fait mieux donnerait deux
  reponses a une question, et la moins fiable serait la plus lisible.
  """

  # Pas d'`import Support` : ces trois murs lisent l'ORDRE d'une liste dans une source, ils ne
  # grepent pas un marqueur. Seul le type du verdict est partage.
  alias Mix.Tasks.Lcars.Contracts.Check.Support

  # ── Topology lock ──────────────────────────────────────────────
  # Z3 (D-19) — there is NO `layering.dependency_graph` check here: dependency DIRECTION
  # is enforced by boundary (Z4) — each domain declares its deps in `use Boundary` and the
  # COMPILER refuses violations, stronger than any grep. What boundary CANNOT see, and what
  # this check locks, is the BOOT invariant: the children order of Fleet.Application is the
  # SOLE carrier of F8 (event_router first; mcp before spawner — no admiral-domain constraint,
  # cf. A-08 comment in the function) — reordering it breaks the boot WITHOUT a compile
  # error. Hence the honest check id: `boot.order_f8`.
  @doc false
  @spec check_boot_order_f8(String.t()) :: Support.result()
  def check_boot_order_f8(root) do
    app_src = File.read!(Path.join(root, "lib/fleet/application.ex"))

    # A-08: there is NO `mcp < admiral` / `spawner < admiral` constraint — their only
    # would-be cause (a mid-boot admiral-domain child spawning the permanents) does not exist:
    # the BootOrchestrator is a root-level POST-boot trigger. What holds: event_router
    # FIRST (the Bus is every subscriber's substrate) and mcp BEFORE spawner (spawner's
    # PublishConsumer can receive an admin.spawn.request as soon as it subscribes →
    # ensure_pod_socket requires the mcp substrate alive).
    with [block] <- Regex.run(~r/children = \[(.*?)\n    \]/s, app_src, capture: :all_but_first),
         positions = %{
           er: :binary.match(block, "Fleet.EventRouter.Application"),
           mcp: :binary.match(block, "Fleet.MCP.Supervisor"),
           spw: :binary.match(block, "Fleet.Spawner.Application")
         },
         false <- Enum.any?(positions, fn {_, m} -> m == :nomatch end) do
      %{er: {er, _}, mcp: {mcp, _}, spw: {spw, _}} = positions
      # er = MIN of the three (the Bus boots before any potential consumer) — NOT er==0:
      # the children block starts with a COMMENT, the module offset is never 0.
      ok? = er < mcp and mcp < spw

      %{
        id: "boot.order_f8",
        remediation:
          "reorder the children of Fleet.Application: event_router FIRST, " <>
            "mcp BEFORE spawner (F8 scar in the moduledoc; no admiral-domain " <>
            "constraint per A-08 — BootOrchestrator is triggered post-boot by the root)",
        status: if(ok?, do: :pass, else: :fail),
        evidence: [
          "children order (offsets in the block): event_router=#{er} mcp=#{mcp} " <>
            "spawner=#{spw} — constraints: er<mcp, mcp<spw"
        ],
        note: "boot-order lock (the deps DIRECTION is enforced by boundary at compile time, Z4)"
      }
    else
      _ ->
        %{
          id: "boot.order_f8",
          remediation:
            "children of Fleet.Application not found (`children = [...]` block or an " <>
              "expected domain supervisor missing) — restore the list + F8 scar",
          status: :fail,
          evidence: ["children block extraction impossible — fail-closed"],
          note: "cf. Z3 (D-19) comment above"
        }
    end
  end

  # Jumeau du precedent, et meme raison d'exister : un ORDRE dans `start/2` que le compilateur ne
  # voit pas. `application.ex` l'ecrit noir sur blanc — *« the images below FREEZE their snapshot
  # from this disk, and a snapshot taken from an unchecked root would carry the fault forward under
  # a proven-good name »*. Une phrase de doctrine que rien ne tient est une phrase qui sera vraie
  # jusqu'au premier refactor : ce check est ce qui la tient.
  #
  # Verrouille sur la SOURCE, comme F8, parce que le mode de panne n'est pas reproductible en test :
  # il demande un catalogue invalide ET des images publiees, c'est-a-dire exactement le boot qu'un
  # test hermetique ne joue pas.
  @doc false
  @spec check_catalogue_before_freeze(String.t()) :: Support.result()
  def check_catalogue_before_freeze(root) do
    app_src = File.read!(Path.join(root, "lib/fleet/application.ex"))

    positions = %{
      verify: :binary.match(app_src, "Fleet.Catalogue.verify!()"),
      cap: :binary.match(app_src, "Fleet.CapProfile.publish_image!()"),
      sp: :binary.match(app_src, "Fleet.SPBuilder.publish_image!()")
    }

    if Enum.any?(positions, fn {_, m} -> m == :nomatch end) do
      %{
        id: "boot.catalogue_before_freeze",
        remediation:
          "restore in Fleet.Application.start/2: Catalogue.verify!() BEFORE " <>
            "CapProfile.publish_image!() and SPBuilder.publish_image!()",
        status: :fail,
        evidence: ["one of verify!/publish_image! not found in application.ex — fail-closed"],
        note: "boot-order lock, twin of boot.order_f8"
      }
    else
      %{verify: {v, _}, cap: {c, _}, sp: {sp, _}} = positions

      %{
        id: "boot.catalogue_before_freeze",
        remediation:
          "move Catalogue.verify!() ABOVE both publish_image! calls: an image frozen from " <>
            "an unchecked catalogue root carries the fault forward under a proven-good name",
        status: if(v < c and v < sp, do: :pass, else: :fail),
        evidence: ["offsets in application.ex: verify=#{v} cap_profile=#{c} sp_builder=#{sp}"],
        note: "boot-order lock, twin of boot.order_f8"
      }
    end
  end

  # THIRD OF THE BOOT-ORDER FAMILY, and the one whose subject is a DEFAULT rather than a call.
  # `Bus.assert_authorized!/1` permits every event while the registry is empty
  # (`@permit_empty_default true`). That default is not laxity: it holds the window between the
  # first line of boot and the moment `Catalog.load!/0` populates the registry, and `load!/0` RAISES
  # on an absent, invalid or empty `events.yaml` — so a fleet that reaches its first broadcast has a
  # loaded registry, always.
  #
  # THE GUARANTEE LIVES IN ANOTHER MODULE AT ANOTHER MOMENT, and nothing held it. `Catalog.load!/0`
  # sits in `EventRouter.Application.init/1` above the children list by convention alone; moving it
  # one line down, or into a child's `init`, widens the permissive window to the whole boot without
  # a single test going red — the failure needs an unregistered event AND a real supervision tree,
  # which the hermetic suite does not play (`event_router_load_event_registry: false` in test.exs).
  #
  # MEASURED, because the register's fiche asks for the opposite and the number decides: flipping
  # `@permit_empty_default` to `false` yields **101 failures out of 2698**. The permissive default
  # is load-bearing. What was missing was never the fail-closed posture — it was this lock.
  @doc false
  @spec check_event_registry_loaded_before_children(String.t()) :: Support.result()
  def check_event_registry_loaded_before_children(root) do
    rel = "lib/fleet/event_router/application.ex"
    src = File.read!(Path.join(root, rel))

    positions = %{
      load: :binary.match(src, "Fleet.EventRouter.Catalog.load!()"),
      children: :binary.match(src, "children =")
    }

    remediation =
      "keep `Fleet.EventRouter.Catalog.load!()` ABOVE the children list in " <>
        "EventRouter.Application.init/1: it is what closes the window that " <>
        "`Bus.@permit_empty_default true` deliberately leaves open, and it raises on an absent, " <>
        "invalid or empty events.yaml"

    if Enum.any?(positions, fn {_, m} -> m == :nomatch end) do
      %{
        id: "boot.event_registry_before_children",
        remediation: remediation,
        status: :fail,
        evidence: ["#{rel}: `Catalog.load!()` or the children list not found — fail-closed"],
        note: "boot-order lock, third of the family (F8, catalogue_before_freeze)"
      }
    else
      %{load: {l, _}, children: {c, _}} = positions

      %{
        id: "boot.event_registry_before_children",
        remediation: remediation,
        status: if(l < c, do: :pass, else: :fail),
        evidence: ["offsets in #{rel}: Catalog.load!=#{l} children=#{c}"],
        note:
          "the permissive empty-registry default is safe only while this call precedes every " <>
            "process that can broadcast"
      }
    end
  end
end
