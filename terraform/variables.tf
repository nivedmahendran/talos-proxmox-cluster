variable "pve_endpoint" {
  description = "Proxmox API endpoint"
  type        = string
  default     = "https://10.10.10.113:8006/"
}

variable "pve_username" {
  description = "Proxmox username (with realm)"
  type        = string
  default     = "root@pam"
}

variable "cluster_name" {
  description = "Name of the Kubernetes/Talos cluster"
  type        = string
  default     = "homelab"
}

variable "talos_version" {
  description = "Talos Linux version to install"
  type        = string
  default     = "1.14.5"
}

variable "talos_schematic_id" {
  description = "Talos Image Factory schematic ID (includes qemu-guest-agent)"
  type        = string
  default     = "ce4c980550dd2ab1b17bbf2b08801c7eb59418eafe8f279833297925d67c7515"
}

variable "vip" {
  description = "Kubernetes API virtual IP shared by the control plane (Talos VIP)"
  type        = string
  default     = "10.10.10.199"
}

variable "node_subnet" {
  description = "Subnet (CIDR) the Talos nodes live in"
  type        = string
  default     = "10.10.10.0/22"
}

variable "gateway" {
  description = "Default gateway for the Talos nodes"
  type        = string
  default     = "10.10.10.1"
}

variable "nameservers" {
  description = "DNS nameservers for the Talos nodes"
  type        = list(string)
  default     = ["10.10.10.1", "1.1.1.1"]
}
