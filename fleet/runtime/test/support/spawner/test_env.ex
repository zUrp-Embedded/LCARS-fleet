defmodule Fleet.Spawner.TestEnv do
  @moduledoc """
  Helper d'env applicatif pour les tests de cette app (dédup B6 du harnais).

  Remplace l'idiome réécrit dans chaque fichier : « save `prev = Application.get_env` ;
  `on_exit` → `put_env(prev)` ou `delete_env` ». La capture passe par `Application.fetch_env/2`
  (pas `get_env`) : une clé ABSENTE est re-supprimée au retour, une clé POSÉE — même à `nil` ou
  `false` — est reposée telle quelle. L'ancien idiome confondait les deux via le `nil` de `get_env`.

  À appeler depuis `setup`/`test` (le process du test) : la restauration s'enregistre via
  `ExUnit.Callbacks.on_exit/1`. Les `on_exit` s'exécutent en LIFO → des poses imbriquées
  (setup de module puis de describe) se dénouent dans le bon ordre.

  Chaque app de l'umbrella porte SA copie de ce module (même corps, module préfixé par l'app) :
  les test/support ne se voient pas entre apps et on ne crée pas de dépendance test cross-app.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  @doc """
  Pose `value` sous `{app, key}` et enregistre la restauration de la valeur PRÉCÉDENTE
  (repose, ou suppression si la clé était absente) à la fin du test. Pose + restauration
  en un appel — le site d'usage n'a plus ni `prev` ni `on_exit` à écrire.
  """
  def put_env_restoring(app, key, value) do
    restore_env_on_exit(app, key)
    Application.put_env(app, key, value)
  end

  @doc """
  Capture la valeur actuelle de `{app, key}` et enregistre sa restauration à la fin du test,
  SANS rien poser. Pour les setups dont les tests mutent ensuite la clé eux-mêmes
  (`put_env`/`delete_env` libres dans le corps du test).
  """
  def restore_env_on_exit(app, key) do
    prev = Application.fetch_env(app, key)

    on_exit(fn ->
      case prev do
        {:ok, value} -> Application.put_env(app, key, value)
        :error -> Application.delete_env(app, key)
      end
    end)
  end
end
