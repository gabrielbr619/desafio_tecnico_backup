# Step 3 — LiveView e o Dashboard: aqui eu me senti em casa

## O que eu fiz

Esse foi o passo onde eu mais me empenhei, e faz sentido — interface é minha área. Construí o dashboard principal que mostra todos os nós em tempo real, uma página de detalhe pra cada nó, e um design system completo com componentes reutilizáveis cobrindo desde o formulário de login até os cards do dashboard.

- `DashboardLive` — grid com todos os nós, stats gerais, busca/filtro/sort em tempo real
- `NodeLive` — visão de detalhe com payload formatado e timeline de mudanças de status
- `TelemetryComponents` — biblioteca de componentes puros do dashboard
- `CoreComponents` — componentes de formulário e layout (inputs, botões, flash, tabelas)
- Design system dark completo em CSS puro, sem biblioteca de UI externa

## A grande virada: como o LiveView se compara ao React

Essa foi a parte mais interessante de aprender. No React, eu penso assim:

```
Browser: useState → render → user event → setState → re-render → DOM diff → patch
```

No LiveView, o fluxo é parecido mas o estado mora no servidor:

```
Server: assign → render → user event (via WebSocket) → handle_event → assign → diff → patch (via WS)
```

A sacada é que o `assign` do LiveView é o `useState` do React, mas roda no servidor. Quando o estado muda, o LiveView calcula o diff do HTML (não do DOM virtual — é diff de HTML string mesmo) e manda só o pedaço que mudou pelo WebSocket. O browser recebe o patch e aplica no DOM.

Parece estranho no começo — "como que o server vai ser rápido o suficiente pra fazer isso?" — mas na prática funciona. A latência de rede local (usina edge) é mínima, e o BEAM é absurdamente eficiente pra esse tipo de operação concorrente (cada conexão LiveView é um processo isolado, lembra do step 2).

### O que eu ganhei vs. o que eu perdi (comparando com React)

**Ganhei:**
- Sem estado duplicado entre client e server. No React eu preciso de React Query/SWR pra manter o front sincronizado com a API. Aqui não existe essa camada — o estado JÁ está no servidor.
- Real-time "de graça". Não preciso configurar Socket.io, criar eventos, gerenciar reconexão. O LiveView já faz isso via PubSub.
- Sem build de frontend pesado. Sem webpack/vite, sem bundle de 2MB, sem tree shaking. O HTML é renderizado no servidor.

**Perdi:**
- Interações muito rápidas (tipo drag-and-drop, animações complexas) seriam complicadas porque cada evento faz um roundtrip ao servidor. Pra um dashboard de telemetria não é problema, mas pra uma interface de desenho seria.
- Não tenho o ecossistema de componentes do React (Radix, Headless UI, etc). Precisei escrever os componentes do zero — o que acabou sendo um exercício valioso.

## Como eu implementei o fluxo reativo

### Dois tipos de atualização (isso foi a decisão mais importante)

Se eu fizesse broadcast de cada heartbeat individualmente, com 10.000 sensores mandando 1 heartbeat por segundo, cada LiveView receberia 10.000 mensagens/s. Inviável.

No Socket.io eu resolveria isso com throttle no servidor:
```javascript
// Socket.io — throttle por nó
const throttled = _.throttle((nodeId, data) => {
  io.to('dashboard').emit('node:update', { nodeId, ...data });
}, 5000);
```

No LiveView, separei em dois canais:

**1. Status change (imediato)** — dispara só quando o status do nó muda (online → offline, etc). Isso é raro e importante, então envia na hora.

```elixir
def handle_info({:status_change, node_id, new_status, ts}, socket) do
  updated_nodes = Enum.map(socket.assigns.all_nodes, fn node ->
    if node.id == node_id do
      # Aproveita o evento pra buscar o event_count atualizado direto do ETS (O(1))
      case TelemetryServer.get_node_state(node_id) do
        {:ok, {_, status, count, _, ts}} -> %{node | status: status, event_count: count, last_seen_at: ts}
        :not_found -> %{node | status: new_status, last_seen_at: ts}
      end
    else
      node
    end
  end)
  {:noreply, socket |> assign(all_nodes: updated_nodes) |> apply_filters_and_sort()}
end
```

