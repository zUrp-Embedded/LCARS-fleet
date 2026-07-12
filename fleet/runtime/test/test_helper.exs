# Helper unique post-collapse (fusion des 14 helpers umbrella — migration Z1).
# - `put_env :start_listener` : ceinture-bretelles héritée du helper fleet_api. config/test.exs
#   le pose déjà ; conservé parce qu'un test qui manipule la config globale ne doit pas rendre
#   le listener bindable par accident (même invariant hermétique, deux verrous).
# - PAS d'`exclude: [:r1_seam]` global : l'exclusion était LOCALE à fleet_api (son test WS R1,
#   rouge-par-design, porte désormais son propre `@moduletag skip:`) — les tests :r1_seam
#   d'event_router tournent et doivent continuer de tourner.
# - `ensure_all_started(:fleet_workflow)` (ex-helper workflow) : couvert par le boot de l'app
#   unique en env test — plus rien à démarrer à la main.
Application.put_env(:fleet_api, :start_listener, false)
ExUnit.start()
