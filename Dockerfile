# SPIRE doesn't publish a `:latest` tag upstream, so the version is a
# build-arg. CI discovers the latest stable release from GitHub and passes
# it in via `--build-arg SPIRE_VERSION=...`; local builds without that
# argument fall back to the default below. The image tag published by CI
# always matches the SPIRE version that was actually built in.
ARG SPIRE_VERSION=1.15.1
FROM ghcr.io/spiffe/spire-server:${SPIRE_VERSION} AS spire-server
FROM ghcr.io/spiffe/spire-agent:${SPIRE_VERSION}  AS spire-agent

FROM alpine:latest

LABEL org.opencontainers.image.title="spire-dev"
LABEL org.opencontainers.image.description="All-in-one SPIRE container for docker-compose dev environments"
LABEL org.opencontainers.image.source="https://github.com/paulo-raca/spire-dev"
# org.opencontainers.image.version is injected at build time by CI
# (docker/metadata-action), so it stays in sync with the image tag.

# jq converts SPIRE's SPIFFE bundle to plain JWKS for the /jwks.json
# endpoint; busybox-extras adds the `httpd` applet (the alpine base
# busybox package doesn't include it) which serves the file.
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
