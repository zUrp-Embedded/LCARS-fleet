defmodule Fleet.SchemaCache do
  use Boundary, deps: [], exports: []

  @moduledoc """
  Shared load-once cache for resolved schemas and boot-time artifacts.

  Values live in `:persistent_term`: reads are frequent and writes must remain
  boot-time or first-access operations. The key is the cache identity, so callers
  include a variable resolved path in the key when variants can coexist.
  """

  @miss {__MODULE__, :miss}

  @doc """
  Reads, decodes, resolves and caches a JSON schema under `persistent_key`.

  Cache hits do not read the file. Artifact and schema errors raise.
  """
  @spec resolve_json_schema!(term(), Path.t()) :: ExJsonSchema.Schema.Root.t()
  def resolve_json_schema!(persistent_key, path) do
    cached(persistent_key, fn ->
      path |> File.read!() |> Jason.decode!() |> ExJsonSchema.Schema.resolve()
    end)
  end

  @doc """
  Fetches a cached value or raises. `boot_loader` is included in the miss
  message when supplied.
  """
  @spec fetch!(term(), String.t() | nil) :: term()
  def fetch!(persistent_key, boot_loader \\ nil) do
    case :persistent_term.get(persistent_key, @miss) do
      @miss ->
        hint = boot_loader || "the owning app's boot-time init function"

        raise ArgumentError,
              "Fleet.SchemaCache: key #{inspect(persistent_key)} not loaded — " <>
                "call #{hint} at boot"

      value ->
        value
    end
  end

  @doc """
  Returns a cached value or computes and stores it with `fun`.

  Raised failures are not cached; returned error tuples are ordinary values and
  are cached.

  THAT ASYMMETRY IS THE CHOICE CRITERION, so read it before reaching for this function: a soft
  `{:error, _}` returned by `fun` is frozen for the BEAM's lifetime. A caller whose failure must
  stay RETRYABLE — a schema that may be absent now and present after a redeploy — belongs outside
  this function and must manage its own `:persistent_term` entry, storing the success only.
  `Fleet.CapProfile.Schema` is that case and says so at its own cache.

  ⚠ `fun` PEUT ETRE EVALUEE PLUSIEURS FOIS pour une meme cle absente, et c'est un choix (6-002).
  Deux processus qui manquent ensemble calculent tous les deux ; un seul ECRIT et tous rendent LE
  MEME terme (cf. la relecture dans le corps). N'evaluer qu'une fois demanderait un verrou tenu
  pendant `fun` — `:global.trans` ou un processus dedie — donc un INTERBLOCAGE possible des qu'un
  `fun` fourni par un appelant appelle `cached/2` sur une autre cle pendant qu'un autre processus
  fait l'inverse. Poser ce risque dans un module de fondation pour economiser un calcul de schema
  au premier acces est un mauvais echange. Corollaire pour l'appelant : **`fun` doit etre PURE et
  sans effet de bord observable** — ce qui est deja le cas des sept sites (lire un fichier, decoder,
  resoudre).
  """
  @spec cached(term(), (-> term())) :: term()
  def cached(persistent_key, fun) when is_function(fun, 0) do
    case :persistent_term.get(persistent_key, @miss) do
      @miss ->
        value = fun.()

        # 6-002 — ON RELIT AVANT D'ECRIRE : LE CHECK-THEN-ACT ECRIVAIT DEUX FOIS.
        #
        # Deux processus qui manquent la meme cle calculent tous les deux, puis ecrivaient tous les
        # deux. Le second `put` est un GC GLOBAL de plus (cf. F-001) pour ranger une valeur qui est
        # deja la — et il REMPLACE le terme que les lecteurs precedents ont recu, ce qui annule
        # gratuitement leur partage.
        #
        # ⚠ Ce que cette relecture ne fait PAS, et il ne faut pas le croire : elle ne donne pas a
        # tout le monde le meme terme physique. `:persistent_term.put/2` COPIE la valeur dans sa
        # zone ; l'ecrivain repart donc toujours avec SON exemplaire, course ou pas. Le partage est
        # une propriete des LECTEURS. Ce qui est gagne ici est borne et reel : une seule ecriture
        # par cle, et le perdant se comporte en lecteur au lieu d'emporter une copie de plus.
        case :persistent_term.get(persistent_key, @miss) do
          @miss ->
            :persistent_term.put(persistent_key, value)
            value

          winner ->
            winner
        end

      value ->
        value
    end
  end
end
