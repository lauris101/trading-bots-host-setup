terraform {
  required_version = ">= 1.6"

  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.4"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # Local state, like the trading host. It holds the tunnel secrets: back
  # it up with your secrets, never commit it (gitignored).
}

# Credentials: CLOUDFLARE_API_TOKEN in the environment (README "API token").
provider "cloudflare" {}
