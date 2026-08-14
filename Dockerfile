# gbrain MCP server for Gravitas.
#
# Why the clone+link install and not `bun install -g github:garrytan/gbrain`:
# Bun blocks gbrain's top-level postinstall on global installs (upstream #218),
# which leaves the PGLite WASM asset unpacked. The global install then fails at
# first use with:
#   Cannot find module '../../node_modules/@electric-sql/pglite/dist/pglite.wasm'
# so `gbrain init` can never create a brain. Verified on this base image, 14 Aug
# 2026. The clone + `bun link` path is upstream's documented fallback and is the
# only one that produces a working brain here. Do not "simplify" this back.
FROM oven/bun:1

RUN apt-get update \
 && apt-get install -y --no-install-recommends git ca-certificates \
 && rm -rf /var/lib/apt/lists/*

# Pin the upstream ref. `latest-stable` is upstream's moving pointer; override
# with a version tag (e.g. v0.45.12.0) for a reproducible rebuild.
ARG GBRAIN_REF=latest-stable
RUN git clone --depth 1 --branch "${GBRAIN_REF}" \
      https://github.com/garrytan/gbrain.git /opt/gbrain

WORKDIR /opt/gbrain
RUN bun install && bun link

# GBRAIN_HOME relocates the brain off $HOME so it can live on the Coolify
# volume -- verified: with GBRAIN_HOME=/data the brain lands at /data/.gbrain
# and nothing is written to /root. Everything outside the mount dies on redeploy.
ENV GBRAIN_HOME=/data \
    GBRAIN_NO_ONBOARD_NUDGE=1 \
    GBRAIN_PORT=3131

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

EXPOSE 3131
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
