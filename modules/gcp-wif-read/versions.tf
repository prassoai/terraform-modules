terraform {
  required_version = ">= 1.2"
  required_providers {
    google = { source = "hashicorp/google", version = ">= 5.0" }
    http   = { source = "hashicorp/http", version = ">= 3.4" }
  }
}
