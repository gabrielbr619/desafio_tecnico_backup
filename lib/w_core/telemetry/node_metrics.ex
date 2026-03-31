defmodule WCore.Telemetry.NodeMetrics do
  use Ecto.Schema
  import Ecto.Changeset

  @valid_statuses ~w(online offline degraded unknown)

  schema "node_metrics" do
    field :status, :string, default: "unknown"
    field :total_events_processed, :integer, default: 0
    field :last_payload, :string
    field :last_seen_at, :utc_datetime_usec

    belongs_to :node, WCore.Telemetry.Node

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(metrics, attrs) do
    metrics
    |> cast(attrs, [:status, :total_events_processed, :last_payload, :last_seen_at, :node_id])
    |> validate_required([:node_id])
    |> validate_inclusion(:status, @valid_statuses)
    |> unique_constraint(:node_id)
    |> foreign_key_constraint(:node_id)
  end

  def valid_statuses, do: @valid_statuses
end
