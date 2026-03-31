defmodule WCore.Telemetry.TelemetryServerTest do
  use WCore.DataCase, async: false

  alias WCore.Telemetry.TelemetryServer

  @table :w_core_telemetry_cache

  # Usa IDs altos para não colidir com dados de dev/seed
  @node_base 900_000

  describe "atomic event counting" do
    test "10.000 heartbeats concorrentes produzem contagem exata no ETS" do
      node_id = @node_base + 1
      :ets.insert(@table, {node_id, "online", 0, "{}", DateTime.utc_now()})

      # 100 Tasks × 100 heartbeats = 10.000 eventos
      tasks =
        for _ <- 1..100 do
          Task.async(fn ->
            for _ <- 1..100 do
              TelemetryServer.process_heartbeat(node_id, "online", %{})
            end
          end)
        end

      Enum.each(tasks, &Task.await(&1, 30_000))

      # Drena o mailbox do GenServer antes de ler o ETS
      :sys.get_state(TelemetryServer)

      [{^node_id, _status, count, _payload, _ts}] = :ets.lookup(@table, node_id)
      assert count == 10_000, "Esperado 10.000 eventos, obteve #{count}"
    end

    test "status idêntico não gera broadcast no PubSub" do
      node_id = @node_base + 2
      :ets.insert(@table, {node_id, "online", 0, "{}", DateTime.utc_now()})

      Phoenix.PubSub.subscribe(WCore.PubSub, "telemetry:updates")

      for _ <- 1..10 do
        TelemetryServer.process_heartbeat(node_id, "online", %{})
      end

      # Drena mailbox
      :sys.get_state(TelemetryServer)

      # Nenhum broadcast deve ter chegado (mesmo status)
      refute_receive {:status_change, ^node_id, _, _}, 200
    end

    test "mudança de status dispara exatamente um broadcast" do
      node_id = @node_base + 3
      :ets.insert(@table, {node_id, "online", 0, "{}", DateTime.utc_now()})

      Phoenix.PubSub.subscribe(WCore.PubSub, "telemetry:updates")

      TelemetryServer.process_heartbeat(node_id, "degraded", %{})
      :sys.get_state(TelemetryServer)

      assert_receive {:status_change, ^node_id, "degraded", _}, 500

      # Sem segundo broadcast
      refute_receive {:status_change, ^node_id, _, _}, 200
    end

    test "múltiplas mudanças de status geram broadcast por transição" do
      node_id = @node_base + 4
      :ets.insert(@table, {node_id, "online", 0, "{}", DateTime.utc_now()})

      Phoenix.PubSub.subscribe(WCore.PubSub, "telemetry:updates")

      TelemetryServer.process_heartbeat(node_id, "degraded", %{})
      TelemetryServer.process_heartbeat(node_id, "offline", %{})
      :sys.get_state(TelemetryServer)

      assert_receive {:status_change, ^node_id, "degraded", _}, 500
      assert_receive {:status_change, ^node_id, "offline", _}, 500
    end

    test "primeiro heartbeat de um nó insere no ETS com count = 1" do
      node_id = @node_base + 5

      TelemetryServer.process_heartbeat(node_id, "online", %{temp: 42})
      :sys.get_state(TelemetryServer)

      assert [{^node_id, "online", 1, payload, _ts}] = :ets.lookup(@table, node_id)
      assert {:ok, %{"temp" => 42}} = Jason.decode(payload)
    end
  end
end
