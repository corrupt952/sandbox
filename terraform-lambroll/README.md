# terraform-lambroll

Deploys a TypeScript Node.js Lambda by splitting responsibilities between
Terraform and [lambroll](https://github.com/fujiwara/lambroll): Terraform owns
the surrounding infrastructure (IAM role and CloudWatch Log Group), and a
`null_resource` with `local-exec` hands the function code deployment to
lambroll (`npm i && npm run deploy` in `function/`). The lambroll trigger
hashes `package.json`, `tsconfig.json`, and everything under `function/src/`,
so the function redeploys only when its inputs change.

## Setup

1. Install Node.js 16 or later
2. Install terraform and lambroll via [aqua](https://aquaproj.github.io/)
   (versions pinned in `aqua.yaml`)
3. Configure AWS credentials

## Deploy

```sh
terraform apply
```

This creates the IAM role and log group, then deploys the function
(`lambda-typescript-example`, region `ap-northeast-1`) via lambroll. The
function is bundled with `@vercel/ncc` and returns a static
`Hello from Lambda!` JSON response.

## Notes

- Creates real AWS resources (IAM, CloudWatch Logs, Lambda).
- Pinned versions are dated: `nodejs16.x` runtime (deprecated by AWS),
  lambroll v0.14.1, Terraform v1.3.6. The deploy region is hardcoded in
  `function/package.json` while the provider block sets none.
