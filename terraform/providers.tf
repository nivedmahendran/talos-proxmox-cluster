terraform {
  required_version = ">= 1.5"

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.111.1"
    }
    talos = {
      source  = "siderolabs/talos"
      version = "~> 0.11.0"
    }
  }
}

provider "proxmox" {
  endpoint = var.pve_endpoint
  insecure = true
  # API credentials are supplied via environment variables:
  #   PROXMOX_VE_USERNAME
  #   PROXMOX_VE_API_TOKEN
}
