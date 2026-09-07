terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.70"
    }
  }


  # State lives in a Cloudflare R2 bucket through the S3 backend. Bucket,
  # endpoint and R2 credentials come from ../backend.hcl (gitignored):
  #   terraform init -backend-config=<repo>/backend.hcl   (just init)
  backend "s3" {
    key    = "trading-host/terraform.tfstate"
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

provider "aws" {
  region  = var.region
  profile = var.aws_profile

  default_tags {
    tags = {
      project    = "trading-bots"
      managed_by = "terraform"
      repository = "trading-bots-host-setup"
    }
  }
}
