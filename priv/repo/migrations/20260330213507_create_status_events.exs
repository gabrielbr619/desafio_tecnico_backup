defmodule WCore.Repo.Migrations.CreateStatusEvents do
  use Ecto.Migration

  def change do
    create table(:status_events) do
      add :node_id, references(:nodes, on_delete: :delete_all), null: false
      add :from_status, :string
      add :to_status, :string, null: false
      add :recorded_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:status_events, [:node_id, :recorded_at])
  end
end
