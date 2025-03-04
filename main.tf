data "aws_caller_identity" "default" {
}

data "aws_region" "default" {
}

module "label" {
  source     = "git::https://github.com/cloudposse/terraform-null-label.git?ref=tags/0.14.1"
  enabled    = var.enabled
  namespace  = var.namespace
  name       = var.name
  stage      = var.stage
  delimiter  = var.delimiter
  attributes = var.attributes
  tags       = var.tags
}

resource "aws_s3_bucket" "default" {
  bucket = module.label.id
  acl    = "private"
  tags   = module.label.tags
}

resource "aws_iam_role" "default" {
  name               = module.label.id
  assume_role_policy = data.aws_iam_policy_document.assume.json
}

data "aws_iam_policy_document" "assume" {
  statement {
    sid = ""

    actions = [
      "sts:AssumeRole"
    ]

    principals {
      type        = "Service"
      identifiers = ["codepipeline.amazonaws.com"]
    }

    effect = "Allow"
  }
}

resource "aws_iam_role_policy_attachment" "default" {
  role       = aws_iam_role.default.id
  policy_arn = aws_iam_policy.default.arn
}

resource "aws_iam_policy" "default" {
  name   = module.label.id
  policy = data.aws_iam_policy_document.default.json
}

data "aws_iam_policy_document" "default" {
  statement {
    sid = ""

    actions = [
      "elasticbeanstalk:*",
      "ec2:*",
      "elasticloadbalancing:*",
      "autoscaling:*",
      "cloudwatch:*",
      "s3:*",
      "sns:*",
      "cloudformation:*",
      "rds:*",
      "sqs:*",
      "ecs:*",
      "iam:PassRole",
      "logs:PutRetentionPolicy",
      "logs:CreateLogGroup",
    ]

    resources = ["*"]
    effect    = "Allow"
  }
}

resource "aws_iam_role_policy_attachment" "s3" {
  role       = aws_iam_role.default.id
  policy_arn = aws_iam_policy.s3.arn
}

resource "aws_iam_policy" "s3" {
  name   = "${module.label.id}-s3"
  policy = data.aws_iam_policy_document.s3.json
}

data "aws_iam_policy_document" "s3" {
  statement {
    sid = ""

    actions = [
      "s3:GetObject",
      "s3:GetObjectVersion",
      "s3:GetBucketVersioning",
      "s3:PutObject",
    ]

    resources = [
      aws_s3_bucket.default.arn,
      "${aws_s3_bucket.default.arn}/*",
      "arn:aws:s3:::elasticbeanstalk*"
    ]

    effect = "Allow"
  }
}

resource "aws_iam_role_policy_attachment" "codebuild" {
  role       = aws_iam_role.default.id
  policy_arn = aws_iam_policy.codebuild.arn
}

resource "aws_iam_policy" "codebuild" {
  name   = "${module.label.id}-codebuild"
  policy = data.aws_iam_policy_document.codebuild.json
}

data "aws_iam_policy_document" "codebuild" {
  statement {
    sid = ""

    actions = [
      "codebuild:*",
    ]

    resources = [module.codebuild.project_id]
    effect    = "Allow"
  }
}

module "codebuild" {
  source                      = "git::https://github.com/drselump14/terraform-aws-codebuild.git?ref=master"
  namespace                   = var.namespace
  name                        = var.name
  stage                       = var.stage
  build_image                 = var.build_image
  build_compute_type          = var.build_compute_type
  buildspec                   = var.buildspec
  delimiter                   = var.delimiter
  attributes                  = concat(var.attributes, ["build"])
  tags                        = var.tags
  privileged_mode             = var.privileged_mode
  aws_region                  = signum(length(var.aws_region)) == 1 ? var.aws_region : data.aws_region.default.name
  aws_account_id              = signum(length(var.aws_account_id)) == 1 ? var.aws_account_id : data.aws_caller_identity.default.account_id
  image_repo_name             = var.image_repo_name
  image_tag                   = var.image_tag
  github_token                = var.github_oauth_token
  environment_variables       = var.environment_variables
  cache_type                  = var.codebuild_cache_type
  local_cache_modes           = var.codebuild_local_cache_modes
  cache_bucket_suffix_enabled = var.codebuild_cache_bucket_suffix_enabled
}

resource "aws_iam_role_policy_attachment" "codebuild_s3" {
  role       = module.codebuild.role_id
  policy_arn = aws_iam_policy.s3.arn
}

# Only one of the `aws_codepipeline` resources below will be created:

# "source_build_deploy" will be created if `var.enabled` is set to `true` and the Elastic Beanstalk application name and environment name are specified

