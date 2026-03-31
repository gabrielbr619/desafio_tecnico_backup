# Step 4 — Testes de caos: provando que nada se perde

## O que eu fiz

Escrevi testes pra provar que o sistema não perde dados sob carga pesada. O teste principal dispara 10.000 heartbeats concorrentes e verifica que todos foram contabilizados — tanto no ETS (memória) quanto no SQLite (disco).

- `TelemetryServerTest` — testes do GenServer: contagem atômica, PubSub
- `WriteBehindWorkerTest` — testes de flush síncrono e threshold
- `ConcurrencyTest` — teste de caos com 10.000 eventos simultâneos

Todos passam com `--seed 0` e `--seed 12345` (sem depender da ordem de execução).

## Como eu pensei nisso (vindo do Jest)

### Testes com processos vivos vs mocks

No Jest/Vitest com Node, eu mockaria tudo. Se precisasse testar que um worker processa eventos, faria algo tipo:

```javascript
jest.mock('./redis');
jest.mock('./database');
const worker = new Worker();
worker.process(event);
expect(redis.set).toHaveBeenCalledWith(...);
```

No Elixir, os processos estão VIVOS durante o teste. O GenServer está rodando de verdade, o ETS está lá, o WriteBehindWorker está fazendo flush de verdade. Não tem mock — é integração real.

Isso é mais confiável, mas trouxe desafios que eu não estava acostumado.

### async: false — o ETS é compartilhado

No Jest eu rodaria testes em paralelo sem pensar duas vezes (cada teste tem seu contexto isolado). Aqui não dá, porque todos os testes de telemetria leem e escrevem na mesma tabela ETS (`:w_core_telemetry_cache`). Se rodassem em paralelo, um teste poderia ver dados de outro.

A solução: `async: false` nos testes de telemetria. Os testes de auth e controllers continuam paralelos porque não tocam o ETS.

### IDs altos pra não colidir

```elixir
@node_base 900_000  # IDs de 900.000+ nos testes
```

No Jest eu usaria `faker` ou IDs aleatórios. Aqui usei IDs fixos e altos (900.000+) pra não colidir com dados de dev/seed. É mais simples e determinístico.

## O teste de caos: 10.000 eventos

Esse é o teste que prova que o `ets:update_counter` é realmente atômico:

```elixir
# 100 Tasks, cada uma envia 100 heartbeats pro MESMO nó
tasks = for _ <- 1..100 do
  Task.async(fn ->
    for _ <- 1..100 do
      TelemetryServer.process_heartbeat(node_id, "online", %{})
    end
  end)
end
Enum.each(tasks, &Task.await(&1, 30_000))

# Resultado: count TEM que ser exatamente 10.000
[{^node_id, _status, count, _payload, _ts}] = :ets.lookup(:w_core_telemetry_cache, node_id)
assert count == 10_000
```

Se o `update_counter` não fosse atômico, teríamos lost updates (dois processos leem 99, ambos escrevem 100 — perdeu um). A asserção `count == 10_000` prova que isso não acontece.

No Node.js, pra ter essa garantia eu precisaria de Redis com `INCR` (que também é atômico) ou um lock explícito. Aqui é uma linha.

## O teste de concorrência multi-nó

Esse testa o cenário mais realista: 1.000 nós diferentes, cada um recebendo 10 heartbeats:

```
1.000 Tasks
  |
  | cada Task envia 10 heartbeats pra 1 nó diferente
  | (total: 10.000 eventos simultâneos)
  |
  v
TelemetryServer
  |
  v
ETS
  |-- assert: 1.000 nós presentes
  |-- assert: cada nó tem count == 10
  |
WriteBehindWorker.flush_now()
  |
  v
SQLite node_metrics
  |-- assert: 1.000 linhas
  +-- assert: total_events_processed == 10 pra cada nó
```

## Onde travei

### flush_now — precisei de um flush síncrono

O WriteBehindWorker normalmente faz flush a cada 5s (1s em testes). Mas no teste eu preciso verificar o SQLite DEPOIS do flush. Se eu fizesse `Process.sleep(2000)`, o teste ficaria lento e frágil (e se o CI for mais devagar?).

A solução foi criar `flush_now/0` — um `GenServer.call` que faz o flush e só retorna quando terminar:

```elixir
assert :ok = WriteBehindWorker.flush_now()
# Agora posso verificar o SQLite com certeza de que o flush já aconteceu
```

No Jest eu não teria esse problema porque mockaria o timer. Mas como aqui o processo é real, precisei criar essa API de teste.

### Limpeza entre testes

No Jest eu tenho `beforeEach(() => jest.clearAllMocks())`. Aqui precisei limpar o ETS manualmente no `on_exit` do DataCase:

```elixir
on_exit(fn ->
  if :ets.whereis(:w_core_telemetry_cache) != :undefined do
    :ets.delete_all_objects(:w_core_telemetry_cache)
  end
end)
```

Demorei pra encontrar o `ets.whereis` — no começo tentava `ets.info` que retorna `:undefined` de um jeito diferente. A doc do Erlang ajudou, mas precisei de um tempo pra achar.

### FK constraints no flush

Um problema que apareceu nos testes: o `WriteBehindWorker` tentava salvar métricas pra `node_ids` que não existiam na tabela `nodes` (porque alguns testes inserem direto no ETS sem criar o nó no banco). Resultado: foreign key constraint error.

A solução foi filtrar os IDs válidos antes do upsert:

```elixir
valid_ids = Repo.all(from n in Node, select: n.id) |> MapSet.new()
metrics = entries |> Enum.filter(fn {id, _, _, _, _} -> MapSet.member?(valid_ids, id) end)
```

É um SELECT a mais por ciclo de flush (a cada 5s), totalmente aceitável. No Prisma eu resolveria com `skipDuplicates` ou um `WHERE EXISTS`, mas aqui a filtragem em memória é mais simples e o volume é pequeno.

### Task.start nos testes — falha silenciosa intencional

Depois de adicionar o histórico de payloads, o `TelemetryServer` passou a disparar dois `Task.start` por heartbeat:

```elixir
Task.start(fn -> Telemetry.log_heartbeat(node_id, status, payload) end)
Task.start(fn -> Telemetry.log_status_change(node_id, from, to) end)  # só em mudança
```

Nos testes unitários do `TelemetryServerTest`, os `node_ids` são inventados (`@node_base + 1`, etc.) e não existem na tabela `nodes`. Quando as Tasks tentam inserir em `heartbeat_logs` ou `status_events`, tomam FK constraint error e crasham.

Isso não quebra nenhum teste porque:
1. `Task.start` é fire-and-forget — o crash da Task não propaga pro processo do teste
2. Os testes unitários só fazem `assert` no ETS, não no banco
3. O teste de caos (`ConcurrencyTest`) cria os nós no banco antes de disparar heartbeats, então lá as Tasks funcionam normalmente

É basicamente o mesmo comportamento de um `Promise.catch(() => {})` no Node — você sabe que pode falhar em contexto de teste e decide ignorar porque não é o que está sendo testado.

## Configuração de teste

No `config/test.exs` reduzi os intervalos pra os testes não ficarem lentos:

```elixir
config :w_core,
  write_behind_interval_ms: 1_000,     # 1s em vez de 5s
  write_behind_dirty_threshold: 50      # 50 em vez de 500
```

## Resultados

```
mix test test/w_core/telemetry/ --trace

8 tests, 0 failures
Finished in ~6.4 seconds
```

Os 6.4 segundos são por causa do teste de 10k eventos — ele spawna muitas Tasks e espera todas terminarem. Os testes unitários rodam em milissegundos.
