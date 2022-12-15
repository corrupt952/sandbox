# Providers
provider "aws" {}

# Variables
variable "function_name" {
  type = string
  default = "lambda-typescript-example"
}

# Data
data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

data "aws_iam_policy_document" "this" {
  statement {
    actions = [
      "lambda:InvokeFunction",
    ]

    resources = [
      "arn:aws:lambda:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:function:${var.function_name}*"
    ]
  }

  statement {
    actions = [
      "logs:PutLogEvents",
    ]

    resources = [
      "${aws_cloudwatch_log_group.this.arn}:*",
    ]
  }
}

# Resources
resource "aws_iam_role" "this" {
  name = var.function_name

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = "sts:AssumeRole"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy" "this" {
  name   = "inline-policy"
  role   = aws_iam_role.this.id
  policy = data.aws_iam_policy_document.this.json
}

resource "aws_cloudwatch_log_group" "this" {
  name = "/aws/lambda/${var.function_name}"

  retention_in_days = 3
}

resource "null_resource" "lambroll" {
  triggers = {
    role_arn = aws_iam_role.this.arn
    hash = sha1(
      join("",
        [
          filesha1("function/package.json"),
          filesha1("function/package-lock.json"),
          filesha1("function/tsconfig.json"),
        ],
        [for f in fileset("function/src", "**"): filesha1("function/src/${f}")],
      )
    )
  }

  provisioner "local-exec" {
    command = "npm i && npm run deploy"
    working_dir = "function"
    environment = {
      LAMBDA_FUNCTION_NAME = var.function_name
      LAMBDA_DESCRIPTION = var.function_name
      LAMBDA_ROLE_ARN = aws_iam_role.this.arn
    }
  }
}
