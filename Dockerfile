# Single source of truth for the upstream SPIRE version this image tracks.
# Bump this, tag a matching v<version> release, and CI publishes
# paulocosta56/spire-dev:<version>.
ARG SPIRE_VERSION=1.13.0

FROM ghcr.io/spiffe/spire-server:${SPIRE_VERSION} AS spire-server
FROM ghcr.io/spiffe/spire-agent:${SPIRE_VERSION}  AS spire-agent

FROM alpine:3.20

ARG SPIRE_VERSION
LABEL org.opencontainers.image.title="spire-dev"
LABEL org.opencontainers.image.description="All-in-one SPIRE container for docker-compose dev environments"
LABEL org.opencontainers.image.source="https://github.com/paulo-raca/spire-dev"
LABEL org.opencontainers.image.version="${SPIRE_VERSION}"
LABEL io.spiffe.spire.version="${SPIRE_VERSION}"

# jq converts SPIRE's SPIFFE bundle to plain JWKS for the /jwks.json
# endpoint; busybox-extras adds the `httpd` applet (the alpine base busybox
# package doesn't include it) which serves the file.
RUN apk add --no-cache jq busybox-extras

COPY --from=spire-server /opt/spire/bin/spire-server /opt/spire/bin/spire-server
COPY --from=spire-agent  /opt/spire/bin/spire-agent  /opt/spire/bin/spire-agent

COPY server.conf.tmpl /etc/spire/server.conf.tmpl
COPY agent.conf.tmpl  /etc/spire/agent.conf.tmpl
COPY run.sh           /usr/local/bin/run.sh
COPY jwks-publish.sh  /usr/local/bin/jwks-publish.sh
RUN chmod +x /usr/local/bin/run.sh /usr/local/bin/jwks-publish.sh

ENV SPIRE_TRUST_DOMAIN=""
ENV SPIRE_WORKLOADS=""
ENV SPIRE_WORKLOAD_LABEL="io.spiffe.workload"
ENV SPIRE_JWKS_PORT="8080"

EXPOSE 8080
VOLUME ["/run/spire/sockets"]

HEALTHCHECK --interval=3s --timeout=2s --retries=20 --start-period=30s \
  CMD wget -qO- http://127.0.0.1:9091/ready >/dev/null 2>&1 \
   && wget -qO- http://127.0.0.1:9092/ready >/dev/null 2>&1

ENTRYPOINT ["/usr/local/bin/run.sh"]
