# envoy-http-front-proxy-benchmark

Benchmarks Envoy vs nginx as a front proxy. Both proxies forward to the same
shared backend (a stock `nginx:stable-alpine` service), and each is load-tested
with [wrk](https://github.com/wg/wrk):

```
Client --HTTP/1.1--> Envoy --HTTP/1.1--> nginx (HTTP/1.1 server)   # port 8000
Client --HTTP/1.1--> nginx --HTTP/1.1--> nginx (HTTP/1.1 server)   # port 8001
```

## How to run

```sh
docker-compose up -d
wrk -t 10 -c 10 http://localhost:8000   # via Envoy
wrk -t 10 -c 10 http://localhost:8001   # via nginx
```

`wrk` must be installed on the host.

## Notes

- When the backend speaks HTTP/1.1, use `http_protocol_options` on the cluster,
  not `http2_protocol_options`.
- Written against docker 18.09 / docker-compose 1.23 (2018); the pinned Envoy
  image uses a legacy config schema that modern Envoy will not load.
- Known flaw: `dockerfiles/nginx/Dockerfile` copies `default.conf` to
  `/etc/nginx/default.conf`, but nginx only includes `/etc/nginx/conf.d/*.conf`.
  The nginx front proxy therefore serves its own welcome page instead of
  proxying to the backend, which skews the nginx side of the comparison.
