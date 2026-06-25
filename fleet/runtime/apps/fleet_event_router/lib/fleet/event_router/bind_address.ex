defmodule Fleet.EventRouter.BindAddress do
  @moduledoc """
  Source UNIQUE de l'adresse IP de bind des listeners HTTP du runtime.

  Invariant établi par construction (et non par 4 patches isolés) :

  > Tout listener Cowboy du runtime bind la loopback `{127, 0, 0, 1}` par
  > défaut. Une exposition non-locale (toutes interfaces, ou une interface
  > précise) est un opt-in EXPLICITE et NOMMÉ — jamais le défaut silencieux.

  Le contrat de sécurité du runtime est « frontière = isolation réseau /
  container » (cf. `Fleet.API.Rest` § Auth, decks no-auth). Ce contrat n'est
  réellement IMPOSÉ que si le code force le bind loopback : sans `:ip`, Cowboy
  écoute `0.0.0.0` (toutes interfaces) et la frontière n'est plus garantie par
  le runtime mais déléguée à un pare-feu/réseau externe — implicite, donc
  fragile. Cette fonction est ce point unique de calcul ; un 5e listener qui
  l'oublie est le seul moyen de régresser (et il est attrapé par les tests de
  bind de chaque surface).

  ## Override d'exposition (opt-in nommé)

  Deux niveaux, du plus spécifique au plus global :

    1. **Par surface** — l'appelant nomme une env var dédiée (ex.
       `LCARS_WEBHOOK_BIND_HOST` pour le webhook forge, seule surface dont
       l'exposition publique est un besoin légitime : une forge distante POST
       sur le webhook, la loopback la bloquerait). Présence de l'env = intention
       claire d'exposer CETTE surface.
    2. **Global** — `LCARS_BIND_HOST` expose TOUS les listeners (déploiement
       derrière un réseau de confiance qui assume l'isolation lui-même).

  L'override par surface l'emporte sur le global. Absence des deux → loopback.

  La valeur d'une env est un host : soit une IP littérale (`0.0.0.0`,
  `192.168.1.10`, `::`, …), soit un nom résolu via DNS. On reste en TCP
  (pas de socket Unix) — c'est uniquement l'`ip` de la socket d'écoute.
  """

  @loopback {127, 0, 0, 1}

  @doc """
  IP de bind à passer dans les options de transport d'un listener Cowboy
  (`options: [ip: ...]` pour Plug.Cowboy ; `:host` pour le transport HTTP ExMCP,
  qui la dérive lui-même).

  `surface_env` (optionnel) = nom de l'env var d'override SPÉCIFIQUE à cette
  surface. Si elle est posée, sa valeur gagne. Sinon on retombe sur l'override
  global `LCARS_BIND_HOST`. Sinon loopback `{127, 0, 0, 1}`.

  Retourne un tuple d'adresse `:inet.ip_address()` (IPv4 ou IPv6).
  """
  @spec ip(String.t() | nil) :: :inet.ip_address()
  def ip(surface_env \\ nil) do
    case override_host(surface_env) do
      nil -> @loopback
      host -> parse_host(host)
    end
  end

  @doc """
  L'adresse de bind sous forme de STRING (`"127.0.0.1"`), pour les transports qui veulent un host
  textuel et non un tuple. CONTRAT ExMCP : `ExMCP.Server.Transport.start_http_server/4` fait
  `Logger.info("…on \#{host}:…")` — donc `to_string(host)` — AVANT son `parse_host`, ce qui CRASHE
  (`Protocol.UndefinedError String.Chars` pour Tuple) si on lui passe le tuple `ip/1`. On lui passe
  donc cette string ; ExMCP la re-parse en tuple côté ranch. (Plug.Cowboy, lui, veut `options: [ip:
  <tuple>]` → utiliser `ip/1` pour Cowboy, `host_string/1` pour ExMCP.)
  """
  @spec host_string(String.t() | nil) :: String.t()
  def host_string(surface_env \\ nil) do
    surface_env |> ip() |> :inet.ntoa() |> to_string()
  end

  @doc "La loopback IPv4 — défaut sûr exposé pour les tests."
  @spec loopback() :: :inet.ip_address()
  def loopback, do: @loopback

  # Override par surface (si nommé et posé) PUIS override global. Une env vide
  # ("") ne compte pas comme override — un export accidentellement vidé ne doit
  # pas ré-exposer un listener.
  defp override_host(surface_env) do
    surface_value =
      case surface_env do
        nil -> nil
        name -> presence(System.get_env(name))
      end

    surface_value || presence(System.get_env("LCARS_BIND_HOST"))
  end

  defp presence(val) when is_binary(val) do
    case String.trim(val) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp presence(_), do: nil

  # Host → tuple IP. IP littérale parsée directement (IPv4/IPv6) ; sinon
  # résolution DNS. Une valeur d'override invalide (ni IP ni nom résoluble) DOIT
  # échouer fort : un opérateur a explicitement demandé une exposition publique,
  # retomber en silence sur la loopback masquerait son intention (il croirait
  # exposé, ce ne le serait pas). On refuse plutôt le boot avec un message clair.
  defp parse_host(host) do
    charlist = String.to_charlist(host)

    case :inet.parse_address(charlist) do
      {:ok, ip} ->
        ip

      {:error, :einval} ->
        case :inet.getaddr(charlist, :inet) do
          {:ok, ip} ->
            ip

          {:error, reason} ->
            raise ArgumentError,
                  "LCARS bind host #{inspect(host)} invalide — ni une IP, ni un nom résoluble " <>
                    "(#{inspect(reason)}). Corriger l'env d'exposition (LCARS_BIND_HOST ou " <>
                    "l'override de surface) ; boot refusé."
        end
    end
  end
end
