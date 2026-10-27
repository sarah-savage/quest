variable "image_tag" {
  description = "Tag of the quest image in ECR to run: the full git SHA the GitHub Actions workflow pushed. Set on the TFC workspace."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-f]{40}$", var.image_tag))
    error_message = "image_tag must be a full 40-character git SHA, as pushed by .github/workflows/build.yml."
  }
}
