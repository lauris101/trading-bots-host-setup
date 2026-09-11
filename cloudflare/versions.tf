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


  # State lives in a Cloudflare R2 bucket through the S3 backend. Bucket,
  # endpoint and R2 credentials come from ../backend.hcl (gitignored):
  #   terraform init -backend-config=<repo>/backend.hcl   (just init)
  backend "s3" {
    key    = "cloudflare/terraform.tfstate"
    region = "auto"
    # R2 is not AWS: no STS, no region, no checksum trailer, path-style URLs.
    skip_credentials_validation = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_metadata_api_check     = true
    skip_s3_checksum            = true
    use_path_style              = true
  }
}

# Credentials: CLOUDFLARE_API_TOKEN in the environment (README "API token").
provider "cloudflare" {
  # From terraform.tfvars (gitignored), like the R2 keys in backend.hcl;
  # unset there, the provider reads CLOUDFLARE_API_TOKEN from the environment.
  api_token = var.cloudflare_api_token
}