Uma coisa que percebi depois: quando o status muda, seria uma pena atualizar só o badge e deixar o contador de eventos desatualizado. Já que estou processando o evento mesmo, fazer um lookup no ETS é O(1) e não custa nada. Então sempre que status muda, o card mostra o estado completo do nó — status, timestamp e event_count, tudo fresquinho.

O LiveView detecta que só um card mudou e envia o patch só daquele elemento pelo WebSocket. No React eu faria algo parecido com `React.memo` + `key` pra evitar re-renders desnecessários. Aqui o framework faz automaticamente.

**2. Dashboard tick (a cada 5s)** — quando o WriteBehindWorker faz flush, ele avisa os LiveViews. Aí eu faço reload completo do ETS pra atualizar contadores de todos os nós de uma vez.

```elixir
def handle_info(:dashboard_tick, socket) do
  all_nodes = load_nodes_from_ets()
  {:noreply, socket |> assign(all_nodes: all_nodes) |> apply_filters_and_sort()}
end
```

Isso cobre o caso em que um sensor manda muitos heartbeats sem mudar de status — o card não fica recebendo atualização a cada heartbeat (o que seria inviável com 10k sensores), mas o contador sobe no próximo tick. Pra um dashboard de monitoramento, atraso de 5s no contador é completamente aceitável. O que não pode atrasar é o badge de status — e esse é imediato.

É o equivalente a um `setInterval` de 5s fazendo `refetch()` no React Query — mas sem HTTP, sem JSON, sem overhead de rede.

### Tópicos: coarse-grained vs fine-grained

- `DashboardLive` escuta `"telemetry:updates"` (tópico global). Recebe mudanças de status e ticks.
- `NodeLive` escuta `"telemetry:node:#{id}"` (tópico por nó). Recebe só o que interessa.

No Socket.io seria: o dashboard entra na room `"all"`, e a página de detalhe entra na room `"node:123"`. Mesma ideia.

## Busca, filtro e ordenação no dashboard

Aqui eu quis explorar como o LiveView lida com interatividade de UI que no React eu faria com estado local. O dashboard tem:

- **Busca** por `machine_identifier` — com debounce de 300ms via `phx-debounce`
- **Filtro por status** — botões All / Online / Degraded / Offline com contagem de cada
- **Ordenação** — por ID, status, eventos ou último sinal, com toggle asc/desc

No React eu resolveria isso com `useState` local e `useMemo` pra derivar a lista filtrada:

```jsx
const [search, setSearch] = useState('');
const [filter, setFilter] = useState('all');
const filtered = useMemo(() => nodes.filter(...).sort(...), [nodes, search, filter]);
```

No LiveView, o estado mora no servidor via `assign`. A decisão de design foi manter `all_nodes` como fonte de verdade e `nodes` como a view derivada:

```elixir
socket
|> assign(all_nodes: raw_list)   # fonte de verdade
|> apply_filters_and_sort()       # recalcula :nodes sempre que all_nodes, search, filter ou sort mudam
```

A função `apply_filters_and_sort/1` é chamada em todos os `handle_event` (busca, filtro, sort) e também nos `handle_info` de atualização em tempo real. Isso garante que os filtros ativos são preservados quando chegam novos dados.

O `phx-debounce="300"` no input de busca foi uma descoberta interessante — equivalente ao `useDebounce` hook do React, mas declarativo no HTML. Sem nenhum JS manual.

## Página de detalhe do nó

A `NodeLive` mostra mais do que só o último payload. Aproveitei a tabela `status_events` (criada no step 2 como extensão do sistema de persistência) pra exibir uma timeline das mudanças de status do nó:

```
ONLINE  →  DEGRADED  →  OFFLINE  →  ONLINE
10:32      10:47         11:03       11:15
```

