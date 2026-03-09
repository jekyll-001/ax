variable "golang_version" {
  type = string
}

variable "variant" {
  type = string
}

variable "op_random_password" {
  type = string
}

variable "snapshot_name" {
  type = string
}

packer {
  required_plugins {
    vultr = {
      version = ">= 2.6.0"
      source  = "github.com/vultr/vultr"
    }
  }
}

source "vultr" "packer" {
  api_key              = var.vultr_api_key
  os_id                = 1743
  plan_id              = var.default_size
  region_id            = var.region
  snapshot_description = var.snapshot_name
  ssh_username         = "root"
  state_timeout        = "25m"
}

build {
  sources = ["source.vultr.packer"]
