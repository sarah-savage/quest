# ──────────────────────────────────────────────────────────────
# Networking outputs consumed by later layers
# ──────────────────────────────────────────────────────────────

output "vpc_id" {
  description = "ID of the quest VPC"
  value       = module.vpc.vpc_id
}

output "public_subnets" {
  description = "IDs of the public subnets"
  value       = module.vpc.public_subnets
}

output "private_subnets" {
  description = "IDs of the private subnets"
  value       = module.vpc.private_subnets
}

output "nat_public_ips" {
  description = "Elastic IPs of the NAT gateway"
  value       = module.vpc.nat_public_ips
}
