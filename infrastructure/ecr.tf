# ──────────────────────────────────────────────────────────────
# Quest container image repository
#
# The GitHub Actions workflow on master pushes here through the role in
# github-oidc.tf. Tags are immutable so a tag always names the image it was
# first pushed as; the lifecycle policy caps storage at the 10 newest images.
# ──────────────────────────────────────────────────────────────

resource "aws_ecr_repository" "quest" {
  name                 = "quest"
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  tags = local.tags
}

resource "aws_ecr_lifecycle_policy" "quest" {
  repository = aws_ecr_repository.quest.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep the 10 most recent images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 10
        }
        action = {
          type = "expire"
        }
      },
    ]
  })
}

output "ecr_repository_url" {
  description = "URL of the quest ECR repository (image push target)."
  value       = aws_ecr_repository.quest.repository_url
}
