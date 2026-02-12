ARG CADDY_VERSION=2.10.2
ARG CADDY_DOCKER_PROXY_VERSION=v2.9.2
ARG CLOUDFLARE_DNS_VERSION=v0.2.3

FROM caddy:${CADDY_VERSION}-builder AS builder

ARG CADDY_DOCKER_PROXY_VERSION
ARG CLOUDFLARE_DNS_VERSION

RUN xcaddy build \
    --with github.com/lucaslorentz/caddy-docker-proxy/v2@${CADDY_DOCKER_PROXY_VERSION} \
    --with github.com/caddy-dns/cloudflare@${CLOUDFLARE_DNS_VERSION}

FROM caddy:${CADDY_VERSION}-alpine

COPY --from=builder /usr/bin/caddy /usr/bin/caddy

CMD ["caddy", "docker-proxy"]
