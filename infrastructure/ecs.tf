# ──────────────────────────────────────────────────────────────
# Quest service — ECS on Fargate, two tasks in the private subnets
# ──────────────────────────────────────────────────────────────

resource "aws_ecs_cluster" "quest" {
  name = "quest"

  setting {
    name  = "containerInsights"
    value = "disabled"
  }

  tags = local.tags
}

resource "aws_cloudwatch_log_group" "quest" {
  name              = "/ecs/quest"
  retention_in_days = 7

  tags = local.tags
}

# ──────────────────────────────────────────────────────────────
# SECRET_WORD — SSM Parameter Store SecureString
#
# Terraform creates the parameter with a placeholder and never sets the value
# again, so the real word is not in git. Refresh still reads it into Terraform
# Cloud state. It is set by hand with `aws ssm put-parameter --overwrite`, then the service
# is redeployed so the tasks read the new value at start.
# ──────────────────────────────────────────────────────────────

resource "aws_ssm_parameter" "secret_word" {
  name        = "/quest/secret_word"
  description = "SECRET_WORD for the quest container; value is set outside Terraform."
  type        = "SecureString"
  value       = "placeholder"

  lifecycle {
    ignore_changes = [value]
  }

  tags = local.tags
}

# ──────────────────────────────────────────────────────────────
# Execution role — used by the ECS agent, never by the app
#
# There is deliberately NO task role: the container gets no AWS credentials,
# so a request that makes the app query the metadata endpoint finds none.
# ──────────────────────────────────────────────────────────────

data "aws_caller_identity" "current" {}

resource "aws_iam_role" "ecs_execution" {
  name        = "QuestEcsTaskExecution"
  description = "ECS task execution role for the quest service (image pull, logs, SECRET_WORD)"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "ecs-tasks.amazonaws.com" }
        Action    = "sts:AssumeRole"
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
          }
        }
      },
    ]
  })

  tags = local.tags
}

resource "aws_iam_role_policy" "ecs_execution" {
  name = "QuestEcsTaskExecution"
  role = aws_iam_role.ecs_execution.id

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
        Sid    = "EcrPullQuest"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:BatchGetImage",
          "ecr:GetDownloadUrlForLayer",
        ]
        Resource = aws_ecr_repository.quest.arn
      },
      {
        Sid      = "WriteLogs"
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.quest.arn}:*"
      },
      # No kms:Decrypt statement: the parameter uses the AWS-managed aws/ssm
      # key, whose key policy already allows decryption through SSM.
      {
        Sid      = "ReadSecretWord"
        Effect   = "Allow"
        Action   = "ssm:GetParameters"
        Resource = aws_ssm_parameter.secret_word.arn
      },
    ]
  })
}

resource "aws_ecs_task_definition" "quest" {
  family                   = "quest"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 256
  memory                   = 512
  execution_role_arn       = aws_iam_role.ecs_execution.arn

  # bin/001-bin/006 are amd64-only binaries.
  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  container_definitions = jsonencode([
    {
      name      = "quest"
      image     = "${aws_ecr_repository.quest.repository_url}:${var.image_tag}"
      essential = true

      portMappings = [
        { containerPort = 3000, protocol = "tcp" },
      ]

      secrets = [
        { name = "SECRET_WORD", valueFrom = aws_ssm_parameter.secret_word.arn },
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.quest.name
          awslogs-region        = data.aws_region.current.region
          awslogs-stream-prefix = "quest"
        }
      }
    },
  ])

  tags = local.tags
}

# Only the ALB reaches the tasks. Egress is open so the tasks can reach ECR,
# SSM and CloudWatch Logs through the NAT gateway (and S3 through its endpoint).
resource "aws_security_group" "tasks" {
  name        = "quest-tasks"
  description = "Quest Fargate tasks: port 3000 from the ALB only"
  vpc_id      = module.vpc.vpc_id

  tags = merge(local.tags, { Name = "quest-tasks" })
}

resource "aws_vpc_security_group_ingress_rule" "tasks_from_alb" {
  security_group_id            = aws_security_group.tasks.id
  description                  = "App port from the ALB"
  ip_protocol                  = "tcp"
  from_port                    = 3000
  to_port                      = 3000
  referenced_security_group_id = aws_security_group.alb.id
}

resource "aws_vpc_security_group_egress_rule" "tasks_all" {
  security_group_id = aws_security_group.tasks.id
  description       = "ECR, SSM and CloudWatch Logs through the NAT gateway"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_ecs_service" "quest" {
  name            = "quest"
  cluster         = aws_ecs_cluster.quest.id
  task_definition = aws_ecs_task_definition.quest.arn
  desired_count   = 2
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = module.vpc.private_subnets
    security_groups  = [aws_security_group.tasks.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.quest.arn
    container_name   = "quest"
    container_port   = 3000
  }

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  propagate_tags = "SERVICE"

  # The target group must be attached to a listener before ECS can register
  # targets in it.
  depends_on = [aws_lb_listener.https]

  tags = local.tags
}

output "ecs_cluster_name" {
  description = "Name of the quest ECS cluster."
  value       = aws_ecs_cluster.quest.name
}

output "ecs_service_name" {
  description = "Name of the quest ECS service (redeploy after setting SECRET_WORD)."
  value       = aws_ecs_service.quest.name
}

output "secret_word_parameter" {
  description = "SSM parameter that holds SECRET_WORD."
  value       = aws_ssm_parameter.secret_word.name
}
