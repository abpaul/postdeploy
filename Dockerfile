# syntax=docker/dockerfile:1

FROM hexpm/elixir:1.20.3-erlang-29.0.5-debian-bookworm-20260803 AS build

RUN apt-get update -y && apt-get install -y --no-install-recommends build-essential git \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app

ENV MIX_ENV=prod

RUN mix local.hex --force && mix local.rebar --force
COPY mix.exs mix.lock ./
COPY config/config.exs config/prod.exs config/
RUN mix deps.get --only prod && mix deps.compile

COPY config/runtime.exs config/runtime.exs
COPY priv priv
COPY lib lib
COPY assets assets
# Compile first: the LiveView colocated JS/CSS is generated during `mix compile`
# and imported by assets.deploy (tailwind/esbuild resolve it via NODE_PATH into
# _build/$MIX_ENV/phoenix-colocated). Running assets.deploy before compile fails.
# `sentry.package_source_code` stores the source lines the Sentry SDK attaches
# to stack frames. It must run after compile and before release.
RUN mix compile --warnings-as-errors && mix sentry.package_source_code \
  && mix assets.deploy && mix release

FROM debian:bookworm-20261005-slim AS app

# ca-certificates: the mailer verifies the Cloudflare SMTP TLS chain at boot via
# :public_key.cacerts_get(), which reads the OS CA bundle. The slim image ships
# none, so the release refuses to boot without this.
RUN apt-get update -y && apt-get install -y --no-install-recommends libstdc++6 openssl ncurses-base ca-certificates curl \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app
RUN useradd --system --create-home --uid 1000 alplus
COPY --from=build --chown=alplus:alplus /app/_build/prod/rel/alplus ./

USER alplus
ENV LANG=C.UTF-8 \
    HOME=/app \
    PHX_SERVER=true \
    PORT=3000

EXPOSE 3000

CMD ["sh", "-c", "bin/alplus eval 'Alplus.Release.migrate()' && bin/alplus eval 'Alplus.Release.seed()' && exec bin/alplus start"]
