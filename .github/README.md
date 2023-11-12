# caddy-docker-proxy-cloudflare

[![Docker Image Version](https://img.shields.io/docker/v/jcdcdev/caddy-docker-proxy-cloudflare/latest)](https://hub.docker.com/r/jcdcdev/caddy-docker-proxy-cloudflare)
[![Docker Image Size](https://img.shields.io/docker/image-size/jcdcdev/caddy-docker-proxy-cloudflare/latest)](https://hub.docker.com/r/jcdcdev/caddy-docker-proxy-cloudflare)
[![GitHub issues](https://img.shields.io/github/issues/jcdcdev/caddy-docker-proxy-cloudflare)](https://github.com/jcdcdev/caddy-docker-proxy-cloudflare/issues)
[![GitHub last commit](https://img.shields.io/github/last-commit/jcdcdev/caddy-docker-proxy-cloudflare)](https://github.com/jcdcdev/caddy-docker-proxy-cloudflare/commits)
[![GitHub license](https://img.shields.io/github/license/jcdcdev/caddy-docker-proxy-cloudflare?color=8AB803)](../LICENSE) 

## Description

This is a Docker image for using Caddy as a reverse proxy for Docker containers, allowing you to easily expose multiple services on one or many domain names with automatic HTTPS encryption using Cloudflare.

The image is based on the official Caddy Docker image and includes the following plugins

- [caddy-dns/cloudflare](https://github.com/caddy-dns/cloudflare)
- [caddy-docker-proxy](https://github.com/lucaslorentz/caddy-docker-proxy)

## Why?

I have a Raspberry pi running docker with many services and I want a clean way to get a https reverse proxy up and running _without_ opening port 80 to the world.

## Requirements

- Docker 
- A domain name
  - DNS must be managed by Cloudflare - [Guide](https://developers.cloudflare.com/dns/zone-setups/full-setup/setup/)
- Cloudflare API key - [Guide](https://github.com/libdns/cloudflare#authenticating)

## Example Usage

Create a `docker-compose.yml` file with the following content:

```yml
version: "3.3"
networks:
  frontend:
    name: frontend
services:
  # Caddy set up
  caddy:
    image: jcdcdev/caddy-docker-proxy-cloudflare:latest
    ports:
      - 80:80
      - 443:443
    networks:
      - frontend
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - '~/caddy/data:/data'
    labels:
      caddy: (cftls)
      caddy.tls.dns: cloudflare "API-KEY-HERE"
      caddy.tls.resolvers: 1.1.1.1
  # Container that uses Caddy
  who:
    image: traefik/whoami
    networks:
      - frontend
    labels:
      caddy: who-am-i.my-domain.com
      caddy.reverse_proxy: "{{upstreams 80}}"
      caddy.import: cftls
```

## Contributing

Contributions to this image are most welcome! Please read the [Contributing Guidelines](CONTRIBUTING.md).

## Acknowledgments (thanks!)

- lucaslorentz - [caddy-docker-proxy](https://github.com/lucaslorentz/caddy-docker-proxy)
- caddy-dns - [caddy-dns/cloudflare](https://github.com/caddy-dns/cloudflare)