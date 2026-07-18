defmodule Fleet.Credentials.PlanValidator do
  @moduledoc """
  Plan/subscription gate: the human's claudeDir must carry a paid
  subscription in order to run claude_code pods. Reads
  `claudeAiOauth.subscriptionType` from the native `.credentials.json` — NO SDK, no
  network call (pure transformer, same contract as `Fleet.Credentials.ScopeValidator`).

  ## Canonical values

  Values emitted by the claude binary in `.credentials.json`:
  `subscriptionType: "max" | "pro" | "team" | "enterprise" | null`. `null`/absent =
  no subscription → refusal. Any known paid value → `:ok` (case-insensitive).

  ## Defense in depth

  The claude binary ALREADY enforces the plan (401/login). This gate fails the spawn
  EARLY (fail-fast at the boundary) rather than at the pod's 1st API call: a clear refusal
  runtime-side instead of a spawned pod that will die on its first unauthorized API call.

  ## Exit codes

    * `:ok` — recognized paid subscription
    * `{:error, {:invalid_plan, type}}` — non-paid/unknown plan (type kept for reporting)

  **Last revised**: 2026-07-18
  """

  # Recognized paid plans (source: Claude Code). MUST stay all-lowercase: `validate/1` downcases the
  # input before the membership test, so a capitalized entry here would never match. The absence/`null`
  # case is handled by the caller (the slot may be missing) — here we only validate a binary value that
  # is present.
  @paid_plans ~w(max pro team enterprise)

  @spec validate(term()) :: :ok | {:error, {:invalid_plan, term()}}
  def validate(subscription_type) when is_binary(subscription_type) do
    if String.downcase(subscription_type) in @paid_plans,
      do: :ok,
      else: {:error, {:invalid_plan, subscription_type}}
  end

  # Total (R1-37): a non-binary plan (absent slot, `null`, a malformed value) is a REFUSAL, not a
  # FunctionClauseError. The @doc notes the caller pre-handles absence, but the validator stands total on
  # its own — no non-paid input reaches a spawn.
  def validate(other), do: {:error, {:invalid_plan, other}}
end
