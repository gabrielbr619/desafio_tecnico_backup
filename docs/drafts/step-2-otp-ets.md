# Step 2 — GenServer, ETS e Write-Behind: a parte que mais me assustou

## O que eu fiz

Esse foi o passo que mais me tirou da zona de conforto. Diferente do step 1 (que tinha bastante paralelo com o que eu já faço), aqui eu entrei num território que não conhecia: OTP, GenServer, ETS. Levei um tempo lendo docs e exemplos antes de conseguir escrever algo que funcionasse.

No final, implementei:
- `TelemetryServer` — um GenServer que recebe heartbeats via `cast` e escreve no ETS
- `WriteBehindWorker` — um worker que periodicamente lê o ETS e persiste no SQLite
- `WCore.Telemetry.Supervisor` — o processo que supervisiona os dois acima
- Depois, como extensão pra suportar o histórico na interface: `StatusEvent` (loga mudanças de status) e `HeartbeatLog` (loga os últimos N payloads por nó)

## Paralelos com o que eu já conhecia

### GenServer — um worker com estado próprio

No começo eu não sabia o que era um GenServer. Li a doc e a analogia que fez sentido pra mim foi: é como uma classe JavaScript com um loop de eventos próprio, onde as mensagens são enfileiradas e processadas uma por vez.

Se eu fosse resolver isso no Node.js, provavelmente usaria uma fila em memória ou um worker thread. O GenServer faz isso de forma mais estruturada:

```elixir
def handle_cast({:heartbeat, node_id, status, payload}, state) do
  # aqui eu sei que nenhuma outra mensagem está sendo processada ao mesmo tempo
  :ets.update_counter(@table, node_id, {@pos_count, 1})
  {:noreply, state}
end
```

A coisa que me chamou atenção: eu não preciso me preocupar com mutex ou lock. A BEAM garante que as mensagens são processadas uma por vez. No Node eu teria que me preocupar se dois requests chegassem ao mesmo tempo e tentassem incrementar o mesmo contador.

### ETS — um Redis que vive dentro da aplicação

Quando li sobre ETS, a primeira coisa que veio na cabeça foi: "é basicamente um Redis, mas sem sair do processo". No High Tide Systems eu uso Redis pra guardar dados quentes que precisam de acesso rápido. ETS é a mesma ideia, só que sem latência de rede e sem precisar de um serviço externo.

A sintaxe é a parte estranha — `:ets.new`, `:ets.insert`, `:ets.lookup`. Aquele `:` na frente é chamada a módulo Erlang, não Elixir. É como se no meio do TypeScript você chamasse uma função C via FFI. Funciona, mas a documentação é a do Erlang, que tem um estilo bem diferente do que eu estava acostumado.

### PubSub — as rooms do Socket.io

Esse eu entendi rápido porque o conceito é idêntico ao que uso com Socket.io:

```javascript
// Socket.io — o que eu faria
io.to('clinic:updates').emit('appointment:changed', data);
```

```elixir
# Phoenix — o equivalente
Phoenix.PubSub.broadcast(WCore.PubSub, "telemetry:updates", {:status_change, node_id, status, ts})
```

Quem está "escutando" aquele tópico recebe a mensagem. A diferença é que no LiveView quem escuta é um processo no servidor, não o browser. O framework cuida de levar o dado até o browser via WebSocket.

## Onde eu travei (de verdade)

### A API do ETS é estranha

Passei um tempo considerável entendendo as opções do `:ets.new`. O que eu queria era uma tabela que qualquer processo pudesse ler (o LiveView lê direto, sem passar pelo GenServer), e que fosse rápida pra leitura concorrente.

Descobri que precisava de `:public` (qualquer processo pode ler/escrever) e `{:read_concurrency, true}` (otimiza pro caso de muitos leitores simultâneos). Também aprendi a diferença entre `:set` (como um `Map` — lookup por chave é O(1)) e `:ordered_set` (como uma árvore ordenada, O(log n)). Como minha operação mais comum é "busca por node_id", fui de `:set`.

Não escolhi isso porque sou especialista — escolhi porque li a documentação, entendi os tradeoffs e pareceu a opção mais óbvia pro caso de uso.

### handle_cast vs handle_call

Demorei pra entender quando usar cada um. `cast` é fire-and-forget (quem chamou não espera resposta). `call` é síncrono.

