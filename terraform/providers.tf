terraform {
  required_version = ">= 1.16.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.9"
    }
  }

  backend "s3" {
    bucket = "llm-platform-terraform-state-16b53600dfa4660f"
    key    = "terraform.tfstate"
    region = "eu-central-1"

    use_lockfile = true
  }
}

provider "aws" {
  region = "eu-central-1"

  default_tags {
    tags = {
      App       = "llm-platform"
      ManagedBy = "terraform"
    }
  }
}
