defmodule Fleet.PodRuntime.StreamParser do
  @moduledoc """
  Parser NDJSON stateful pour le stdout claude -p (PoC-1 PROVEN).

  Pure functions stateful — pas de process, state passée
  explicitement (`%__MODULE__{}` struct). Cohérent skill
  `elixir:elixir-thinking` (no process without runtime reason).

  ## Finding F1 PoC-1

  La frame `init` peut être reçue **plusieurs fois** intra-session
  sans qu'il s'agisse d'un reboot. Distinction via `session_id` :

    * `init` 1ère fois → `session_id` capturé, `init_count = 1`
    * `init` Nème fois avec **même** `session_id` → normal, increment
    * `init` avec `session_id` différent → reboot anormal, état
      remis à zéro avec nouveau `session_id` (caller décide d'émettre
      warning)

  ## F-INIT-VALIDATE 9 champs

  `validate_init/1` vérifie la présence des 9 champs critiques de la
  frame `init` (consultant SDK 100%). Délégué de `Fleet.Spawner.Pod`
  phase MONITOR (chantier 6 PROMOTED a sa propre `InitValidator`
  équivalente — duplication assumée pour découplage chantier-à-chantier).

  ## Champ struct `events` — placeholder

  Le champ `events: []` est conservé conformément au contrat design
  note L106-107 mais **n'est pas alimenté** par `parse_chunk/2` :
  l'accumulateur d'events décodés est retourné directement dans le
  tuple `{:ok, events, state}`. Le caller maintient l'historique s'il
  en a besoin. Champ réservé pour une future accumulation cross-turn
  intra-pod si requis (sinon candidat à suppression chantier ultérieur).
  """

  defstruct session_id: nil, init_count: 0, buffer: "", events: []

  @type t :: %__MODULE__{
          session_id: nil | String.t(),
          init_count: non_neg_integer(),
          buffer: binary(),
          events: [map()]
        }

  @required_init_keys ~w(tools model permission_mode api_key_source cwd claude_code_version mcp_servers slash_commands agents)a

  @doc """
  Initialise un parser vierge.
  """
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Parse un chunk binaire arbitraire (peut couper une ligne au milieu).

  Returns `{:ok, events_décodés, new_state}`. Les lignes incomplètes
  restent dans `state.buffer` jusqu'au prochain `parse_chunk/2`.

  Les lignes JSON invalides sont silencieusement ignorées (log via
  caller s'il le souhaite — pure function pas d'effet de bord).
  """
  @spec parse_chunk(t(), binary()) :: {:ok, [map()], t()}
  def parse_chunk(%__MODULE__{} = state, chunk) when is_binary(chunk) do
    full = state.buffer <> chunk
    {complete_lines, residual} = split_lines(full)

    {events_rev, state2} =
      Enum.reduce(complete_lines, {[], state}, fn line, {acc_events, acc_state} ->
        case decode_line(line) do
          {:ok, event} ->
            {[event | acc_events], track_event(acc_state, event)}

          :skip ->
            {acc_events, acc_state}
        end
      end)

    {:ok, Enum.reverse(events_rev), %{state2 | buffer: residual}}
  end

  @doc """
  Valide une frame `init` selon F-INIT-VALIDATE (9 champs).

  Returns `:ok` ou `{:error, missing_fields :: [atom()]}`.

  Vérifie aussi `api_key_source == "oauth"` (G24 invariant). Champ
  manquant ou valeur ≠ `oauth` → `:api_key_source` dans missing.
  """
  @spec validate_init(map()) :: :ok | {:error, [atom()]}
  def validate_init(init_event) when is_map(init_event) do
    missing =
      Enum.reduce(@required_init_keys, [], fn key, acc ->
        case Map.fetch(init_event, Atom.to_string(key)) do
          {:ok, value} ->
            if key == :api_key_source and value != "oauth", do: [key | acc], else: acc

          :error ->
            [key | acc]
        end
      end)

    case missing do
      [] -> :ok
      list -> {:error, Enum.reverse(list)}
    end
  end

  defp split_lines(buffer) do
    case String.split(buffer, "\n") do
      [single] ->
        {[], single}

      parts ->
        {complete, [residual]} = Enum.split(parts, length(parts) - 1)
        complete = Enum.reject(complete, &(&1 == ""))
        {complete, residual}
    end
  end

  defp decode_line(line) do
    case Jason.decode(line) do
      {:ok, event} when is_map(event) -> {:ok, event}
      _ -> :skip
    end
  end

  defp track_event(state, %{"type" => "init", "session_id" => session_id})
       when is_binary(session_id) do
    cond do
      state.session_id == nil ->
        %{state | session_id: session_id, init_count: 1}

      state.session_id == session_id ->
        %{state | init_count: state.init_count + 1}

      true ->
        %{state | session_id: session_id, init_count: 1}
    end
  end

  defp track_event(state, _other), do: state
end
