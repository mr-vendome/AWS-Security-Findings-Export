terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.0"
    }
  }

  backend "s3" {
    bucket         = "security-findings-tfstate-550724411583"
    key            = "securityhub-exporter/terraform.tfstate"
    region         = "eu-west-1"
  }
}

provider "aws" {
  region = "eu-west-1"
}

#-------------------------------------------------------------------------------
# KMS Key Definition for Findings Export Bucket B
#-------------------------------------------------------------------------------
resource "aws_kms_key" "s3_export_key" {
  description             = "KMS Key for Security Hub findings export bucket encryption"
  deletion_window_in_days = 30
  enable_key_rotation     = true
}

#-------------------------------------------------------------------------------
# Bucket B: Export Target Configuration
#-------------------------------------------------------------------------------
resource "aws_s3_bucket" "findings_export" {
  bucket        = "aws-securityhub-cspm-exports-550724411583"
  force_destroy = false
}

resource "aws_s3_bucket_public_access_block" "findings_export" {
  bucket                  = aws_s3_bucket.findings_export.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "findings_export" {
  bucket = aws_s3_bucket.findings_export.id
  rule {
    apply_server_side_encryption_by_default {
      kms_master_key_id = aws_kms_key.s3_export_key.arn
      sse_algorithm     = "aws:kms"
    }
  }
}

# Configures Server Access Logging as defined in requirements
resource "aws_s3_bucket_logging" "findings_export_logging" {
  bucket        = aws_s3_bucket.findings_export.id
  target_bucket = "security-findings-tfstate-550724411583" # Logging to designated storage or centralized log bucket
  target_prefix = "s3-access-logs/aws-securityhub-cspm-exports/"
}

#-------------------------------------------------------------------------------
# Lambda Execution Role & Dedicated Least-Privilege Policies
#-------------------------------------------------------------------------------
resource "aws_iam_role" "lambda_execution" {
  name = "securityhub-cspm-exporter-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action    = "sts:AssumeRole"
        Effect    = "Allow"
        Principal = { Service = "lambda.amazonaws.com" }
      }
    ]
  })
}

resource "aws_iam_policy" "lambda_permissions" {
  name        = "securityhub-cspm-exporter-lambda-policy"
  description = "Allows execution runtime to access Security Hub findings, write to S3, and use KMS."

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = [ "securityhub:GetFindings" ]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = [ "s3:PutObject" ]
        Resource = [ "${aws_s3_bucket.findings_export.arn}/*" ]
      },
      {
        Effect   = "Allow"
        Action   = [
          "kms:Encrypt",
          "kms:GenerateDataKey*"
        ]
        Resource = [ aws_kms_key.s3_export_key.arn ]
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:*:*:*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_attach" {
  role       = aws_iam_role.lambda_execution.name
  policy_arn = aws_iam_policy.lambda_permissions.arn
}

#-------------------------------------------------------------------------------
# Lambda Engine (Python 3.14 / ARM64)
#-------------------------------------------------------------------------------
data "archive_file" "lambda_zip" {
  type        = "zip"
  source_file = "${path.module}/lambda_function.py"
  output_path = "${path.module}/lambda_function.zip"
}

resource "aws_lambda_function" "exporter" {
  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  function_name    = "securityhub-cspm-findings-exporter"
  role             = aws_iam_role.lambda_execution.arn
  handler          = "lambda_function.lambda_handler"
  
  runtime          = "python3.13"
  architectures    = ["arm64"]
  
  timeout          = 300
  memory_size      = 256

  environment {
    variables = {
      S3_BUCKET_NAME = aws_s3_bucket.findings_export.id
    }
  }
}

#-------------------------------------------------------------------------------
# EventBridge Automation Trigger Engine
#-------------------------------------------------------------------------------
resource "aws_cloudwatch_event_rule" "daily_trigger" {
  name                = "securityhub-cspm-export-schedule"
  description         = "Triggers the Security Hub export engine daily at 00:00 UTC."
  schedule_expression = "cron(0 0 * * ? *)"
}

resource "aws_cloudwatch_event_target" "lambda_target" {
  rule      = aws_cloudwatch_event_rule.daily_trigger.name
  target_id = "TriggerLambdaExporter"
  arn       = aws_lambda_function.exporter.arn
}

resource "aws_lambda_permission" "allow_eventbridge" {
  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.exporter.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.daily_trigger.arn
}
