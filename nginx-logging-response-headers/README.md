# nginx-logging-response-headers

Logs an upstream response header in nginx while hiding that header from the
client. The upstream is a small Go server that sets `X-Time` (current RFC3339
timestamp) on every response; nginx strips it with `proxy_hide_header 'X-Time'`
but still records it in an LTSV-format access log via `$upstream_http_x_time`.

## How to verify

1. Start the containers: `docker compose up`
2. Request the app directly and confirm the response **includes** `X-Time`:
   `curl -i http://localhost:8001/`
3. Request via nginx and confirm the response **does not include** `X-Time`:
   `curl -i http://localhost:8000/`
4. Check the nginx access log and confirm `x_time` is populated:
   `docker compose exec nginx cat /var/log/nginx/access.log`

## Notes

- `app/main.go` has no `go.mod`; on a current `golang:alpine` image,
  `go run main.go` may fail without module initialization.
