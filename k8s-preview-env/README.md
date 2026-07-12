# Preview Environment on Kubernetes

Verify that ArgoCD ApplicationSet (PR Generator + Plugin Generator) can automatically create per-PR preview environments with multi-namespace isolation.

## Components

* Ory Hydra ... ID platform (OAuth2/OIDC)
* sample-app ... Simple web app that delegates auth to Hydra
* plugin-generator ... HTTP service for same-name branch resolution across repos

## Prerequisites

* Kubernetes cluster running locally
* kubectl

## Verification Steps

### Stage 1: Plugin Generator standalone (no push required)

```bash
cd k8s-preview-env/plugin-generator
GITHUB_OWNER=corrupt952 REPOS=sandbox go run main.go &

curl -s -X POST http://localhost:8080/api/v1/getparams.execute \
  -H 'Content-Type: application/json' \
  -d '{"parameters":{"branch":"main","branch_slug":"main","number":"101","head_sha":"abc1234"}}'
```

### Stage 2: ArgoCD Application with multi-namespace deployment (push required)

```bash
bash setup.sh
kubectl apply -f test-application.yaml

# Verify
kubectl get ns | grep preview-test
kubectl get deploy -n preview-test-hydra
kubectl get deploy -n preview-test-sample-app
```

### Stage 3: ApplicationSet + PR Generator E2E (push + PR required)

```bash
kubectl apply -f applicationset.yaml

# Open a PR on GitHub, then verify
kubectl get applications -n argocd
kubectl get ns | grep preview
```
