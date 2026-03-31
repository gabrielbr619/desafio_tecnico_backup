defmodule WCore.Release do
  @moduledoc """
  Tarefas de release executadas antes do start do servidor.
  Chamado pelo entrypoint.sh via `bin/w_core eval "WCore.Release.migrate()"`.

  Garante que todas as migrações Ecto estejam aplicadas antes do Phoenix
  aceitar conexões — crítico para o schema SQLite estar correto.
  """

  @app :w_core

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  defp repos, do: Application.fetch_env!(@app, :ecto_repos)

  defp load_app do
    Application.load(@app)
  end
end
