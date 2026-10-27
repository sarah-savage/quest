# ──────────────────────────────────────────────────────────────
# GitHub Actions — OIDC push role for ECR
#
# Lets the GitHub Actions workflow in sarah-savage/quest exchange its OIDC
# token for short-lived STS credentials that can push to the quest ECR
# repository, so no long-lived AWS access keys are stored in GitHub.
#
# Unlike tfc-oidc.tf this needs no bootstrap: TFC's apply role creates it.
# ──────────────────────────────────────────────────────────────

resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]

  # No thumbprint_list: AWS validates GitHub's IdP against its own trusted CAs.

  tags = local.tags
}

resource "aws_iam_role" "github_actions_push" {
  name        = "QuestGitHubActionsPush"
  description = "GitHub Actions ECR push role for sarah-savage/quest master"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = aws_iam_openid_connect_provider.github.arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        # The master branch only: the repo is a public fork, so workflows from
        # pull requests and other branches or tags get no push credentials.
        #
        # The repo issues immutable subject claims, which carry the owner and
        # repo IDs (`gh api repos/sarah-savage/quest/actions/oidc/customization/sub`
        # → sub_claim_prefix), so a renamed or re-created repo of the same name
        # cannot match. The plain repo:sarah-savage/quest:… form is never sent.
        Condition = {
          StringEquals = {
            "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
            "token.actions.githubusercontent.com:sub" = "repo:sarah-savage@112581092/quest@1435536201:ref:refs/heads/master"
          }
        }
      },
    ]
  })

  tags = local.tags
}

# Push to the one quest repository, plus the account-wide auth token call
# (GetAuthorizationToken does not support resource-level permissions).
resource "aws_iam_role_policy" "github_actions_push" {
  name = "QuestEcrPush"
  role = aws_iam_role.github_actions_push.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "EcrAuthToken"
        Effect   = "Allow"
        Action   = "ecr:GetAuthorizationToken"
        Resource = "*"
      },
      {
        Sid    = "EcrPushQuest"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:PutImage",
          "ecr:BatchGetImage",
          "ecr:GetDownloadUrlForLayer",
        ]
        Resource = aws_ecr_repository.quest.arn
      },
    ]
  })
}

output "github_actions_push_role_arn" {
  description = "Role ARN for aws-actions/configure-aws-credentials (role-to-assume) in the quest workflow."
  value       = aws_iam_role.github_actions_push.arn
}
