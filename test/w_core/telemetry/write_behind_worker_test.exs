defmodule WCore.Telemetry.WriteBehindWorkerTest do
  use WCore.DataCase, async: false

  alias WCore.Telemetry
  alias WCore.Telemetry.{TelemetryServer, WriteBehindWorker}

  @node_base 910_000

  describe "write-behind flush" do
    test "flush_now/0 persiste contagens do ETS no SQLite com precisão" do
      {:ok, node1} = Telemetry.find_or_create_node("wb-node-1-#{@node_base}", "lab")
      {:ok, node2} = Telemetry.find_or_create_node("wb-node-2-#{@node_base}", "lab")

      # 5.000 eventos por nó em paralelo
      tasks =
        for node <- [node1, node2] do
          Task.async(fn ->
            for _ <- 1..5_000 do
              TelemetryServer.process_heartbeat(node.id, "online", %{})
            end
          end)
        end

      Enum.each(tasks, &Task.await(&1, 30_000))
      :sys.get_state(TelemetryServer)

      # Flush síncrono: garante persistência antes das asserções
      assert :ok = WriteBehindWorker.flush_now()

      for node <- [node1, node2] do
        [{_id, _status, ets_count, _payload, _ts}] = :ets.lookup(:w_core_telemetry_cache, node.id)

        db_metrics = WCore.Repo.get_by!(WCore.Telemetry.NodeMetrics, node_id: node.id)

        assert ets_count == 5_000,
               "ETS: esperado 5.000 eventos para nó #{node.id}, obteve #{ets_count}"

        assert db_metrics.total_events_processed == ets_count,
               "SQLite #{db_metrics.total_events_processed} != ETS #{ets_count} para nó #{node.id}"
      end
    end

    test "threshold dispara flush antecipado antes do timer de 5s" do
      # No ambiente de teste, dirty_threshold = 50 (config/test.exs).
      # Enviamos exatamente 50 marks: o 50º dispara o flush (new_count >= 50)
      # e reseta dirty_count para 0. Um 51º mark resultaria em dirty_count = 1.
      for _ <- 1..50 do
        WriteBehindWorker.mark_dirty()
      end

      # Drena o mailbox do GenServer antes de checar o estado
      :sys.get_state(WriteBehindWorker)

      state = :sys.get_state(WriteBehindWorker)
      assert state.dirty_count == 0,
             "dirty_count deveria ter sido resetado após flush por threshold, mas é #{state.dirty_count}"
    end
  end
end