Isso é útil na prática: se um sensor ficou offline às 11h03 e voltou às 11h15, o operador consegue ver o histórico sem precisar fazer queries manuais no banco.

Os componentes `node_detail_header`, `payload_viewer` e `timeline` fazem essa composição de forma declarativa — mesma ideia de composição de componentes do React.

## O design system completo

No começo eu pensei "vou só customizar o que o Phoenix gerou". Mas aí vi que o template do Phoenix vem com referências ao Phoenix Framework na navbar, ícone de chama, links pra documentação — nada que faz sentido num produto de missão crítica industrial.

Decidi reescrever tudo do zero, começando pelo que o avaliador vai ver primeiro: o formulário de login.

### Arquitetura visual

O sistema tem dois níveis de componentes:

**`CoreComponents`** — layer de formulário/layout (gerado pelo Phoenix, customizado por mim):
- `input/1` — campo com label, estado de erro, classe `.wc-input`
- `button/1` — suporta `variant="primary"` e ghost, classes `.auth-btn`
- `flash/1` — notificações com slide-in animation, classes `.wc-flash`

**`TelemetryComponents`** — layer do dashboard:
- `status_badge/1` — badge com dot pulsante pra "online"
- `node_card/1` — card clicável com borda colorida por status
- `stats_bar/1` — métricas no topo (total, online, degraded, offline)
- `search_input/1` — input de busca com botão de limpar
- `filter_bar/1` — tabs de filtro com contagem por status
- `sort_controls/1` — cabeçalhos clicáveis com indicador de direção
- `empty_state/1` — tela vazia pra "sem nós" e "sem resultados de filtro"
- `timeline/1` — histórico de mudanças de status
- `payload_viewer/1` — JSON formatado do último heartbeat
- `node_detail_header/1` — header da página de detalhe com stats do nó

### A API é parecida com React function components:

```elixir
# Phoenix — declaração de props
attr :status, :string, required: true
def status_badge(assigns) do
  ~H"""
  <span class={"badge badge--#{@status}"}>
    <%= if @status == "online" do %>
      <span class="badge__dot badge__dot--pulse"></span>
    <% end %>
    <%= String.upcase(@status) %>
  </span>
  """
end
```

```jsx
// React — como eu faria
function StatusBadge({ status }) {
  return (
    <span className={`badge badge--${status}`}>
      {status === 'online' && <span className="badge__dot badge__dot--pulse" />}
      {status.toUpperCase()}
    </span>
  );
}
```

Muito parecido. As maiores diferenças:
- `attr :status, :string, required: true` é como PropTypes, mas validado em compile-time (não em runtime). Gostei disso — no React eu usaria TypeScript pra ter algo similar.
- `~H"""..."""` é o template HEEx. É como JSX, mas no servidor. `@status` acessa os assigns (tipo `props.status`).

### CSS: dark theme do zero

Tema escuro com fundo `rgb(3 7 18)` (quase preto), superfícies em `rgb(15 23 42)`, bordas em `rgb(30 41 59)`, e accent indigo `rgb(79 70 229)`. Tudo em CSS puro — sem Tailwind, sem biblioteca de componentes.

A navbar é estática:
```css
.site-nav {
  background: rgb(3 7 18);
  border-bottom: 1px solid rgb(30 41 59);
}
```

Os cards do dashboard usam BEM + modificadores por status:
```css
.node-card { border-left: 3px solid transparent; }
.node-card--online  { border-left-color: rgb(34 197 94);  }
.node-card--offline { border-left-color: rgb(239 68 68);  }
.node-card--degraded{ border-left-color: rgb(234 179 8);  }
```

O grid é responsivo sem media queries:
```css
.node-grid {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(280px, 1fr));
  gap: 1rem;
}
```

Isso é algo que eu faria exatamente igual no React. CSS é CSS — essa parte não mudou nada.

## Onde travei

### O ciclo de vida do LiveView

No React eu penso em: mount → render → effect → cleanup. No LiveView é:

