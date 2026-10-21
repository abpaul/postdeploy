FROM rust:1.99-slim-bookworm@sha256:53fcf8044a64eb36f8a6de6ff011c7e41f549730761e134e0a73ee3f02fc52e0 AS build
ARG TARGETARCH
RUN test "$TARGETARCH" = amd64
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates libssl-dev pkg-config && rm -rf /var/lib/apt/lists/*
WORKDIR /build
ENV RUSTUP_TOOLCHAIN=1.99.0 \
    CARGO_TARGET_DIR=/build/task-target \
    CARGO_PROFILE_DEV_DEBUG=0 \
    CARGO_PROFILE_TEST_DEBUG=0 \
    CARGO_PROFILE_RELEASE_DEBUG=0 \
    CARGO_PROFILE_RELEASE_STRIP=symbols
COPY . .
ENV CARGO_BUILD_JOBS=2
RUN --mount=type=cache,id=postdeploy-rust-registry,target=/usr/local/cargo/registry,sharing=locked \
    --mount=type=cache,id=postdeploy-rust-git,target=/usr/local/cargo/git,sharing=locked \
    --mount=type=cache,id=postdeploy-rust-1.99-amd64-target,target=/build/task-target,sharing=locked \
    cargo build --release --locked --bin postdeploy-cli \
    && cp /build/task-target/release/postdeploy-cli /build/postdeploy-cli

FROM debian:bookworm-slim@sha256:7c7b2c966bc9ee8cedfeef67e0e279108992c77681fa595db4a9d65c06ccc587
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates libssl3 && rm -rf /var/lib/apt/lists/* \
    && useradd --system --uid 10004 --home /app postdeploy \
    && mkdir -p /app /data && chown 10004:10004 /app /data
WORKDIR /app
ENV SQLITE_TMPDIR=/data/sqlite-tmp \
    MALLOC_ARENA_MAX=2
COPY --from=build /build/postdeploy-cli /usr/local/bin/postdeploy
COPY assets ./assets
COPY config ./config
COPY scripts/container-entrypoint.sh /usr/local/bin/container-entrypoint
ARG SOURCE_REVISION
RUN test -n "$SOURCE_REVISION"
LABEL org.opencontainers.image.revision=$SOURCE_REVISION
USER 10004:10004
EXPOSE 80
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --start-interval=5s --retries=3 \
    CMD ["/usr/local/bin/postdeploy", "healthcheck"]
ENTRYPOINT ["/usr/local/bin/container-entrypoint"]
CMD ["/usr/local/bin/postdeploy", "start", "--environment", "production"]
