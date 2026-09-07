terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.70"
    }
  }

  # State stays on the machine that runs terraform (gitignored). One host,
  # one operator: a remote backend would be more infrastructure to manage
  # than the thing it protects. Back the .tfstate up with the rest of your
  # secrets; losing it means importing the resources by hand.
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
