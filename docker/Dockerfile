# syntax=docker/dockerfile:1
# ---- build: the only place Swift exists ----
FROM swift@sha256:7060a792f4cd9eaa0d00826d941cec00ab8d252d33b8b28bc8e105f51f2dba73 AS build
WORKDIR /src
COPY Package.swift Package.resolved ./
RUN swift package resolve
COPY Sources Sources
COPY Tests Tests
RUN swift build -c release --product sneekd --static-swift-stdlib \
 && install -D "$(swift build -c release --show-bin-path)/sneekd" /out/sneekd

# ---- clients: fetched with tools that never reach the final image ----
FROM debian@sha256:3783cc01769c7b2b1b83a5c5ad96c815348e28ed7da68e2e3687004faa906251 AS repos
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl gnupg \
 && install -d /out/keyrings /out/sources \
 && curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor -o /out/keyrings/pgdg.gpg \
 && curl -fsSL https://pgp.mongodb.com/server-8.0.asc | gpg --dearmor -o /out/keyrings/mongodb.gpg \
 && echo "deb [signed-by=/usr/share/keyrings/pgdg.gpg] https://apt.postgresql.org/pub/repos/apt bookworm-pgdg main" > /out/sources/pgdg.list \
 && echo "deb [signed-by=/usr/share/keyrings/mongodb.gpg] https://repo.mongodb.org/apt/debian bookworm/mongodb-org/8.0 main" > /out/sources/mongodb.list

# ---- runtime ----
FROM debian@sha256:3783cc01769c7b2b1b83a5c5ad96c815348e28ed7da68e2e3687004faa906251
ARG PG_CLIENT_VERSION=17
# Exact package versions, pinned from the first successful build.
ARG PG_CLIENT_PKG_VERSION=17.11-1.pgdg12+2
ARG MONGOSH_PKG_VERSION=2.12.0
# 6.1.1 exists on PyPI only as a macOS-arm64 build; 6.1.3 is the newest generic 6.1.x
# (the Cassandra 4.1 line — 6.2.x is built against 5.0 and warns against a 4.1 server).
ARG CQLSH_VERSION=6.1.3
# bookworm-slim ships no CA bundle, so apt cannot reach the HTTPS PGDG/MongoDB repos
# until ca-certificates is in place — install it before their lists are added.
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates \
 && rm -rf /var/lib/apt/lists/*
COPY --from=repos /out/keyrings/ /usr/share/keyrings/
COPY --from=repos /out/sources/ /etc/apt/sources.list.d/
RUN apt-get update \
 && apt-get install -y --no-install-recommends procps python3 python3-pip \
      postgresql-client-${PG_CLIENT_VERSION}=${PG_CLIENT_PKG_VERSION} \
      mongodb-mongosh=${MONGOSH_PKG_VERSION} \
 && pip3 install --no-cache-dir --break-system-packages cqlsh==${CQLSH_VERSION} \
 && apt-get purge -y python3-pip && apt-get autoremove -y \
 && rm -rf /var/lib/apt/lists/* /etc/apt/sources.list.d/pgdg.list /etc/apt/sources.list.d/mongodb.list \
 && groupadd -g 2001 sneek && groupadd -g 2100 sneeksock \
 # Foundation on Linux resolves the home directory from this passwd entry, not $HOME.
 && useradd -u 2001 -g sneek -G sneeksock -M -d /var/lib/sneek -s /usr/sbin/nologin sneek \
 && install -d -o sneek -g sneek -m 0700 /var/lib/sneek \
 # The audit log's mount point, owned by the daemon: a named volume mounted over an
 # existing directory copies its ownership, so no chown of a fresh volume is needed.
 && install -d -o sneek -g sneek -m 0700 /var/lib/sneek-audit \
 && install -d -o sneek -g sneeksock -m 2770 /run/sneek \
 && install -d -o root -g root -m 0755 /etc/sneek/commands
COPY --from=build /out/sneekd /usr/local/bin/sneekd
COPY --chmod=0755 docker/entrypoint.sh docker/healthcheck.sh /usr/local/bin/
USER sneek
ENV HOME=/var/lib/sneek
ENV SNEEK_LOG_STDERR=1
# Turns on the entrypoint's fail-fast: this image never starts a daemon whose config
# lacks restrict_socket: true and require_readonly_prod: true.
ENV SNEEK_SERVER=1
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
HEALTHCHECK --interval=60s --timeout=90s --start-period=30s --retries=3 CMD ["/usr/local/bin/healthcheck.sh"]
