defmodule Fleet.CapProfile.Invariants do
  @moduledoc """
  The **pure** G24 business invariants of a composed `%Fleet.CapProfile{}`
  (cap-profile canon v2.5 + containment gate).

  Pure validation cluster extracted from `Fleet.CapProfile`: one function per
  check, aggregated by `violations/1`. Pure — no process read, no FS read
  (same struct ⇒ same verdict), zero I/O. `Fleet.CapProfile.validate/1`
  DELEGATES here: it wraps `violations/1` in its return contract
  (`:ok | {:error, [atom()]}`) and is the single public entry point.

  This module is the SINGLE SOURCE for the per-code catalogue: what each
  `:g24_*` enforces lives on its check function below; `validate/1` points here
  rather than restating it.

  The error-atom vocabulary is **FROZEN**: the tests AND `mix lcars.contracts.check`
  match these exact codes — do NOT rename them (they are a wire contract, not a
  comment). The registry in `violations/1` is the list; naming an upper bound here
  would be a second copy that goes stale the next time one is added, which is
  exactly what happened to the `… :g24_14` this sentence used to end on.

  ## Excluded from `validate/1` (documented at their sites below)

    * The numbering GAPS in the registry (`g24_2`, `g24_5`, `g24_7`) are deliberate:
      those invariants no longer exist, and their codes stay retired — never reused
      (frozen wire vocab). A one-line note sits at each gap's position below.
    * `g24_13` RETIRED with its `mcp_channels` field: the field was a phantom control —
      no production code ever read it (the real tool surface is `scope.allowedTools`,
      filtered by `mcp_fleet_tools/1`, plus the MCP handler gates). A schema field that
      LOOKS like a mechanical barrier while nothing enforces it hands the catalogue
      author a false assurance — removed rather than wired (no consumer ever needed it).
    * The **I/O parts** of otherwise-pure checks: `g24_14`'s FS existence of
      the monk registry + `monk_instance` lookup is load-time (`compose/2`);
      only its pure both-or-neither structural part is checked here.

  Single dependency direction (no cycle): this module depends on the
  `%Fleet.CapProfile{}` struct (compile-dep); `Fleet.CapProfile.validate/1`
  calls `violations/1` (runtime-dep).
  """

  alias Fleet.CapProfile

  @kind_pinned "CapabilityProfile"

  # g24_9 — deny Anthropic's native server-tools: they run SERVER-SIDE, outside the pod → outside the
  # pod's SANCTUARY. The sanctuary grants the agent ONLY what runs INSIDE it (constructive framing:
  # "what is not projected does not exist"), so these server-side tools — which escape the projection —
  # are denied by construction. Not "the sandbox does not contain them" (containment framing): "they live
  # outside the world we project FOR the agent".
  # Strict entries = equality, prefix entries = `String.starts_with?/2`.
  #
  # DECLARED then VALIDATED, not copied — the distinction matters when reading the catalogue. Every
  # canon cap-profile repeats these entries in its own `spec.scope.disallowedTools`, and this list is
  # what MAKES that repetition safe rather than duplicated: `check_disallowed_strict/1` requires each
  # profile to contain every strict entry, so a profile that drops one FAILS validation. The seven
  # lists cannot drift apart, and reading any single cap-profile shows what its pod is denied.
  #
  # Do not confuse this with the OTHER mechanism on the same field: the git denials are INJECTED at
  # resolve time (`CapProfile.DisallowedTools.with_resolved/1`, from `baseline/git-denied.yaml`) and
  # appear in no cap-profile. Same key, two mechanisms — one declared and checked here, one injected
  # and absent from the source. Adding the server-tools minimum to the injection instead would make the
  # catalogue stop stating its own denials.
  @disallowed_minimum_strict ~w(web_search web_fetch code_execution bash_code_execution text_editor_code_execution)
  @disallowed_minimum_prefix ~w(tool_search_)

  @containment_enum ~w(bwrap none)
  @lifetime_scope_enum ~w(one-shot pipe run forever)

  @doc """
  The list of G24 invariant codes VIOLATED by the composed profile (`[]` = all
  pass). Stable order = the declaration order of the registry below.
  Pure: same struct ⇒ same list.

  `Fleet.CapProfile.validate/1` is the sole consumer; it translates `[]` into
  `:ok` and a non-empty list into `{:error, list}`.
  """
  @spec violations(CapProfile.t()) :: [atom()]
  def violations(%CapProfile{} = profile) do
    # g24_2 retired: no apiVersion field exists (schema versioning is carried by the code).
    [
      {:g24_1, &check_containment/1},
      {:g24_3, &check_kind/1},
      {:g24_4, &check_lifetime_scope/1},
      {:g24_6, &check_modop_incompatible/1},
      {:g24_8, &check_metadata_name/1},
      {:g24_9_strict, &check_disallowed_strict/1},
      {:g24_9_prefix, &check_disallowed_prefix/1},
      {:g24_10, &check_boot_at_start_forever/1},
      {:g24_11, &check_subagent_template_one_shot/1},
      {:g24_12, &check_host_native_containment/1},
      {:g24_14, &check_monk_registry_pairing/1},
      {:g24_15, &check_slot_scope_declared/1},
      {:g24_16, &check_remote_control_declared/1},
      {:g24_17, &check_human_facing_visible/1}
    ]
    |> Enum.reject(fn {_code, fun} -> fun.(profile) == :ok end)
    |> Enum.map(fn {code, _fun} -> code end)
  end

  @doc """
  Closed enum of `spec.invocation.lifetime_scope` (`g24_4`). This list is DUPLICATED in
  `priv/cap_profile/schema/cap-profile-v2.5.json` — a physical dedup is impossible (a JSON
  schema cannot reference Elixir), so a drift test locks the two copies
  (`cap_profile_v25_conformance_test.exs`). Exposed as the code-side copy that test reads.
  """
  @spec lifetime_scope_enum() :: [String.t()]
  def lifetime_scope_enum, do: @lifetime_scope_enum

  # ============================================================
  # G24 invariants (one function per check)
  # ============================================================

  defp check_containment(%CapProfile{metadata: meta}) do
    if Map.get(meta, "containment") in @containment_enum, do: :ok, else: :error
  end

  defp check_kind(%CapProfile{kind: k}) do
    if k == @kind_pinned, do: :ok, else: :error
  end

  defp check_lifetime_scope(%CapProfile{spec: spec}) do
    # Canon: lifetime_scope is nested under `spec.invocation` (schema
    # cap-profile-v2.5.json + canon cap-profiles), not at the `spec` level —
    # reading `spec.lifetime_scope` directly would miss the value.
    if get_in(spec, ["invocation", "lifetime_scope"]) in @lifetime_scope_enum,
      do: :ok,
      else: :error
  end

  # g24_5 retired: workers MAY push when their cap-profile allows it. The successor is the
  # disallowedTools mechanism (`with_resolved_disallowed_tools/1` + `baseline/git-denied.yaml`):
  # the destructive patterns (`push --force`, `reset --hard`, `--no-verify`, …) are universally
  # denied without forbidding `push` wholesale.

  defp check_modop_incompatible(%CapProfile{spec: spec} = profile) do
    # `modop_set` is a MAP (schema v2.5: default/optional/incompatible), not a list; the
    # incompatible pairs live under `spec.modop_set.incompatible`. The ACTIVE set is
    # `CapProfile.active_modops/1` — the resolve decision (role defaults ++ the step's
    # validated extras), falling back to the declared defaults for a profile that never
    # went through resolve. Do NOT widen this to `default ++ optional`: an
    # available-but-unactivated option is not active, and two mutually exclusive
    # OPTIONALS are a coherent catalogue shape — B-01 already refuses their real
    # co-activation at resolve; this invariant re-checks the SAME definition of active
    # at the spawn boundary, never a broader one.
    modop_set = Map.get(spec, "modop_set", %{})

    # Canon modop_set = a MAP. A legacy/empty profile may carry it as a LIST (`[]`) →
    # `Map.get` would crash (BadMapError). The non-map form reads as "no incompatible
    # pair declared" — made harmless by construction, not caught by a rescue.
    pairs = if is_map(modop_set), do: Map.get(modop_set, "incompatible", []), else: []
    active = MapSet.new(Fleet.CapProfile.active_modops(profile))

    conflict? =
      Enum.any?(pairs, fn pair ->
        case pair do
          [a, b] -> MapSet.member?(active, a) and MapSet.member?(active, b)
          _ -> false
        end
      end)

    if conflict?, do: :error, else: :ok
  end

  # g24_7 retired: no API = no budget to enforce. The response timeout is a default keyed by
  # lifetime_scope in `Fleet.Spawner.Pod.Liveness.monitor_timeout_ms/1`; a per-cap-profile
  # override (`spec.timeouts.response_sec`) is optional, never required.

  defp check_metadata_name(%CapProfile{metadata: meta}) do
    case Map.get(meta, "name") do
      name when is_binary(name) and byte_size(name) > 0 -> :ok
      _ -> :error
    end
  end

  defp check_disallowed_strict(%CapProfile{spec: spec}) do
    disallowed = get_in(spec, ["scope", "disallowedTools"]) || []
    if Enum.all?(@disallowed_minimum_strict, &(&1 in disallowed)), do: :ok, else: :error
  end

  defp check_disallowed_prefix(%CapProfile{spec: spec}) do
    disallowed = get_in(spec, ["scope", "disallowedTools"]) || []

    prefix_ok =
      Enum.all?(@disallowed_minimum_prefix, fn prefix ->
        Enum.any?(disallowed, &String.starts_with?(&1, prefix))
      end)

    if prefix_ok, do: :ok, else: :error
  end

  # ------------------------------------------------------------
  # G24-10..14 — v2.5 extensions
  #
  # STRING keys/values: the struct is deeply stringified (`to_struct`). The
  # compared values are therefore strings, not atoms (`"forever"`, `"one-shot"`
  # with a hyphen, `"none"`) — comparing to an atom `:forever` would always miss.
  # ------------------------------------------------------------

  # G24-10: boot_at_start: true ⟹ lifetime_scope: forever.
  # Doubles the JSON-schema `allOf` (belt-and-suspenders, with a verbose error atom).
  defp check_boot_at_start_forever(%CapProfile{spec: spec}) do
    if get_in(spec, ["invocation", "boot_at_start"]) == true and
         get_in(spec, ["invocation", "lifetime_scope"]) != "forever" do
      :error
    else
      :ok
    end
  end

  # G24-11: non-empty subagent_template ⟹ lifetime_scope: one-shot.
  # `subagent_template` (invocation) implies a one-shot dispatch; distinct from
  # `knowledge.sp_template` (the SP template of a permanent monk/archivist pod)
  # which is NOT constrained here. nil or "" = no template → no constraint
  # (consistent with the schema's `minLength: 1`).
  defp check_subagent_template_one_shot(%CapProfile{spec: spec}) do
    template = get_in(spec, ["invocation", "subagent_template"])
    scope = get_in(spec, ["invocation", "lifetime_scope"])

    if is_binary(template) and template != "" and scope != "one-shot" do
      :error
    else
      :ok
    end
  end

  # G24-12: host_native: true ⟹ metadata.containment: none.
  # `containment` lives in `metadata` (not `spec`). No `system_user` clause:
  # that field does not exist in schema v2.5. G24-12 real = `containment: none`
  # alone, aligned with the JSON `allOf`.
  defp check_host_native_containment(%CapProfile{spec: spec, metadata: meta}) do
    if get_in(spec, ["invocation", "host_native"]) == true and
         Map.get(meta, "containment") != "none" do
      :error
    else
      :ok
    end
  end

  # G24-14: monk_registry ⟺ monk_instance pairing (both-or-neither).
  # The PURE, structural part (not carried by the JSON-schema, which declares
  # both independently nullable). The registry's FS existence + the
  # `monk_instance` lookup are I/O ⟹ load-time (`compose/2`), not here.
  defp check_monk_registry_pairing(%CapProfile{spec: spec}) do
    # A BLANK/whitespace string counts as ABSENT, like nil: `monk_registry: ""` is not a real pairing.
    # The former `is_nil`-only test let `{"x", ""}` pass (both non-nil) — a half-declared, broken pairing.
    registry? = monk_present?(get_in(spec, ["knowledge", "monk_registry"]))
    instance? = monk_present?(get_in(spec, ["knowledge", "monk_instance"]))

    if registry? == instance?, do: :ok, else: :error
  end

  defp monk_present?(v), do: is_binary(v) and String.trim(v) != ""

  # g24_15 — a role that is NOT one-shot must DECLARE its `slot_scope`.
  #
  # `slot_scope` derives from `lifetime_scope` when absent, and that derivation is a tautology on
  # one side and a CHOICE on the other. `one-shot ⟹ instance` has nothing to choose: a one-shot
  # keyed by project would be one pod per repo dying after a single use, and the next dispatch
  # would land on a dead id. But `context-long ⟹ project` is a decision — the one that was taken
  # in silence for a year, and that made "long-lived AND one per ticket" inexpressible while being
  # exactly what a producer needs.
  #
  # So the declaration is required exactly where the derivation LIES, and nowhere else. Not a
  # schema `required`: that would refuse the one-shot judges, which are right to say nothing. A
  # named refusal at load, on the half that carries a choice.
  defp check_slot_scope_declared(%CapProfile{spec: spec}) do
    if get_in(spec, ["invocation", "lifetime_scope"]) == "one-shot" or
         get_in(spec, ["invocation", "slot_scope"]) in ~w(instance project),
       do: :ok,
       else: :error
  end

  # g24_16 — a PROJECT-keyed role must DECLARE its `remote_control`.
  #
  # Same shape, same reason, one axis over. An instance-keyed pod is ephemeral by construction, so
  # "no durable Desktop handle" has nothing to choose. A project-keyed pod has a stable identity,
  # so whether it deserves a handle IS a decision — and leaving it to a default meant "visible
  # unless someone remembered to say otherwise", which was harmless while producers were one per
  # repo and became Desktop pollution the day they fanned out per ticket.
  defp check_remote_control_declared(%CapProfile{spec: spec} = profile) do
    if CapProfile.slot_scope(profile) != "project" or
         is_boolean(get_in(spec, ["invocation", "remote_control"])),
       do: :ok,
       else: :error
  end

  # g24_17 — a role with a HUMAN in front of it must be REACHABLE by that human.
  #
  # `interlocutor` says who the REPL converses with; `remote_control` says whether there is a door
  # to that REPL. `both`/`human` with no door is not a restriction, it is a CONTRADICTION: the
  # profile provisions the human protocol addendum (`SeeU`, handoff, the whole interactive
  # contract) into a terminal nobody can open. The pod would sit there holding a conversation
  # contract with no counterpart, and the fleet would report it healthy.
  #
  # Checked on the EFFECTIVE answer, not on the declared field: since the visibility derivation, an
  # instance-keyed `both` role that declares nothing derives to invisible, which is the same
  # contradiction reached by silence rather than by statement. `g24_16` covers the project-keyed
  # side by forcing a declaration; this one covers what the declaration then says.
  #
  # The debug widening is deliberately NOT consulted: it is a fleet-lifetime mode, and an invariant
  # that a runtime flag can satisfy is not an invariant. A profile must be coherent as written.
  defp check_human_facing_visible(%CapProfile{} = profile) do
    if CapProfile.interlocutor(profile) in ~w(both human) and
         not CapProfile.remote_control?(profile),
       do: :error,
       else: :ok
  end
end