# This is used in two use-cases:

# 1. GitHub -> S3 -> Elastic Beanstalk (running application stack like Node, Go, Java, IIS, Python)

# 2. GitHub -> ECR (Docker image) -> Elastic Beanstalk (running Docker stack)

# "source_build" will be created if `var.enabled` is set to `true` and the Elastic Beanstalk application name or environment name are not specified

# This is used in this use-case:

# 1. GitHub -> ECR (Docker image)

resource "aws_codepipeline" "source_build_deploy" {
  # Elastic Beanstalk application name and environment name are specified
  count    = var.enabled && signum(length(var.app)) == 1 && signum(length(var.env)) == 1 ? 1 : 0
  name     = module.label.id
  role_arn = aws_iam_role.default.arn

  artifact_store {
    location = aws_s3_bucket.default.bucket
    type     = "S3"
  }

  stage {
    name = "Source"

    action {
      name             = "Source"
      category         = "Source"
      owner            = "ThirdParty"
      provider         = "GitHub"
      version          = "1"
      output_artifacts = ["code"]

      configuration = {
        OAuthToken           = var.github_oauth_token
        Owner                = var.repo_owner
        Repo                 = var.repo_name
        Branch               = var.branch
        PollForSourceChanges = var.poll_source_changes
      }
    }
  }

  stage {
    name = "Build"

    action {
      name     = "Build"
      category = "Build"
      owner    = "AWS"
      provider = "CodeBuild"
      version  = "1"

      input_artifacts  = ["code"]
      output_artifacts = ["package"]

      configuration = {
        ProjectName = module.codebuild.project_name
      }
    }
  }

  stage {
    name = "Deploy"

    action {
      name            = "Deploy"
      category        = "Deploy"
      owner           = "AWS"
      provider        = "ElasticBeanstalk"
      input_artifacts = ["package"]
      version         = "1"

      configuration = {
        ApplicationName = var.app
        EnvironmentName = var.env
      }
    }
  }
}

resource "aws_codepipeline" "source_build" {
  count    = var.enabled && signum(length(var.app)) == 0 || signum(length(var.env)) == 0 ? 1 : 0
  name     = module.label.id
  role_arn = aws_iam_role.default.arn

  artifact_store {
    location = aws_s3_bucket.default.bucket
    type     = "S3"
  }

  stage {
    name = "Source"

    action {
      name             = "Source"
      category         = "Source"
      owner            = "ThirdParty"
      provider         = "GitHub"
      version          = "1"
      output_artifacts = ["code"]

      configuration = {
        OAuthToken           = var.github_oauth_token
        Owner                = var.repo_owner
        Repo                 = var.repo_name
        Branch               = var.branch
        PollForSourceChanges = var.poll_source_changes
      }
    }
  }

  stage {
    name = "Build"

    action {
      name     = "Build"
      category = "Build"
      owner    = "AWS"
      provider = "CodeBuild"
      version  = "1"

      input_artifacts  = ["code"]
      output_artifacts = ["package"]

      configuration = {
        ProjectName = module.codebuild.project_name
      }
    }
  }
}

############## Create AWS Webhook ##########################
resource "aws_codepipeline_webhook" "webhook" {
  count           = var.enabled && !var.poll_source_changes ? 1 : 0
  name            = "${local.codepipeline_id}-webhook"
  authentication  = "GITHUB_HMAC"
  target_action   = "Source"
  target_pipeline = "${local.codepipeline_id}"

  authentication_configuration {
    secret_token  = "${local.webhook_secret}"
  }

  filter {
    json_path     = "$.ref"
    match_equals  = "refs/heads/{Branch}"
  }
}
#############################################################

############## Create Github Webhook ##########################
resource "random_string" "webhook_secret" {
  length = 32

  # Special characters are not allowed in webhook secret (AWS silently ignores webhook callbacks)
  special = false
}

locals {
  webhook_secret  = "${join("", random_string.webhook_secret.*.result)}"
  webhook_url     = "${join("", aws_codepipeline_webhook.webhook.*.url)}"
  codepipeline_id = coalesce(join("", aws_codepipeline.source_build.*.id), join("", aws_codepipeline.source_build_deploy.*.id))
}

provider "github" {
  token        = var.github_oauth_token
  organization = var.repo_owner
}

resource "github_repository_webhook" "default" {
  count           = var.enabled && !var.poll_source_changes ? 1 : 0
  repository = var.repo_name

  configuration {
    url          = "${local.webhook_url}"
    content_type = "json"
    secret       = "${local.webhook_secret}"
    insecure_ssl = false
  }

  events = ["push"]
}
#############################################################

