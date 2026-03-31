defmodule WCore.Repo.Migrations.CreateNodes do
  use Ecto.Migration

  def change do
    create table(:nodes) do
      add :machine_identifier, :string, null: false
      add :location, :string

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:nodes, [:machine_identifier])
  end
end
