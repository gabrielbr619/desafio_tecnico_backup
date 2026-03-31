defmodule WCore.Telemetry do
  @moduledoc """
  Telemetry context — persistence layer for nodes and their metrics.

  This module handles only SQLite operations. Hot-path reads/writes go through
  WCore.Telemetry.TelemetryServer (ETS). This context is called by:
    - WriteBehindWorker (batch upserts)
    - TelemetryServer.init/1 (warm-up from DB on startup)
    - LiveView fallback (initial mount before ETS is warm)
  """

  import Ecto.Query
  alias WCore.Repo
  alias WCore.Telemetry.{Node, NodeMetrics, StatusEvent, HeartbeatLog}

  # ---------------------------------------------------------------------------
  # Node operations
  # ---------------------------------------------------------------------------

  @doc """
  Finds a node by machine_identifier or creates it if it doesn't exist.
  Safe for concurrent calls — uses INSERT OR IGNORE + SELECT pattern via
  Ecto's on_conflict: :nothing.
  """
  @spec find_or_create_node(String.t(), String.t() | nil) ::
          {:ok, Node.t()} | {:error, Ecto.Changeset.t()}
  def find_or_create_node(machine_identifier, location \\ nil) do
    case Repo.get_by(Node, machine_identifier: machine_identifier) do
      %Node{} = node ->
        {:ok, node}

      nil ->
        %Node{}
        |> Node.changeset(%{machine_identifier: machine_identifier, location: location})
        |> Repo.insert(on_conflict: :nothing, conflict_target: [:machine_identifier])
        |> case do
          {:ok, %Node{id: nil}} ->
            # Race: another process inserted between our get and insert
            {:ok, Repo.get_by!(Node, machine_identifier: machine_identifier)}

          result ->
            result
        end
    end
  end

  @doc """
  Returns all nodes with their most recent metrics.
  Used on dashboard initial load and TelemetryServer warm-up.
  """
  @spec list_nodes_with_metrics() :: list(map())
  def list_nodes_with_metrics do
    Node
    |> preload(:metrics)
    |> Repo.all()
    |> Enum.map(fn node ->
      %{node: node, metrics: node.metrics}
    end)
  end

  # ---------------------------------------------------------------------------
  # Metrics operations (Write-Behind path)
  # ---------------------------------------------------------------------------

  @doc """
  Batch upserts node metrics from ETS into SQLite.
  Called exclusively by WriteBehindWorker — single writer guarantee.

  Uses INSERT OR REPLACE semantics via on_conflict to handle both
  first-time inserts and subsequent updates in one statement.
  """
  @spec batch_upsert_metrics(list(map())) :: {:ok, non_neg_integer()} | {:error, term()}
  def batch_upsert_metrics([]), do: {:ok, 0}

  def batch_upsert_metrics(entries) when is_list(entries) do
    now = DateTime.utc_now()

    rows =
      Enum.map(entries, fn %{
                              node_id: node_id,
                              status: status,
                              total_events_processed: count,
                              last_payload: payload,
                              last_seen_at: ts
                            } ->
        %{
          node_id: node_id,
          status: status,
          total_events_processed: count,
          last_payload: payload,
          last_seen_at: ts,
          inserted_at: now,
          updated_at: now
        }
      end)

    Repo.transaction(fn ->
      {n, _} =
        Repo.insert_all(
          NodeMetrics,
          rows,
          on_conflict:
            {:replace,
             [:status, :total_events_processed, :last_payload, :last_seen_at, :updated_at]},
          conflict_target: [:node_id]
        )

      n
    end)
  end

  @doc """
  Returns the current metrics for a single node from SQLite.
  Prefer TelemetryServer.get_node_state/1 (ETS) for hot-path reads.
  """
  @spec get_node_metrics(integer()) :: NodeMetrics.t() | nil
  def get_node_metrics(node_id) do
    Repo.get_by(NodeMetrics, node_id: node_id)
  end

  # ---------------------------------------------------------------------------
  # Status events (history)
  # ---------------------------------------------------------------------------

  @doc "Logs a status change event for a node."
  @spec log_status_change(integer(), String.t() | nil, String.t()) :: {:ok, StatusEvent.t()} | {:error, term()}
  def log_status_change(node_id, from_status, to_status) do
    %StatusEvent{}
    |> StatusEvent.changeset(%{
      node_id: node_id,
      from_status: from_status,
      to_status: to_status,
      recorded_at: DateTime.utc_now()
    })
    |> Repo.insert()
  end

  @doc "Returns the most recent status events for a node, ordered by time descending."
  @spec list_status_events(integer(), non_neg_integer()) :: list(StatusEvent.t())
  def list_status_events(node_id, limit \\ 50) do
    StatusEvent
    |> where([e], e.node_id == ^node_id)
    |> order_by([e], desc: e.recorded_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc "Returns a node by ID with its metadata."
  @spec get_node(integer()) :: Node.t() | nil
  def get_node(node_id) do
    Repo.get(Node, node_id)
  end

  # ---------------------------------------------------------------------------
  # Heartbeat logs (payload history)
  # ---------------------------------------------------------------------------

  @heartbeat_log_limit 50

  @doc "Logs an individual heartbeat and prunes old entries (keeps last #{@heartbeat_log_limit} per node)."
  @spec log_heartbeat(integer(), String.t(), String.t() | nil) ::
          {:ok, HeartbeatLog.t()} | {:error, term()}
  def log_heartbeat(node_id, status, payload) do
    result =
      %HeartbeatLog{}
      |> HeartbeatLog.changeset(%{node_id: node_id, status: status, payload: payload})
      |> Repo.insert()

    prune_heartbeat_logs(node_id)
    result
  end

  defp prune_heartbeat_logs(node_id) do
    keep_ids =
      from(h in HeartbeatLog,
        where: h.node_id == ^node_id,
        order_by: [desc: h.inserted_at],
        limit: @heartbeat_log_limit,
        select: h.id
      )

    Repo.delete_all(
      from(h in HeartbeatLog,
        where: h.node_id == ^node_id and h.id not in subquery(keep_ids)
      )
    )
  end

  @doc "Returns the N most recent heartbeat logs for a node, newest first."
  @spec list_recent_payloads(integer(), non_neg_integer()) :: list(HeartbeatLog.t())
  def list_recent_payloads(node_id, limit \\ 10) do
    HeartbeatLog
    |> where([h], h.node_id == ^node_id)
    |> order_by([h], desc: h.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end
end