O dilema prático: quando um sensor envia um heartbeat, ele precisa esperar o ETS ser atualizado antes de receber o 200? Concluí que não — o controller já confirma o recebimento do request HTTP. O GenServer pode processar em background. Então `cast`.

Mas quando o `WriteBehindWorker` precisa saber se o flush terminou (especialmente nos testes), aí `call`. Criei um `flush_now/0` que usa `call` justamente pra isso.

### Entendendo por que o Supervisor importa

No começo eu não entendi pra que servia o Supervisor. "Se o processo crasha, reinicia." Ok, mas por quê isso importa?

A virada foi entender que o ETS pertence ao `TelemetryServer`. Se ele morrer, a tabela ETS vai junto. Se o `WriteBehindWorker` continuar rodando depois disso, vai tentar ler uma tabela que não existe mais — erro.

Por isso a estratégia do supervisor é `:rest_for_one`: se o `TelemetryServer` morrer, reinicia ele E tudo que veio depois (o `WriteBehindWorker`). Diferente de `:one_for_one` (reinicia só quem morreu). Isso me lembrou as restart policies do Docker Compose, onde a ordem dos serviços importa.

### O flush híbrido — descobri isso lendo um blog post

O `WriteBehindWorker` faz flush a cada 5 segundos. Mas e se chegar 10.000 eventos em 1 segundo? Ficar esperando 5s com tudo na memória parece ruim.

Li sobre "write-behind with threshold" num post sobre arquitetura de cache e implementei: se acumular mais de 500 eventos "sujos" (marcados pelo GenServer via `mark_dirty/1`), faz flush antes dos 5s. É basicamente um debounce com `maxWait` — conceito que uso em front-end com lodash, aplicado a persistência.

## Extensões que adicionei pra suportar a interface

Depois de terminar o Write-Behind, percebi que a página de detalhe do nó ficaria vazia — só mostraria o último payload. Queria mostrar um histórico.

Adicionei duas tabelas extras fora do fluxo Write-Behind:
- `status_events` — registra cada mudança de status (online → offline, etc.)
- `heartbeat_logs` — guarda os últimos 50 payloads por nó (com limpeza automática)

Essas duas tabelas são escritas de forma diferente do `node_metrics`: não passam pelo ETS, vão direto pro SQLite via `Task.start` (async, sem bloquear o GenServer). Faz sentido porque são logs append-only, não hot state que precisa de cache.

## O fluxo completo

```
Sensor (HTTP POST)
     |
     v
HeartbeatController
     | find_or_create_node/2 (SQLite — busca ou cria o nó)
     | process_heartbeat/3   (GenServer.cast — não bloqueia o request)
     v
TelemetryServer (GenServer)
     |
     |-- :ets.update_counter  --- incremento atômico do event_count
     |-- :ets.update_element  --- atualiza status/payload/timestamp
     |-- mark_dirty()         --- sinaliza pro WriteBehindWorker
     |-- PubSub.broadcast     --- SEMPRE pro tópico do nó (payload history)
     +-- PubSub.broadcast     --- só quando o STATUS MUDA (dashboard global)
     |
     +-- Task.start: log_heartbeat/3  --- histórico de payloads (SQLite direto)
     +-- Task.start: log_status_change/3  --- só em mudança de status
              |
              v
     :w_core_telemetry_cache (ETS)
              |
     WriteBehindWorker (flush a cada 5s ou 500 eventos)
              |
              v
     SQLite node_metrics (upsert em lote)
```

## Verificação

```bash
mix phx.server

# Enviar heartbeat
curl -X POST http://localhost:4000/api/v1/heartbeat \
  -H "Authorization: Bearer dev_secret_key" \
  -H "Content-Type: application/json" \
  -d '{"machine_identifier":"sensor-001","status":"online","payload":{"temp":42,"rpm":1200}}'

# Ver o ETS direto no IEx
iex -S mix
:ets.tab2list(:w_core_telemetry_cache)
# [{1, "online", 1, "{\"temp\":42,\"rpm\":1200}", #DateTime<...>}]

# Esperar ~5s e verificar o SQLite
WCore.Repo.all(WCore.Telemetry.NodeMetrics)
# [%NodeMetrics{node_id: 1, status: "online", total_events_processed: 1, ...}]
```
