# docker-unix-domain-socket

Verifies that two docker-compose services can communicate over a Unix domain
socket shared through a named volume: a Go (Echo) server listens on
`/var/run/glaaki/glaaki.sock` instead of a TCP port, and nginx reverse-proxies
to that socket via an `upstream` block (`server unix:/var/run/glaaki/glaaki.sock`).

## How to run

```sh
docker compose up -d
# open http://localhost:8000
```

Only nginx publishes a port (8000 → 80); the Go app is reachable exclusively
through the socket.

## Notes

- Written against docker 18.09 / docker-compose 1.23 (2018). The Go app uses
  pre-modules `go get` with Echo v1 and has no `go.mod`, so it will not run
  on a current `golang:alpine` image without adjustments.
- The socket is created with mode `0500`, which works here only because both
  processes effectively run as root.
