defmodule WCore.Telemetry.Node do
  use Ecto.Schema
  import Ecto.Changeset

  schema "nodes" do
    field :machine_identifier, :string
    field :location, :string

    has_one :metrics, WCore.Telemetry.NodeMetrics
    has_many :status_events, WCore.Telemetry.StatusEvent
    has_many :heartbeat_logs, WCore.Telemetry.HeartbeatLog

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(node, attrs) do
    node
    |> cast(attrs, [:machine_identifier, :location])
    |> validate_required([:machine_identifier])
    |> validate_length(:machine_identifier, min: 1, max: 255)
    |> unique_constraint(:machine_identifier)
  end
end
