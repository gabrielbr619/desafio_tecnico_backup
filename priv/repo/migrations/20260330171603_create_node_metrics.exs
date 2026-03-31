defmodule WCore.Repo.Migrations.CreateNodeMetrics do
  use Ecto.Migration

  def change do
    create table(:node_metrics) do
      add :node_id, references(:nodes, on_delete: :delete_all), null: false
      add :status, :string, default: "unknown"
      add :total_events_processed, :integer, default: 0
      add :last_payload, :text
      add :last_seen_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:node_metrics, [:node_id])
    create index(:node_metrics, [:status])
    create index(:node_metrics, [:last_seen_at])
  end
end
