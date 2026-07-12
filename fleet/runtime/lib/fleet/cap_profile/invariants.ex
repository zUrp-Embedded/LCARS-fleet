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

  The error-atom vocabulary (`:g24_1`, `:g24_3`, … `:g24_14`) is **FROZEN**:
  the tests AND `mix lcars.contracts.check` match these exact codes — do NOT
  rename them (they are a wire contract, not a comment).

  ## Excluded from `validate/1` (documented at their sites below)

    * Removed checks — the invariant itself no longer holds: `g24_2`
      (apiVersion), `g24_5` (git_ops_denied), `g24_7` (budget). See the inline
      notes for why each was dropped.
    * `g24_13` (mcp_channels non-empty ⟹ `Fleet.MCP.Server` alive) — a runtime
      **liveness** check, hence impure/non-deterministic; it violates the "pure
      data transformer" contract and is a spawn-time concern, not a static
      invariant. Enforced at the spawn boundary (the validated world), not here.
    * The **I/O parts** of otherwise-pure checks: `g24_14`'s FS existence of
      the monk registry + `monk_instance` lookup is load-time (`compose/2`);
      only its pure both-or-neither structural part is checked here.

  Single dependency direction (no cycle): this module depends on the
  `%Fleet.CapProfile{}` struct (compile-dep); `Fleet.CapProfile.validate/1`
  calls `violations/1` (runtime-dep).
  """

  alias Fleet.CapProfile

  @kind_pinned "CapabilityProfile"

  # g24_9 — deny Anthropic's native server-tools: they run server-side, NOT inside the pod → the bwrap
  # sandbox does not contain them by construction.
  # LOUP-FLAG (sanctuary vs sandbox pass): the framing "the sandbox does not contain them" is
  # containment-flavored; the constructive framing is "these run outside the pod's sanctuary, which
  # grants only what runs inside it". Reframe deferred to the coordinated sanctuary-vocabulary pass —
  # the mechanism (structural deny) is already sanctuary-aligned; only the wording drifts.
  # Strict entries = equality, prefix entries = `String.starts_with?/2`.
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
    # No apiVersion check (the former g24_2): the apiVersion field does not exist.
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
      {:g24_14, &check_monk_registry_pairing/1}
    ]
    |> Enum.reject(fn {_code, fun} -> fun.(profile) == :ok end)
    |> Enum.map(fn {code, _fun} -> code end)
  end

  @doc """
  Closed enum of `spec.invocation.lifetime_scope` (`g24_4`). This list is DUPLICATED in `priv/cap_profile/schema/cap-profile-v2.5.json` ... — a
  physical dedup is impossible (JSON schema can't reference Elixir), so a drift test locks the two copies
  (R0-CAP-011). Exposed as the code-side SSoT that test reads.
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

  # No `git_ops_denied` check (the former g24_5): workers MAY push if the
  # cap-profile allows it via the claude CLI `allowedTools`. The invariant that
  # required `"push"` in `git_ops_denied` would therefore be obsolete. The
  # generic catalogue → claude CLI disallowedTools mechanism (via
  # `with_resolved_disallowed_tools/1` + baseline `_baseline-git-denied.yaml`)
  # is the successor: it universally forbids the destructive patterns
  # (`push --force`, `reset --hard`, `--no-verify`, etc.) without forbidding
  # `push` wholesale.

  defp check_modop_incompatible(%CapProfile{spec: spec}) do
    # `modop_set` is a MAP (schema v2.5: default/optional/incompatible), not a
    # list. The incompatible pairs are under `spec.modop_set.incompatible`; the
    # ACTIVE modops = `default` ++ `optional`. Do NOT read `spec.modop_incompatible`
    # (missing key → always []) nor treat `spec.modop_set` as a list, otherwise the
    # invariant never fires.
    modop_set = Map.get(spec, "modop_set", %{})

    # Canon modop_set = a MAP (default/optional/incompatible). A legacy/empty profile may carry it as a
    # LIST (`[]`) → `Map.get` would crash (BadMapError). We treat the non-map form as "no incompatible
    # pair declared" → no conflict, no crash at the spawn boundary (the wrong type is made harmless, not
    # caught by a rescue).
    {pairs, active} =
      if is_map(modop_set) do
        {Map.get(modop_set, "incompatible", []),
         MapSet.new(Map.get(modop_set, "default", []) ++ Map.get(modop_set, "optional", []))}
      else
        {[], MapSet.new()}
      end

    conflict? =
      Enum.any?(pairs, fn pair ->
        case pair do
          [a, b] -> MapSet.member?(active, a) and MapSet.member?(active, b)
          _ -> false
        end
      end)

    if conflict?, do: :error, else: :ok
  end

  # No budget check (the former g24_7): no API = no budget. The response
  # timeout (once mis-named budget.maxDurationSec) is now a default keyed by
  # lifetime_scope in `Fleet.Spawner.Pod.monitor_timeout_ms/1`; a per-cap-profile
  # override (e.g. `spec.timeouts.response_sec`) is accepted as optional but not
  # required.

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
end