1. `mount/3` — inicializa estado (equivalente ao `useState` + `useEffect([], ...)`)
2. `render/1` — retorna o template (equivalente ao `return <JSX>`)
3. `handle_event/3` — eventos do usuário (equivalente ao `onClick`, `onChange`, etc)
4. `handle_info/2` — mensagens do servidor (tipo um `onMessage` de WebSocket, mas interno)

O `handle_info` não tem equivalente direto no React. É onde o LiveView recebe mensagens PubSub, timers, etc. Demorei um pouco pra entender que esse é o mecanismo principal de reatividade — não eventos do DOM, mas mensagens entre processos do servidor.

### connected?/1

Outro detalhe: o `mount` é chamado DUAS vezes. Primeiro pra gerar o HTML estático (SEO, primeira pintura), depois pra conectar o WebSocket. Na segunda vez, `connected?(socket)` retorna `true`, e aí sim eu faço o `subscribe` no PubSub.

No Next.js eu teria esse mesmo padrão com SSR: o componente renderiza no servidor (sem acesso a browser APIs), e depois hidrata no client. Mas lá é explícito com `useEffect` — aqui precisa checar `connected?` manualmente.

### Entender por que não preciso de API

Essa foi a mudança mental mais difícil. No meu dia a dia com React + Node, eu:
1. Crio uma API REST (ou GraphQL)
2. O front faz fetch
3. Gerencio loading/error/data com React Query
4. Quando chega dado novo, preciso invalidar cache ou usar WebSocket

No LiveView, simplesmente não existe essa camada. O LiveView LÊ DO ETS DIRETAMENTE. Não tem fetch, não tem JSON, não tem loading state. O dado vai do ETS pro template em microsegundos. Isso simplifica muito, mas levei um tempo pra "desaprender" o padrão SPA.

## Diagrama do fluxo reativo completo

```
mount()
  |
  +- Phoenix.PubSub.subscribe("telemetry:updates")
  |
  +- TelemetryServer.all_node_states()  <-- lê ETS diretamente
       |
       v
    assigns: all_nodes, nodes (filtered), stats, search, filter, sort_field, sort_dir
       |
       v
    render() --> stats_bar + filter_bar + node-grid de node_cards

Heartbeat chega
  |
  v
TelemetryServer --- status mudou? --- SIM --> PubSub.broadcast {:status_change}
                                                  |
                                          handle_info/2 no DashboardLive
                                                  |
                                          atualiza all_nodes + reaplica filtros ativos
                                          (sem re-renderizar cards que não mudaram)

WriteBehindWorker --- flush a cada 5s --> PubSub.broadcast :dashboard_tick
                                                  |
                                          handle_info/2 no DashboardLive
                                                  |
                                          reload completo do ETS
                                          (atualiza event_count de todos os nós)
                                          reaplica filtros/sort ativos
```

## Verificação

```bash
mix phx.server
# Criar conta em http://localhost:4000/users/register
# Login redireciona automaticamente pra http://localhost:4000/dashboard

# Em outra janela, enviar heartbeats
for i in $(seq 1 5); do
  curl -s -X POST http://localhost:4000/api/v1/heartbeat \
    -H "Authorization: Bearer dev_secret_key" \
    -H "Content-Type: application/json" \
    -d "{\"machine_identifier\":\"sensor-$i\",\"status\":\"online\"}"
done

# Cards aparecem no dashboard em até 5s (dashboard_tick)
# Filtrar por status: clicar em "Online" mostra só os ativos
# Buscar: digitar "sensor-1" filtra em tempo real (debounce 300ms)

# Mudar status de um sensor pra ver atualização instantânea:
curl -X POST http://localhost:4000/api/v1/heartbeat \
  -H "Authorization: Bearer dev_secret_key" \
  -H "Content-Type: application/json" \
  -d '{"machine_identifier":"sensor-1","status":"offline"}'
# Badge muda de ONLINE pra OFFLINE na hora (PubSub :status_change)
# Contador "Offline" no filter_bar atualiza também
```
