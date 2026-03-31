# =============================================================================
# W-Core — Dockerfile para mix release
# Multi-stage: builder (Elixir completo) → runtime (Alpine mínimo)
# =============================================================================

# ---------------------------------------------------------------------------
# Stage 1: Builder
# ---------------------------------------------------------------------------
FROM hexpm/elixir:1.19.2-erlang-28.3.1-alpine-3.21.3 AS builder

# Ferramentas de build necessárias para NIFs (exqlite usa SQLite compilado)
RUN apk add --no-cache build-base git nodejs npm

WORKDIR /app

# Copia manifestos de dependências primeiro (melhor cache de camadas)
COPY mix.exs mix.lock ./
COPY config config

ENV MIX_ENV=prod

RUN mix local.hex --force && \
    mix local.rebar --force && \
    mix deps.get --only prod

# Compila dependências separadamente do código da aplicação
RUN mix deps.compile

# Copia o restante do código-fonte
COPY priv priv
COPY lib lib
COPY assets assets
COPY rel rel

# Build dos assets (Tailwind + esbuild) e da release
RUN mix assets.deploy && \
    mix compile && \
    mix release

# ---------------------------------------------------------------------------
# Stage 2: Runtime
# ---------------------------------------------------------------------------
FROM alpine:3.21.3 AS runtime

# Dependências mínimas de runtime para o BEAM
RUN apk add --no-cache libstdc++ libgcc ncurses-libs openssl

# Cria usuário não-root para segurança
RUN addgroup -S wcore && adduser -S wcore -G wcore

WORKDIR /app

# Copia a release compilada do stage anterior
COPY --from=builder --chown=wcore:wcore /app/_build/prod/rel/w_core ./

# Diretório para o banco SQLite — deve ser montado como volume em produção
RUN mkdir -p /data && chown wcore:wcore /data

# Copia script de entrypoint (roda migrações antes de iniciar)
COPY --chown=wcore:wcore rel/overlays/bin/entrypoint.sh /app/bin/entrypoint.sh
RUN chmod +x /app/bin/entrypoint.sh

USER wcore

ENV HOME=/app
ENV DATABASE_PATH=/data/w_core.db
ENV PHX_SERVER=true
ENV MIX_ENV=prod

EXPOSE 4000

CMD ["/app/bin/entrypoint.sh"]
