terraform {
  required_version = ">= 1.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 5.0"
    }
    murmur = {
      source  = "prassoai/murmur"
      version = "~> 0.1"
    }
  }
}
