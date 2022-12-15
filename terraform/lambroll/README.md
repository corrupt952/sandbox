# Terraform + lambroll + Node.js lambda

## Setup

1. Install Node.JS 16 or greater than
2. Install terraform and lambroll via [aqua](https://aquaproj.github.io/)[]
3. Configure AWS credentials

## Deploy

Execute `terraform apply`, then

- Create IAM and CloudWatch Log Group via Terraform
- Terraform's `local-exec` deploys the Lambda function using lambroll
