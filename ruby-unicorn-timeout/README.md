# ruby-unicorn-timeout

Verifies Unicorn's worker timeout behavior behind nginx.

## Configuration

- nginx proxy timeouts (`nginx/conf.d/default.conf`) ... `proxy_read_timeout 1s`,
  `proxy_send_timeout 3s`
- Unicorn timeout ... 3 seconds (`app/unicorn.conf`)
- Sleep inside the Rails controller ... 5 seconds
  (`app/app/controllers/top_controller.rb`)

## Verification steps

### With Unicorn's timeout set

Processing that exceeds the `timeout` value in Unicorn's config gets the worker
process killed.

1. Start the containers: `docker compose up -d`
2. Confirm the request times out: <http://127.0.0.1:8080>
3. Confirm Unicorn killed the worker: `docker compose logs app | grep killing`

### Without Unicorn's timeout

Unicorn's default timeout is around 30–60 seconds. Processing that exceeds it is
of course killed, but anything under it keeps running to completion — even after
the ALB/nginx in front has already returned a timeout to the client.

1. Comment out the `timeout` line: `vim app/unicorn.conf`
2. Restart: `docker compose restart`
3. Confirm the request times out: <http://127.0.0.1:8080>
4. Confirm Unicorn did **not** kill the worker:
   `docker compose logs app | grep killing`

As the chart below shows, when multiple slow requests queue up, processing
continues even after the ALB/nginx timeouts have fired:

```mermaid
gantt

dateFormat HH:mm:ss
axisFormat %H:%M:%S

section Request α
ALB : a1, 11:00:00, 60sec
Nginx : a2, 11:00:01, 60sec
Unicorn : a3, active, 11:00:02, 50sec

section Request β
ALB : b1, 11:00:30, 60sec
Nginx : b2, 11:00:31, 60sec
Unicorn : b3, after a3, 50sec
```

Assuming a single worker process: request α completes within the ALB/nginx
timeouts, but request β isn't processed until α finishes, so the user gets a
504. Real deployments run multiple processes, but the same reasoning applies.
