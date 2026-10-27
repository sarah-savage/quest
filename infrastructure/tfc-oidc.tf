# ──────────────────────────────────────────────────────────────
# Terraform Cloud — dynamic credentials (OIDC)
#
# Lets the TFC `quest` workspace authenticate to AWS account 847323757682 by
# exchanging its workload identity token for short-lived STS credentials, so no
# long-lived access keys ever exist for Terraform.
#
# Enabled by three workspace ENV variables (not Terraform variables):
#   TFC_AWS_PROVIDER_AUTH  = true
#   TFC_AWS_PLAN_ROLE_ARN  = <arn of aws_iam_role.terraform_plan below>
#   TFC_AWS_APPLY_ROLE_ARN = <arn of aws_iam_role.terraform below>
#
# PLAN/APPLY SPLIT — a plan runs code from the repo (external data sources,
# providers), and the repo is a public fork, so the plan phase gets read-only
# credentials and only the apply phase, which runs after a human confirms the
# plan, gets admin. Each role trusts only its own run phase. Speculative plans
# are also off on the workspace.
#
# BOOTSTRAP — these roles cannot create themselves. TFC has no AWS credentials
# until a role exists, and the roles are what grant them. The OIDC provider,
# both roles and their policy attachments were therefore created by hand once
# with the AWS CLI and imported into state on the first run.
#
# The audience is fixed by TFC and must be exactly aws.workload.identity unless
# TFC_AWS_WORKLOAD_IDENTITY_AUDIENCE overrides it on the workspace.
# ──────────────────────────────────────────────────────────────

resource "aws_iam_openid_connect_provider" "tfc" {
  url            = "https://app.terraform.io"
  client_id_list = ["aws.workload.identity"]

  # SHA1 of the ROOT cert in the app.terraform.io chain, per AWS's documented
  # procedure. Verified against the live chain 2026-10-27: app.terraform.io is
  # served by Amazon (CN=app.terraform.io -> Amazon RSA 2048 M04 -> Amazon Root
  # CA 1), so this is the Amazon Root CA 1 thumbprint, NOT a Let's Encrypt or
  # DigiCert one. Re-derive with:
  #   openssl s_client -servername app.terraform.io -connect app.terraform.io:443 \
  #     -showcerts </dev/null 2>/dev/null | <take last cert> \
  #     | openssl x509 -noout -fingerprint -sha1
  thumbprint_list = ["06b25927c42a721631c1efd9431e648fa62e1e39"]

  tags = local.tags
}

# Apply phase only.
resource "aws_iam_role" "terraform" {
  name        = "RearcQuestTerraform"
  description = "TFC dynamic-credentials role for the rearc-quest workspace"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = aws_iam_openid_connect_provider.tfc.arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "app.terraform.io:aud" = "aws.workload.identity"
          }
          # Scoped to the apply phase of the `quest` workspace in TFC project
          # `AWS`. Renaming the workspace or moving it between projects breaks
          # this trust and every run will fail with AccessDenied.
          StringLike = {
            "app.terraform.io:sub" = "organization:Tailwinds:project:AWS:workspace:quest:run_phase:apply"
          }
        }
      },
    ]
  })

  tags = local.tags
}

# AdministratorAccess is deliberate: account 847323757682 exists only for the
# quest and is short-lived, and the trust above is scoped to the apply phase of
# the one workspace.
resource "aws_iam_role_policy_attachment" "terraform_admin" {
  role       = aws_iam_role.terraform.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

# Plan phase only — read-only, because a plan runs repo code (see header).
resource "aws_iam_role" "terraform_plan" {
  name        = "RearcQuestTerraformPlan"
  description = "TFC plan-phase role for the quest workspace"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = aws_iam_openid_connect_provider.tfc.arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "app.terraform.io:aud" = "aws.workload.identity"
          }
          # Scoped to the plan phase of the `quest` workspace in TFC project
          # `AWS`. Renaming the workspace or moving it between projects breaks
          # this trust and every run will fail with AccessDenied.
          StringLike = {
            "app.terraform.io:sub" = "organization:Tailwinds:project:AWS:workspace:quest:run_phase:plan"
          }
        }
      },
    ]
  })

  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "terraform_plan_readonly" {
  role       = aws_iam_role.terraform_plan.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

output "tfc_plan_role_arn" {
  description = "Set as TFC_AWS_PLAN_ROLE_ARN (env var) on the quest workspace."
  value       = aws_iam_role.terraform_plan.arn
}

output "tfc_apply_role_arn" {
  description = "Set as TFC_AWS_APPLY_ROLE_ARN (env var) on the quest workspace."
  value       = aws_iam_role.terraform.arn
}
