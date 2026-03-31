defmodule WCoreWeb.HeartbeatController do
  use WCoreWeb, :controller

  alias WCore.Telemetry
  alias WCore.Telemetry.TelemetryServer

  @doc """
  Accepts a heartbeat (pulse) from a sensor node.

  Expected JSON body:
    - machine_identifier (required) — unique sensor ID
    - status (required) — "online" | "offline" | "degraded"
    - location (optional) — physical location string
    - payload (optional) — arbitrary metrics map

  The event is immediately written to ETS via TelemetryServer (non-blocking cast).
  SQLite persistence happens asynchronously via WriteBehindWorker.
  """
  def create(conn, params) do
    with {:ok, machine_id} <- fetch_required(params, "machine_identifier"),
         {:ok, status} <- fetch_required(params, "status"),
         :ok <- validate_status(status),
         {:ok, node} <- Telemetry.find_or_create_node(machine_id, params["location"]) do
      TelemetryServer.process_heartbeat(
        node.id,
        status,
        Map.get(params, "payload", %{})
      )

      conn
      |> put_status(:accepted)
      |> json(%{ok: true, node_id: node.id})
    else
      {:missing, field} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "#{field} is required"})

      {:invalid_status, status} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "invalid status '#{status}', must be one of: online, offline, degraded"})

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: inspect(reason)})
    end
  end

  defp fetch_required(params, key) do
    case Map.fetch(params, key) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:missing, key}
    end
  end

  defp validate_status(status) when status in ~w(online offline degraded), do: :ok
  defp validate_status(status), do: {:invalid_status, status}
end
