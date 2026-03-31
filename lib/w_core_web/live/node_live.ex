defmodule WCoreWeb.NodeLive do
  @moduledoc """
  Visão de detalhe de um nó individual.
  Usa tópico granular "telemetry:node:{id}" para receber apenas eventos
  do nó em questão, sem ruído dos demais.
  """

  use WCoreWeb, :live_view

  alias WCore.Telemetry
  alias WCore.Telemetry.TelemetryServer
  import WCoreWeb.TelemetryComponents

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    node_id = String.to_integer(id)

    if connected?(socket) do
      Phoenix.PubSub.subscribe(WCore.PubSub, "telemetry:node:#{node_id}")
    end

    node_state = load_node(node_id)
    db_node = Telemetry.get_node(node_id)
    events = Telemetry.list_status_events(node_id, 20)
    payload_logs = Telemetry.list_recent_payloads(node_id, 10)

    {:ok,
     assign(socket,
       node_id: node_id,
       node: node_state,
       db_node: db_node,
       events: events,
       payload_logs: payload_logs,
       page_title: "Nó ##{node_id} — W-Core"
     )}
  end

  @impl true
  def handle_info({:heartbeat_received, node_id, new_status, payload, ts}, socket) do
    if node_id == socket.assigns.node_id do
      # Recarrega do ETS para pegar event_count atualizado (O(1) lookup)
      updated_node = load_node(node_id)

      # Prepend do novo payload na lista — sem query DB, dado vem inline no evento
      new_log = %{status: new_status, payload: payload, inserted_at: ts}
      updated_logs = [new_log | socket.assigns.payload_logs] |> Enum.take(10)

      # Se houve mudança de status, recarrega a timeline do DB
      events =
        if new_status != (socket.assigns.node && socket.assigns.node.status) do
          Telemetry.list_status_events(node_id, 20)
        else
          socket.assigns.events
        end

      {:noreply, assign(socket, node: updated_node, payload_logs: updated_logs, events: events)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(:dashboard_tick, socket) do
    {:noreply, assign(socket, node: load_node(socket.assigns.node_id))}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-gray-950 text-gray-100">
      <header class="border-b border-gray-800 px-6 py-4">
        <.link navigate="/dashboard" class="text-gray-500 hover:text-white text-sm transition-colors">
          ← Voltar ao Dashboard
        </.link>
      </header>

      <main class="px-6 py-6 max-w-4xl">
        <%= if @node do %>
          <.node_detail_header node={@node} db_node={@db_node} />

          <div class="node-detail-grid">
            <.payload_history logs={@payload_logs} />
            <.timeline events={@events} />
          </div>
        <% else %>
          <div class="empty-state">
            <div class="empty-state__icon empty-state__icon--muted">
              <svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="1" stroke="currentColor" class="w-12 h-12">
                <path stroke-linecap="round" stroke-linejoin="round" d="M12 9v3.75m9-.75a9 9 0 1 1-18 0 9 9 0 0 1 18 0Zm-9 3.75h.008v.008H12v-.008Z" />
              </svg>
            </div>
            <h3 class="empty-state__title empty-state__title--sm">Nó #<%= @node_id %> não encontrado</h3>
            <p class="empty-state__description">
              Este sensor ainda não enviou nenhum heartbeat ou não está no cache.
            </p>
          </div>
        <% end %>
      </main>
    </div>
    """
  end

  defp load_node(node_id) do
    case TelemetryServer.get_node_state(node_id) do
      {:ok, {id, status, count, payload, ts}} ->
        %{id: id, status: status, event_count: count, last_payload: payload, last_seen_at: ts}

      :not_found ->
        nil
    end
  end
end
