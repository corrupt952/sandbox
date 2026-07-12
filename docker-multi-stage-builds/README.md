# docker-multi-stage-builds

Demonstrates producing per-environment images (dev / staging / production) from a
single Dockerfile using named multi-stage build targets, with Redis on Alpine as
the example workload. All stages share a common `base` stage; each environment
stage layers its own tweaks on top (e.g. `dev` adds bash/vim and debug logging).

## How to run

```sh
# dev target via compose (Redis on localhost:6379)
docker compose up

# build a specific stage directly
docker build --target production -t redis-prod .
docker build --target staging -t redis-staging .
```

The companion GitHub Actions workflow
([github-actions-workflows/docker_multi_stage_build.yaml](../github-actions-workflows/docker_multi_stage_build.yaml),
retired from `.github/workflows/`) builds the `staging` and `production`
targets from this directory via a build matrix.

## Notes

- The `staging` stage is intentionally a no-op (identical to `base`).
- `production` also sets `loglevel debug` — kept simple for demonstration purposes.
