defmodule Fleet.Spawner.Pod.SessionMint do
  @moduledoc """
  MINT du `session_id` d'un pod au spawn — décision extraite de `Fleet.Spawner.Pod`.

  Décide QUEL session_id un pod reçoit à sa création : déterministe hexspeak pour un rôle
  catalogué (encodé par `Fleet.Spawner.SessionId.encode/4`, l'encodeur PUR), `UUID.uuid4()` pour un
  rôle non catalogué, REFUS (raise) pour un rôle project-bound sans `repo_id`. La séparation des
  autorités est volontaire : `SessionId` déclare « aucun refus de rôle : ces décisions vivent au
  niveau spawn, pas ici » — la décision vit donc ICI (côté spawn), l'arithmétique de la string
  reste là-bas. La SOURCE du QUOI (index de rôle, tier protégé, fleet-level) est le cap-profile.

  Quasi-pur : aucune I/O, aucun state, aucun timer — seule la branche « rôle non catalogué » tire
  de l'aléa (`UUID.uuid4()`). Aucune dépendance vers `Fleet.Spawner.Pod` (pas de cycle).

  ## Contrat (appelé par `Pod`)

  - `mint/2` — appelé par `initial_state` (via `recover_or_init`) quand `opts[:session_id]` (seed
    explicite, ex. recall arch) n'est pas fourni — le seed PRIME toujours sur le mint.
  """

  @doc """
  Minte le session_id d'un pod depuis son cap-profile + les opts du spawn.

    * rôle NON catalogué — `UUID.uuid4()` est légitime.
    * fleet-level (arch, gatekeeper) — repo `0000`, pas de dimension projet.
    * project-bound (eng, juges) — l'identité hexspeak EXIGE le repo (`opts[:repo_id]`).
        - AVEC repo → id déterministe (`Fleet.Spawner.SessionId.encode/4`).
        - SANS repo → REFUS (raise `ArgumentError`) : l'absence de repo signale une forge qui n'a
          pas résolu l'id (forge down). On ne fabrique JAMAIS un UUID random pour masquer ça
          (fausse identité, non reconstructible). Le raise est rattrapé par le try/rescue de
          `Pod.init/1` → `{:error, {exception, stack}}` au `start_link` (fail-loud, aucun launch) ;
          le filet de dernier recours (stop propre) vit en amont, au dispatch.
  """
  @spec mint(Fleet.CapProfile.t(), keyword()) :: String.t()
  def mint(%Fleet.CapProfile{} = cap_profile, opts) when is_list(opts) do
    repo = Keyword.get(opts, :repo_id)

    cond do
      not Fleet.CapProfile.catalogued?(cap_profile) ->
        UUID.uuid4()

      Fleet.CapProfile.fleet_level?(cap_profile) ->
        Fleet.Spawner.SessionId.encode(
          Fleet.CapProfile.role_index(cap_profile),
          Fleet.CapProfile.protected?(cap_profile),
          0x0000
        )

      is_integer(repo) ->
        Fleet.Spawner.SessionId.encode(
          Fleet.CapProfile.role_index(cap_profile),
          Fleet.CapProfile.protected?(cap_profile),
          repo
        )

      true ->
        raise ArgumentError,
              "SessionMint.mint: rôle project-bound #{Fleet.CapProfile.name(cap_profile)} " <>
                "sans repo_id — la forge n'a pas résolu l'id (forge down ?). " <>
                "On ne fabrique pas d'UUID random."
    end
  end
end
