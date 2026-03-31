defmodule WCore.Telemetry.TelemetryServer do
  @moduledoc """
  GenServer responsável por toda a escrita no ETS.

  É o único processo que cria e possui a tabela ETS :w_core_telemetry_cache.
  LiveViews e outras partes do sistema leem o ETS diretamente (acesso :public),
  mas toda escrita passa por este processo via cast assíncrono.

  ## ETS table layout
    {node_id, status, event_count, last_payload, timestamp}
      [1]       [2]      [3]          [4]           [5]
  """

  use GenServer
  require Logger

  alias WCore.Telemetry

  @table :w_core_telemetry_cache

  # Posições no tuple ETS (1-indexed, posição 1 é a chave)
  @pos_status 2
  @pos_count 3
  @pos_payload 4
  @pos_ts 5

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Envia um heartbeat para processamento assíncrono (cast — não bloqueia o sensor).
  O ETS é atualizado antes do retorno do próximo `handle_cast`.
  """
  @spec process_heartbeat(integer(), String.t(), map()) :: :ok
  def process_heartbeat(node_id, status, payload) do
    GenServer.cast(__MODULE__, {:heartbeat, node_id, status, payload})
  end

  @doc """
  Lê o estado atual de um nó diretamente do ETS (sem passar pelo GenServer).
  O(1) lookup. Seguro para chamada de qualquer processo graças ao acesso :public.
  """
  @spec get_node_state(integer()) ::
          {:ok, {integer(), String.t(), integer(), String.t(), DateTime.t()}} | :not_found
  def get_node_state(node_id) do
    case :ets.lookup(@table, node_id) do
      [entry] -> {:ok, entry}
      [] -> :not_found
    end
  end

  @doc """
  Retorna todos os estados atuais do ETS para flush ou leitura do dashboard.
  Leitura direta sem passar pelo GenServer mailbox.
  """
  @spec all_node_states() :: list()
  def all_node_states do
    :ets.tab2list(@table)
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :public, {:read_concurrency, true}])
    Logger.info("[TelemetryServer] ETS table #{@table} created")

    # Aquece o cache com o último estado conhecido do SQLite.
    # Após um crash e restart, o dashboard não fica em branco.
    warm_up_from_db()

    {:ok, %{}}
  end

  @impl true
  def handle_cast({:heartbeat, node_id, new_status, payload}, state) do
    previous_status = current_status(node_id)
    now = DateTime.utc_now()
    payload_str = Jason.encode!(payload)

    case :ets.lookup(@table, node_id) do
      [] ->
        # Primeiro heartbeat deste nó: insere com count = 1
        :ets.insert(@table, {node_id, new_status, 1, payload_str, now})

      _ ->
        # ets:update_counter é uma operação atômica via CAS no nível da VM.
        # Garante que incrementos concorrentes nunca se percam, mesmo que
        # vários processos enviem heartbeats para o mesmo node_id.
        :ets.update_counter(@table, node_id, {@pos_count, 1})

        # update_element NÃO é atômico com update_counter, mas isso é aceitável:
        # o count é sempre preciso; status/payload refletem o write mais recente
        # (last-writer-wins), que é o comportamento correto para telemetria.
        :ets.update_element(@table, node_id, [
          {@pos_status, new_status},
          {@pos_payload, payload_str},
          {@pos_ts, now}
        ])
    end

    # Sinaliza ao WriteBehindWorker que há dado novo para persistir
    WCore.Telemetry.WriteBehindWorker.mark_dirty()

    # Broadcast para o tópico do nó em todo heartbeat.
    # A NodeLive usa isso pra atualizar o histórico de payloads em tempo real.
    Phoenix.PubSub.broadcast(
      WCore.PubSub,
      "telemetry:node:#{node_id}",
      {:heartbeat_received, node_id, new_status, payload_str, now}
    )

    # Broadcast global somente em mudança de status — evita saturar o DashboardLive
    # com milhares de mensagens por segundo durante carga alta
    if new_status != previous_status do
      Phoenix.PubSub.broadcast(
        WCore.PubSub,
        "telemetry:updates",
        {:status_change, node_id, new_status, now}
      )

      # Persiste a mudança de status no SQLite (async pra não bloquear o GenServer)
      Task.start(fn ->
        Telemetry.log_status_change(node_id, previous_status, new_status)
      end)
    end

    # Persiste o heartbeat individual no histórico (async)
    Task.start(fn ->
      Telemetry.log_heartbeat(node_id, new_status, payload_str)
    end)

    {:noreply, state}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp current_status(node_id) do
    case :ets.lookup(@table, node_id) do
      [{_, status, _, _, _}] -> status
      [] -> nil
    end
  end

  defp warm_up_from_db do
    try do
      Telemetry.list_nodes_with_metrics()
      |> Enum.each(fn
        %{node: node, metrics: nil} ->
          :ets.insert(@table, {node.id, "unknown", 0, "{}", DateTime.utc_now()})

        %{node: node, metrics: m} ->
          :ets.insert(
            @table,
            {node.id, m.status, m.total_events_processed,
             m.last_payload || "{}", m.last_seen_at || DateTime.utc_now()}
          )
      end)

      Logger.info("[TelemetryServer] ETS warmed up from SQLite")
    rescue
      e ->
        Logger.warning("[TelemetryServer] Could not warm up ETS from DB: #{inspect(e)}")
    end
  end
end
