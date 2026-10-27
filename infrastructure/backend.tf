terraform {
  cloud {
    hostname     = "app.terraform.io"
    organization = "Tailwinds"
    workspaces {
      name = "quest"
    }
  }
}
