# github-actions-workflows

GitHub Actions experiments. These workflows used to live in
`.github/workflows/`; they were moved here (out of the active path) once the
verification was done, so they no longer trigger.

## Workflows

- `workflow.yaml` — bare `workflow_dispatch` baseline job (checkout + sleep),
  the control case for the concurrency experiments.
- `concurrency-workflow.yaml` — cross-run mutual exclusion using the
  third-party [gh-action-mutex](https://github.com/ben-z/gh-action-mutex) action.
- `concurrency-workflow-2.yaml` — the same goal using GitHub's native
  `concurrency` block (`cancel-in-progress: false`, i.e. queueing).
- `docker_multi_stage_build.yaml` — builds the `staging` / `production` targets
  of [docker-multi-stage-builds](../docker-multi-stage-builds/) via a build
  matrix with QEMU + Buildx (build only; nothing is pushed).
- `trigger-check.yaml` — path-filtered `pull_request` trigger
  (`.github/**/*.yml`) that fetches the base ref and prints the changed files
  via `git diff --name-only`.

## How to use

Copy a workflow back into `.github/workflows/` to reactivate it. The
dispatch-based ones are run manually from the Actions tab.
