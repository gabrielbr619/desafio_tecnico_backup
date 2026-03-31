defmodule WCore.Telemetry.StatusEvent do
  use Ecto.Schema
  import Ecto.Changeset

  schema "status_events" do
    field :from_status, :string
    field :to_status, :string
    field :recorded_at, :utc_datetime_usec

    belongs_to :node, WCore.Telemetry.Node

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [:node_id, :from_status, :to_status, :recorded_at])
    |> validate_required([:node_id, :to_status, :recorded_at])
  end
end
