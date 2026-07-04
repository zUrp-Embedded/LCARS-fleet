defmodule Fleet.SchemaCache do
  @moduledoc """
  Autorité unique du pattern « artefact chargé une fois, caché en `:persistent_term` »
  (schemas JSON résolus, configs boot-time).

  Dédup B-R2 : le pipeline `File.read! |> Jason.decode! |> ExJsonSchema.Schema.resolve`
  + cache `:persistent_term` vivait copié dans `fleet_workflow` (Loader),
  `fleet_starfleet` (Gatekeeper) et `fleet_coord` (Policies — qui, lui, relisait et
  re-résolvait le fichier schema à CHAQUE validation, sans cache). Une seule
  implémentation ici, Ring 0 : workflow/starfleet/coord dépendent déjà de
  `fleet_event_router`, zéro nouvelle arête dans `priv/allowed_graph.yaml`.

  ## Pourquoi `:persistent_term` (et pas ETS / un GenServer)

  Ces artefacts sont lus à CHAQUE validation (hot path) et écrits UNE fois au boot
  ou au premier accès : exactement le profil `:persistent_term` — lecture sans copie
  ni verrou, depuis n'importe quel process, sans process porteur (Iron Law : pas de
  process sans raison runtime). La contrepartie est le coût d'écriture : chaque `put`
  déclenche un scan du heap de TOUS les process (GC global). JAMAIS de `put`
  par-tick / par-requête à travers ce module — un artefact, une écriture.

  ## Contrat de clé

  La clé `:persistent_term` est l'IDENTITÉ du cache : deux paths différents sous la
  même clé = la même entrée (le premier chargé gagne). Si le path peut varier dans la
  vie du BEAM (override de test via Application env), mets le path RÉSOLU DANS la clé
  (ex. `{__MODULE__, :schema, path}`) — chaque variante a son entrée, pas de pollution
  prod↔test. Une clé fixe (ex. `{Gatekeeper, :decision_schema}`) sert aux artefacts
  chargés une fois au boot et relus par `fetch!/2` (qui ne connaît pas le path).

  ## Note Ring 0 (cap_profile)

  `fleet_cap_profile` (Ring 0 lui aussi, SANS dep vers `fleet_event_router`) garde
  deux copies locales du squelette `cached/2` (`CapProfile.Schema.load_schema_file/1`,
  `CapProfile.DisallowedTools.load_baseline_git_ops_denied!/0`) : on n'ajoute pas une
  arête intra-R0 pour dix lignes. Si l'arête apparaît un jour pour une autre raison,
  migrer ces deux sites.
  """

  # Sentinelle de miss namespacée : `nil` ou `:miss` nus seraient des VALEURS
  # cachables légitimes (le fun de `cached/2` peut retourner n'importe quoi).
  @miss {__MODULE__, :miss}

  @doc """
  Read + decode + resolve d'un JSON-schema, caché en `:persistent_term` sous
  `persistent_key`. Idempotent : un hit ne relit PAS le fichier (les schemas priv
  sont immuables dans la vie du BEAM). Fail-loud si le fichier est absent
  (`File.Error`), malformé (`Jason.DecodeError`) ou non-résolvable
  (`ExJsonSchema` raise) — un schema cassé est un artefact de deploy cassé, le
  boot doit crasher, jamais log-and-continue.
  """
  @spec resolve_json_schema!(term(), Path.t()) :: ExJsonSchema.Schema.Root.t()
  def resolve_json_schema!(persistent_key, path) do
    cached(persistent_key, fn ->
      path |> File.read!() |> Jason.decode!() |> ExJsonSchema.Schema.resolve()
    end)
  end

  @doc """
  Get-or-raise : lit la valeur cachée sous `persistent_key`, raise `ArgumentError`
  si rien n'a été chargé. `boot_loader` (optionnel) nomme la fonction d'init à
  appeler au boot (ex. `"Fleet.Coord.Policies.init_policies!/0"`) pour un message
  d'erreur actionnable.
  """
  @spec fetch!(term(), String.t() | nil) :: term()
  def fetch!(persistent_key, boot_loader \\ nil) do
    case :persistent_term.get(persistent_key, @miss) do
      @miss ->
        hint = boot_loader || "la fonction d'init boot-time de l'app propriétaire"

        raise ArgumentError,
              "Fleet.SchemaCache: clé #{inspect(persistent_key)} pas chargée — " <>
                "appeler #{hint} au boot"

      value ->
        value
    end
  end

  @doc """
  Cache lazy générique : retourne la valeur cachée sous `persistent_key`, sinon
  exécute `fun`, cache son résultat et le retourne. Si `fun` raise, RIEN n'est
  caché — le prochain appel retente (erreurs non-cachées).

  Piège assumé : si `fun` retourne un tuple `{:error, _}` (au lieu de raise),
  ce tuple EST caché comme n'importe quelle valeur. Pour un chargement dont
  l'échec doit rester retentable, faire raise (cf. `resolve_json_schema!/2`)
  ou gérer le cache à la main (cf. `Fleet.CapProfile.Schema`).
  """
  @spec cached(term(), (-> term())) :: term()
  def cached(persistent_key, fun) when is_function(fun, 0) do
    case :persistent_term.get(persistent_key, @miss) do
      @miss ->
        value = fun.()
        :persistent_term.put(persistent_key, value)
        value

      value ->
        value
    end
  end
end
