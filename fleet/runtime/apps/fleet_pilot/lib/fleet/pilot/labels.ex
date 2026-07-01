defmodule Fleet.Pilot.Labels do
  @moduledoc """
  Vocabulaire de labels du **wire-protocol** forge-state-machine : la forge EST la machine à états,
  ces labels sont son fil. SOURCE UNIQUE.

  Ces constantes NE SONT PAS de la config : elles SONT le protocole. Le poller, le dispatcher,
  le completer et le consumer doivent s'accorder au byte près — un verrou `lcars-in-flight` posé
  par l'un n'est levé par l'autre que s'ils nomment le MÊME label. Les re-déclarer en `@attr` par
  module = dérive silencieuse à un renommage. Centralisé ici, consommé partout.

  Usage compile-time (préserve la sémantique de constante, utilisable en `cond`/pattern) :

      @in_flight_label Fleet.Pilot.Labels.in_flight()

  ou runtime direct (`Fleet.Pilot.Labels.awaits_arch()`).

  Le vocabulaire se réduit aux VERROUS `lcars-in-flight` et `lcars-awaits-arch` : ni `lcars-dispatched`
  (c'était le lock d'un poller legacy, retiré) ni chaîne `state:*` (l'état vit dans la route-comment ; un
  état-dans-label contredirait « état = route-comment »). Tout label hors de ces deux verrous n'existe pas.
  """

  @in_flight "lcars-in-flight"
  @awaits_arch "lcars-awaits-arch"

  @doc "Verrou « pod en vol » : posé AVANT le spawn (anti double-spawn), levé en fin-de-step-run."
  @spec in_flight() :: String.t()
  def in_flight, do: @in_flight

  @doc "Verrou HUMAIN : l'issue attend une action via l'arch (verdict escalate/halt/redirect)."
  @spec awaits_arch() :: String.t()
  def awaits_arch, do: @awaits_arch
end
