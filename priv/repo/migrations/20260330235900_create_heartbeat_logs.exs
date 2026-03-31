defmodule WCore.Repo.Migrations.CreateHeartbeatLogs do
  use Ecto.Migration

  def change do
    create table(:heartbeat_logs) do
      add :node_id, references(:nodes, on_delete: :delete_all), null: false
      add :status, :string, null: false
      add :payload, :string

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:heartbeat_logs, [:node_id, :inserted_at])
  end
end
