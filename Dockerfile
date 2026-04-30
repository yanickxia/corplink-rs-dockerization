# syntax=docker/dockerfile:1.6

# =============================================================================
# Multi-arch Dockerfile for corplink-rs
#
# corplink-rs only ships x86_64 linux pre-built binaries on its release page,
# so for multi-arch (amd64 + arm64) support we build from source here using
# Rust + Go (for libwg, which is a cgo wrapper around wireguard-go).
#
# Final image also bundles go-gost (https://github.com/go-gost/gost) so the
# VPN tunnel can be exposed as a SOCKS5 / HTTP proxy to other containers
# or hosts on the LAN.
# =============================================================================

# -----------------------------------------------------------------------------
# Stage 1: build corplink-rs from source
# -----------------------------------------------------------------------------
FROM --platform=$BUILDPLATFORM rust:1-bookworm AS corplink-builder

ARG TARGETPLATFORM
ARG TARGETARCH
ARG CORPLINK_REF=master

# Install cross-compilation toolchain + Go (needed for libwg)
RUN apt-get update && apt-get install -y --no-install-recommends \
        git ca-certificates build-essential pkg-config \
        clang llvm libclang-dev \
        gcc-aarch64-linux-gnu g++-aarch64-linux-gnu \
        wget curl \
    && rm -rf /var/lib/apt/lists/*

# Install Go (libwg requires go)
ARG GO_VERSION=1.22.5
RUN set -eux; \
    case "${BUILDPLATFORM:-linux/amd64}" in \
        linux/amd64) GOARCH=amd64 ;; \
        linux/arm64) GOARCH=arm64 ;; \
        *)           GOARCH=amd64 ;; \
    esac; \
    wget -qO- "https://go.dev/dl/go${GO_VERSION}.linux-${GOARCH}.tar.gz" | tar -C /usr/local -xz
ENV PATH=/usr/local/go/bin:/root/go/bin:$PATH
ENV GOPATH=/root/go

# Add rust target
RUN set -eux; \
    case "$TARGETARCH" in \
        amd64) RUST_TARGET=x86_64-unknown-linux-gnu ;; \
        arm64) RUST_TARGET=aarch64-unknown-linux-gnu ;; \
        *)     echo "unsupported arch: $TARGETARCH"; exit 1 ;; \
    esac; \
    echo "$RUST_TARGET" > /tmp/rust_target; \
    rustup target add "$RUST_TARGET"

WORKDIR /src
RUN git clone --recurse-submodules https://github.com/PinkD/corplink-rs.git . \
    && git checkout "${CORPLINK_REF}" \
    && git submodule update --init --recursive

# Build libwg (wireguard-go cgo wrapper). When cross-compiling to arm64 we
# set GOARCH/CC so wireguard-go's Makefile emits an aarch64 shared library.
RUN set -eux; \
    RUST_TARGET="$(cat /tmp/rust_target)"; \
    cd libwg; \
    case "$TARGETARCH" in \
        amd64) export GOARCH=amd64 CC=gcc ;; \
        arm64) export GOARCH=arm64 CC=aarch64-linux-gnu-gcc ;; \
    esac; \
    export CGO_ENABLED=1; \
    bash ./build.sh

# Build corplink-rs itself
RUN set -eux; \
    RUST_TARGET="$(cat /tmp/rust_target)"; \
    case "$TARGETARCH" in \
        amd64) \
            export CC_x86_64_unknown_linux_gnu=gcc; \
            export CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_LINKER=gcc; \
            ;; \
        arm64) \
            export CC_aarch64_unknown_linux_gnu=aarch64-linux-gnu-gcc; \
            export CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER=aarch64-linux-gnu-gcc; \
            export BINDGEN_EXTRA_CLANG_ARGS="--sysroot=/usr/aarch64-linux-gnu"; \
            ;; \
    esac; \
    cargo build --release --target "$RUST_TARGET"; \
    mkdir -p /out; \
    cp "target/${RUST_TARGET}/release/corplink-rs" /out/corplink-rs; \
    cp libwg/libwg.so /out/libwg.so

# -----------------------------------------------------------------------------
# Stage 2: fetch gost binary for the target arch
# -----------------------------------------------------------------------------
FROM --platform=$BUILDPLATFORM debian:bookworm-slim AS gost-fetcher

ARG TARGETARCH
ARG GOST_VERSION=3.2.6

RUN apt-get update && apt-get install -y --no-install-recommends wget ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN set -eux; \
    case "$TARGETARCH" in \
        amd64) GOST_ARCH=amd64v3 ;; \
        arm64) GOST_ARCH=arm64 ;; \
        arm)   GOST_ARCH=armv7 ;; \
        *)     echo "unsupported arch: $TARGETARCH"; exit 1 ;; \
    esac; \
    mkdir -p /out; \
    wget -qO- "https://github.com/go-gost/gost/releases/download/v${GOST_VERSION}/gost_${GOST_VERSION}_linux_${GOST_ARCH}.tar.gz" \
        | tar -C /out -xz gost

# -----------------------------------------------------------------------------
# Stage 3: final runtime image (debian-slim + s6)
# -----------------------------------------------------------------------------
FROM debian:bookworm-slim

LABEL org.opencontainers.image.source="https://github.com/yanickxia/corplink-rs-dockerization"
LABEL org.opencontainers.image.description="Dockerized PinkD/corplink-rs with a go-gost proxy sidecar"
LABEL org.opencontainers.image.licenses="GPL-2.0-or-later"

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        iproute2 iputils-ping \
        bind9-dnsutils \
        curl wget \
        procps \
        s6 \
    && rm -rf /var/lib/apt/lists/*

# Binaries produced by previous stages
COPY --from=corplink-builder /out/corplink-rs /app/corplink-rs
COPY --from=corplink-builder /out/libwg.so    /app/libwg.so
COPY --from=gost-fetcher     /out/gost        /app/gost

# libwg.so is linked with rpath=$ORIGIN, so placing it next to corplink-rs
# works. For safety, also expose it via LD_LIBRARY_PATH.
ENV LD_LIBRARY_PATH=/app

# s6 service definitions
COPY s6/           /etc/s6/
COPY scripts/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh /etc/s6/corplink/run /etc/s6/gost/run

WORKDIR /tmp

# Default proxy ports (overridable at runtime)
ENV GOST_SOCKS_PORT=1080 \
    GOST_HTTP_PORT=8080

EXPOSE 1080/tcp 8080/tcp

ENTRYPOINT ["/entrypoint.sh"]
CMD ["/usr/bin/s6-svscan", "/etc/s6"]
