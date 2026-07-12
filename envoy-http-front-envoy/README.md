# envoy-http-front-envoy

Verifies a minimal Envoy front-proxy topology over HTTP/1.1:

```
Client --HTTP/1.1--> Envoy --HTTP/1.1--> nginx (HTTP/1.1 server)
```

Envoy listens on port 80 (published as 8000) and routes all paths to a stock
`nginx:stable-alpine` backend cluster. Based on
[envoyproxy/envoy examples/front-proxy](https://github.com/envoyproxy/envoy/tree/main/examples/front-proxy).

## How to run

```sh
docker-compose up -d
# open http://localhost:8000  (Envoy admin: http://localhost:8001)
```

## Notes

- When the backend speaks HTTP/1.1, use `http_protocol_options` on the cluster,
  not `http2_protocol_options`.
- Written against docker 18.09 / docker-compose 1.23 (2018). The pinned
  `envoyproxy/envoy-alpine` image and the legacy v1/v2 config style
  (`config:` instead of `typed_config`, `hosts:` instead of `load_assignment`)
  will not load on a modern Envoy without rewriting.
