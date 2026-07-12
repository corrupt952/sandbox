# sandbox

Personal sandbox repository — a collection of small, independent experiments.
Each directory is self-contained; see its README for details and setup.

## Experiments

| Directory | Description |
|-----------|-------------|
| [docker-cloud9](docker-cloud9/) | Legacy Cloud9 IDE (c9/core) built from source in a CentOS 7 container |
| [docker-golang-react](docker-golang-react/) | Full-stack sample: React (Vite) frontend + Go backend, dev hot-reload and a single production image |
| [docker-m1-elasticsearch](docker-m1-elasticsearch/) | Elasticsearch/Kibana OSS 6.8 on Apple Silicon via amd64 emulation, with Japanese analysis plugins |
| [docker-multi-stage-builds](docker-multi-stage-builds/) | Per-environment images (dev/staging/production) from one Dockerfile using named multi-stage targets |
| [docker-orion](docker-orion/) | Eclipse Orion 8.0 browser IDE in a CentOS 7 container |
| [docker-prometheus-grafana](docker-prometheus-grafana/) | Monitoring a Yamaha RTX1300 router with Prometheus + snmp_exporter + Grafana |
| [docker-run-and-exec-redirect-file](docker-run-and-exec-redirect-file/) | Feeding a local script to `docker run` / `docker exec` via stdin |
| [docker-unix-domain-socket](docker-unix-domain-socket/) | Nginx → Go app communication over a Unix domain socket shared through a compose volume |
| [envoy-http-front-envoy](envoy-http-front-envoy/) | Minimal Envoy front proxy in front of an nginx backend (HTTP/1.1) |
| [envoy-http-front-proxy-benchmark](envoy-http-front-proxy-benchmark/) | Benchmarking Envoy vs nginx as a front proxy with `wrk` |
| [mermaid-diagrams](mermaid-diagrams/) | Gallery of Mermaid diagram syntax samples |
| [nginx-logging-response-headers](nginx-logging-response-headers/) | Logging an upstream response header in nginx while hiding it from the client |
| [ruby-configurable](ruby-configurable/) | Layered per-environment settings in Rails with dry-configurable |
| [ruby-graceful-delayed](ruby-graceful-delayed/) | Graceful shutdown behavior of Delayed Job workers during long-running jobs |
| [ruby-oauth](ruby-oauth/) | Notion OAuth2 authorization-code flow in a minimal Sinatra app |
| [ruby-system-linkage](ruby-system-linkage/) | Syncing data between two Rails apps through a shared engine, JSON API, and a Sidekiq worker |
| [ruby-unicorn-timeout](ruby-unicorn-timeout/) | Unicorn worker timeout behavior behind nginx |
| [ruby-yamaha-diff](ruby-yamaha-diff/) | Dumping a Yamaha RTX router config over SSH-tunneled Telnet |
| [terraform-archive-file](terraform-archive-file/) | Zip creation patterns with Terraform's `archive_file` data source |
| [terraform-lambroll](terraform-lambroll/) | Deploying a TypeScript Lambda with Terraform (infra) + lambroll (function code) |

The workflows under [.github/workflows](.github/workflows/) are experiments themselves
(GitHub Actions concurrency control, `workflow_dispatch`, matrix multi-stage Docker builds,
path-filtered triggers) rather than CI for this repository.
