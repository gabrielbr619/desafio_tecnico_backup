# Step 1 — Montando a base: Phoenix, SQLite e autenticação

## O que eu fiz

Esse primeiro passo foi basicamente o "create-next-app" do Elixir. Rodei `mix phx.new . --app w_core --database sqlite3 --no-mailer` e já ganhei um projeto inteiro com estrutura de pastas, roteamento, e até live reload. Lembrou bastante o scaffolding do Next.js, só que mais opinado — o Phoenix já vem com tudo conectado.

Depois gerei a autenticação com `mix phx.gen.auth Accounts User users`. Isso criou login, registro, confirmação de email, reset de senha... tudo pronto. No meu projeto principal (High Tide Systems) eu implementei auth do zero com JWT + bcrypt no Node, então ver isso pronto em um comando foi surreal.

Além disso, criei as tabelas do domínio de telemetria (`nodes` e `node_metrics`), o endpoint da API para receber heartbeats, e um plug de autenticação por Bearer token.

## O que eu aprendi

### mix é o npm do Elixir (mas faz mais coisa)

`mix deps.get` = `npm install`. `mix ecto.migrate` = `npx prisma migrate deploy`. `mix phx.server` = `npm run dev`. Até aí tranquilo. Mas o `mix` também compila, roda testes, gera código... é npm + npx + scripts tudo junto.

### Ecto me lembrou o Prisma

As schemas do Ecto são parecidas com os models do Prisma. Em vez de um `schema.prisma` centralizado, cada schema fica no seu arquivo `.ex` com os campos e tipos declarados. As migrations também são parecidas — arquivos com timestamp que rodam em ordem.

Uma coisa que me pegou: no Prisma com PostgreSQL eu tinha `@id @default(autoincrement())` e pronto. No Ecto com SQLite, o campo `:id` já é auto-increment por padrão, mas a sintaxe é diferente. Levei um tempo lendo a doc do `ecto_sqlite3` pra entender como configurar tudo.

### Contextos do Phoenix ≈ separação de módulos no Node

O Phoenix organiza o código em "contextos" — módulos que agrupam a lógica de negócio. Eu separei `Accounts` (auth, usuários) de `Telemetry` (nós, métricas) desde o começo. No meu projeto Node eu faço algo parecido com pastas tipo `modules/auth/`, `modules/patients/`, etc. A diferença é que no Phoenix isso é mais formalizado: cada contexto expõe funções públicas e esconde os detalhes internos.

## Onde travei

### Sintaxe funcional

A primeira hora foi estranha. Sem `let`, sem `const`, sem `for` loop clássico. Tudo é imutável por padrão, e o `=` não é atribuição — é pattern matching. Tipo:

```elixir
{:ok, user} = Accounts.register_user(attrs)
```

Parece destructuring do JavaScript (`const { ok, user } = ...`), mas se o lado esquerdo não "bater" com o direito, dá erro em runtime. Demorei pra internalizar isso.

### Configuração do SQLite

No Node eu usaria o `better-sqlite3` ou o Prisma com SQLite e pronto. Aqui precisei configurar o WAL mode (Write-Ahead Logging) manualmente no `config.exs`:

```elixir
config :w_core, WCore.Repo,
  journal_mode: :wal,
  cache_size: -64_000,
  busy_timeout: 5_000
```

O WAL mode é parecido com o WAL do PostgreSQL — permite leituras enquanto uma escrita acontece. Sem isso, o dashboard travaria toda vez que o WriteBehindWorker tentasse salvar no banco. O `busy_timeout` de 5s é tipo um retry automático em caso de lock (no SQLite só um processo pode escrever por vez).

## Decisões

### Por que SQLite e não PostgreSQL?

O briefing fala em "edge computing" — um servidor local na usina. SQLite roda embarcado, sem precisar de um serviço separado. É como ter o banco dentro da aplicação. Pro cenário descrito (single-instance, dados locais), faz mais sentido que subir um PostgreSQL. Eu uso PostgreSQL no dia a dia e gosto mais, mas aqui o SQLite é a ferramenta certa.

### ApiAuthPlug — Bearer token simples

Pra API de ingestão dos sensores, usei autenticação por Bearer token vindo de variável de ambiente. No Express eu faria um middleware assim:

```javascript
// Express
app.use('/api', (req, res, next) => {
  if (req.headers.authorization !== `Bearer ${process.env.API_KEY}`) {
    return res.status(401).json({ error: 'unauthorized' });
  }
  next();
});
```

No Phoenix, o equivalente é um "Plug" — um módulo que implementa `call/2`. O conceito é o mesmo (middleware), mas a nomenclatura é diferente.

### find_or_create_node — lidando com concorrência

Implementei um padrão GET → INSERT ON CONFLICT → GET pra lidar com dois sensores tentando se registrar ao mesmo tempo. No Prisma eu usaria `upsert`, aqui usei `on_conflict: :nothing` no insert e um segundo `get_by` se o insert não retornar nada. No final, o mesmo conceito — "cria se não existe, busca se já existe".

## Estrutura do projeto após esse passo

```
desafio_tecnico/
├── lib/
│   ├── w_core/
│   │   ├── accounts/          ← gerado pelo phx.gen.auth
│   │   │   ├── user.ex
│   │   │   ├── user_token.ex
│   │   │   └── scope.ex
│   │   ├── accounts.ex        ← contexto de autenticação
│   │   ├── telemetry/
│   │   │   ├── node.ex        ← schema dos nós (sensores)
│   │   │   └── node_metrics.ex ← schema das métricas
│   │   ├── telemetry.ex       ← contexto de persistência
│   │   └── repo.ex
│   └── w_core_web/
│       ├── plugs/
│       │   └── api_auth_plug.ex  ← middleware da API
│       ├── controllers/
│       │   ├── heartbeat_controller.ex
│       │   └── health_controller.ex
│       └── router.ex
└── priv/repo/migrations/
    ├── ..._create_users_auth_tables.exs
    ├── ..._create_nodes.exs
    └── ..._create_node_metrics.exs
```
