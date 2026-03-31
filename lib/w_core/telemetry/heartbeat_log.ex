defmodule WCore.Telemetry.HeartbeatLog do
  use Ecto.Schema
  import Ecto.Changeset

  schema "heartbeat_logs" do
    field :status, :string
    field :payload, :string

    belongs_to :node, WCore.Telemetry.Node

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(log, attrs) do
    log
    |> cast(attrs, [:node_id, :status, :payload])
    |> validate_required([:node_id, :status])
  end
end
