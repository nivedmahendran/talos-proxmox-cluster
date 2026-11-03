locals {
  net_prefix = split("/", var.node_subnet)[1]

  control_nodes = {
    "talos-cp-1" = { ip = "10.10.10.200" }
  }
  worker_nodes = {
    "talos-worker-1" = { ip = "10.10.10.203" }
    "talos-worker-2" = { ip = "10.10.10.204" }
  }

  common_patches = [
    yamlencode({
      machine = {
        install = { disk = "/dev/vda" }
      }
    })
  ]

  control_patches = {
    for name, n in local.control_nodes : name => concat(local.common_patches, [
      yamlencode({
        machine = {
          network = {
            interfaces = [
              {
                interface = "eth0"
                addresses = ["${n.ip}/${local.net_prefix}"]
                routes = [
                  { network = "0.0.0.0/0", gateway = var.gateway }
                ]
              }
            ]
          }
        }
      })
    ])
  }

  worker_patches = {
    for name, n in local.worker_nodes : name => concat(local.common_patches, [
      yamlencode({
        machine = {
          network = {
            interfaces = [
              {
                interface = "eth0"
                addresses = ["${n.ip}/${local.net_prefix}"]
                routes = [
                  { network = "0.0.0.0/0", gateway = var.gateway }
                ]
              }
            ]
          }
        }
      })
    ])
  }

  control_ips = [for n in local.control_nodes : n.ip]
  worker_ips  = [for n in local.worker_nodes : n.ip]
  all_ips     = concat(local.control_ips, local.worker_ips)
}

# ---------------------------------------------------------------------------
# Talos OS image (qcow2 with qemu-guest-agent) -> downloaded into `local`
# datastore via the API as import content (no SSH required).
# ---------------------------------------------------------------------------
resource "proxmox_download_file" "talos_image" {
  content_type = "import"
  datastore_id = "local-import"
  node_name    = "pve"
  url          = "https://factory.talos.dev/image/${var.talos_schematic_id}/v${var.talos_version}/nocloud-amd64.qcow2"
  file_name    = "talos-nocloud-v${var.talos_version}-amd64.qcow2"
}

# ---------------------------------------------------------------------------
# Control plane VMs
# ---------------------------------------------------------------------------
resource "proxmox_virtual_environment_vm" "control" {
  for_each = local.control_nodes
  name      = each.key
  node_name = "pve"

  agent {
    enabled = true
    wait_for_ip {
      disabled = true
    }
  }

  bios   = "ovmf"
  machine = "q35"

  efi_disk {
    datastore_id = "local-lvm"
    type          = "4m"
    pre_enrolled_keys = false
  }

  serial_device {}

  cpu {
    cores = 2
    type  = "x86-64-v2-AES"
  }

  memory {
    dedicated = 4096
    floating  = 4096
  }

  disk {
    datastore_id = "local-lvm"
    interface     = "virtio0"
    import_from   = proxmox_download_file.talos_image.id
    size          = 40
  }

  network_device {
    bridge = "vmbr0"
  }

  initialization {
    datastore_id = "local-lvm"
    interface     = "ide2"
    type         = "nocloud"
    ip_config {
      ipv4 {
        address = "${each.value.ip}/${local.net_prefix}"
        gateway = var.gateway
      }
    }
    dns {
      servers = var.nameservers
    }
  }

  operating_system {
    type = "l26"
  }
}

# ---------------------------------------------------------------------------
# Worker VMs
# ---------------------------------------------------------------------------
resource "proxmox_virtual_environment_vm" "worker" {
  for_each = local.worker_nodes
  name      = each.key
  node_name = "pve"

  agent {
    enabled = true
    wait_for_ip {
      disabled = true
    }
  }

  bios   = "ovmf"
  machine = "q35"

  efi_disk {
    datastore_id = "local-lvm"
    type          = "4m"
    pre_enrolled_keys = false
  }

  serial_device {}

  cpu {
    cores = 2
    type  = "x86-64-v2-AES"
  }

  memory {
    dedicated = 4096
    floating  = 4096
  }

  disk {
    datastore_id = "local-lvm"
    interface     = "virtio0"
    import_from   = proxmox_download_file.talos_image.id
    size          = 60
  }

  network_device {
    bridge = "vmbr0"
  }

  initialization {
    datastore_id = "local-lvm"
    interface     = "ide2"
    type         = "nocloud"
    ip_config {
      ipv4 {
        address = "${each.value.ip}/${local.net_prefix}"
        gateway = var.gateway
      }
    }
    dns {
      servers = var.nameservers
    }
  }

  operating_system {
    type = "l26"
  }
}

# ---------------------------------------------------------------------------
# Talos cluster bootstrap
# ---------------------------------------------------------------------------
resource "talos_machine_secrets" "secrets" {}

data "talos_machine_configuration" "control_mc" {
  cluster_name     = var.cluster_name
  machine_type     = "controlplane"
  cluster_endpoint = "https://10.10.10.200:6443"
  machine_secrets  = talos_machine_secrets.secrets.machine_secrets
}

data "talos_machine_configuration" "worker_mc" {
  cluster_name     = var.cluster_name
  machine_type     = "worker"
  cluster_endpoint = "https://10.10.10.200:6443"
  machine_secrets  = talos_machine_secrets.secrets.machine_secrets
}

data "talos_client_configuration" "client" {
  cluster_name         = var.cluster_name
  client_configuration = talos_machine_secrets.secrets.client_configuration
  endpoints            = local.control_ips
  nodes                = local.all_ips
}

resource "talos_machine_configuration_apply" "control_apply" {
  for_each                  = local.control_nodes
  client_configuration        = talos_machine_secrets.secrets.client_configuration
  machine_configuration_input = data.talos_machine_configuration.control_mc.machine_configuration
  node                        = each.value.ip
  config_patches              = local.control_patches[each.key]

  depends_on = [
    proxmox_virtual_environment_vm.control
  ]
}

resource "talos_machine_bootstrap" "bootstrap" {
  node                 = local.control_ips[0]
  client_configuration = talos_machine_secrets.secrets.client_configuration

  depends_on = [
    talos_machine_configuration_apply.control_apply
  ]
}

resource "talos_machine_configuration_apply" "worker_apply" {
  for_each                  = local.worker_nodes
  client_configuration        = talos_machine_secrets.secrets.client_configuration
  machine_configuration_input = data.talos_machine_configuration.worker_mc.machine_configuration
  node                        = each.value.ip
  config_patches              = local.worker_patches[each.key]

  depends_on = [
    talos_machine_bootstrap.bootstrap
  ]
}

resource "talos_cluster_kubeconfig" "kubeconfig" {
  node                 = local.control_ips[0]
  client_configuration = talos_machine_secrets.secrets.client_configuration

  depends_on = [
    talos_machine_bootstrap.bootstrap
  ]
}
