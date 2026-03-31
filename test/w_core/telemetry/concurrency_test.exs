defmodule WCore.Telemetry.ConcurrencyTest do
  use WCore.DataCase, async: false

  alias WCore.Telemetry
  alias WCore.Telemetry.{TelemetryServer, WriteBehindWorker}

  @moduletag :chaos
  @moduletag timeout: 120_000

  @doc """
  Teste de caos: 1.000 nós × 10 eventos = 10.000 eventos concorrentes.

  Verifica:
  1. Todos os 1.000 nós chegam ao ETS (nenhum evento perdido)
  2. Cada nó tem exatamente 10 eventos no ETS (sem over/undercount)
  3. Após flush, o SQLite tem 1.000 linhas em node_metrics
  4. Os totais do SQLite correspondem aos totais do ETS
  """
  test "10.000 eventos concorrentes: sem perda, sem condição de corrida, SQLite sincronizado" do
    suffix = System.unique_integer([:positive])

    # Cria 1.000 nós no SQLite
    nodes =
      for i <- 1..1_000 do
        {:ok, node} = Telemetry.find_or_create_node("chaos-#{suffix}-#{i}", "zone-#{rem(i, 10)}")
        node
      end

    # Cada nó recebe 10 heartbeats de processos concorrentes
    tasks =
      for node <- nodes do
        Task.async(fn ->
          for j <- 1..10 do
            status = Enum.at(["online", "degraded", "offline"], rem(j, 3))
            TelemetryServer.process_heartbeat(node.id, status, %{seq: j, node: node.id})
          end
        end)
      end

    # Aguarda todos com timeout generoso
    Enum.each(tasks, &Task.await(&1, 60_000))

    # Drena o mailbox do GenServer
    :sys.get_state(TelemetryServer)

    # --- Verificação 1 & 2: ETS ---
    ets_entries = :ets.tab2list(:w_core_telemetry_cache)
    ets_by_id = Map.new(ets_entries, fn {id, status, count, payload, ts} ->
      {id, %{status: status, count: count, payload: payload, ts: ts}}
    end)

    for node <- nodes do
      entry = Map.get(ets_by_id, node.id)

      assert entry != nil,
             "Nó #{node.id} não encontrado no ETS — evento foi perdido"

      assert entry.count == 10,
             "Nó #{node.id}: esperado 10 eventos, ETS tem #{entry.count}"
    end

    # --- Verificação 3 & 4: SQLite após flush síncrono ---
    assert :ok = WriteBehindWorker.flush_now()

    db_count =
      WCore.Repo.aggregate(
        from(m in WCore.Telemetry.NodeMetrics,
          where: m.node_id in ^Enum.map(nodes, & &1.id)),
        :count,
        :id
      )

    assert db_count == 1_000,
           "SQLite deveria ter 1.000 linhas em node_metrics, tem #{db_count}"

    # Verifica que contadores do SQLite batem com o ETS
    for node <- nodes do
      entry = Map.fetch!(ets_by_id, node.id)
      db = WCore.Repo.get_by!(WCore.Telemetry.NodeMetrics, node_id: node.id)

      assert db.total_events_processed == entry.count,
             "Divergência para nó #{node.id}: SQLite=#{db.total_events_processed}, ETS=#{entry.count}"
    end
  end
end
