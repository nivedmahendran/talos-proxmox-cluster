# Troubleshooting

This documents the real failure modes hit while bringing up this cluster and
their fixes. Symptom → root cause → fix.

## 1. Talos scrolls "This program can only be run on AMD64 processors with v2 microarchitecture support" → kernel panic

- **Symptom:** After GRUB auto-boot, the node panics:
  ```
  [talos] [initramfs] executing /sbin/init
  This program can only be run on AMD64 processors with v2 microarchitecture support.
  Kernel panic - not syncing: Attempted to kill init!
  ```
  The node may still answer ping (network comes up early), but the Talos API
  (port 50000) never listens.
- **Root cause:** Talos 1.14 binaries require **x86-64-v2**. The default
  QEMU CPU model (`qemu64`) is an ancient baseline without SSE4.2/POPCNT, so
  the Talos userspace cannot even start.
- **Fix:** set the VM CPU type:
  ```hcl
  cpu {
    cores = 2
    type  = "x86-64-v2-AES"
  }
  ```

## 2. VMs boot to GRUB but nothing else happens / services never start

- **Symptom:** GRUB renders, then the display stays on the GRUB frame; no
  Talos dashboard; API never comes up.
- **Root cause:** the VMs were created with legacy SeaBIOS. Talos 1.14
  images are UEFI-first.
- **Fix:** use UEFI:
  ```hcl
  bios   = "ovmf"
  machine = "q35"
  efi_disk {
    datastore_id = "local-lvm"
    type          = "4m"
    pre_enrolled_keys = false
  }
  ```

## 3. Talos dashboard shows `failed to validate config acquired via platform nocloud`

- **Symptom:** on the VM console:
  ```
  failed to validate config acquired via platform nocloud: 3 errors occurred:
    * UnattendedInstallConfig config is incompatible with v1alpha1 config (.machine.install)
    * .machine.network.nameservers is already set in v1alpha1 config
    * static hostname is already set in v1alpha1 config
  ```
- **Root cause:** `talosctl gen config` in v1.14 emits a **multi-document**
  bundle (`UnattendedInstallConfig`, `HostnameConfig`, `ResolverConfig`, ...).
  Slicing it down to "just the first document" loses the kubelet/control-plane
  sections, and mixing it with manual `machine.network.hostname` /
  `nameservers` / `machine.install` patches creates validation conflicts.
- **Fix:** do not hand-build user-data. Let the node boot into **maintenance
  mode** and have the `siderolabs/talos` provider apply the canonical bundle:

  ```hcl
  resource "talos_machine_configuration_apply" "control_apply" {
    client_configuration        = talos_machine_secrets.secrets.client_configuration
    machine_configuration_input = data.talos_machine_configuration.control_mc.machine_configuration
    node                        = each.value.ip
    config_patches              = [...]   # only what is truly per-node (IP/route)
  }
  ```

## 4. `talosctl kubeconfig` fails with "k8s API server CA config is not set"

- **Symptom:** after bootstrap, kubeconfig errors with `FailedPrecondition:
  k8s API server CA config is not set`, and `service kubelet` is absent.
- **Root cause:** the control-plane config was incomplete (see #3), so
  kubelet never ran and static pods (kube-apiserver) never started.
- **Fix:** same as #3 — apply the full canonical config, then bootstrap.

## 5. Terraform apply hangs on `talos_machine_configuration_apply`

- **Symptom:** the apply resource stays `Still creating...` for many minutes.
- **Root cause (usually):** the node is not reachable on the Talos API. See
  #1/#2 (CPU/firmware). Occasionally this is also caused by a **secret
  mismatch**: if the node was already configured from user-data generated with
  *different* cluster secrets, the apply can't take over.
- **Fix:** address the boot issue; keep a single source of identity (the
  `talos_machine_secrets` resource).

## 6. Proxmox: "storage 'local' is not configured for content-type 'import'"

- **Symptom:** `proxmox_download_file` fails downloading the qcow2 image.
- **Root cause:** the target datastore must accept `import` content.
- **Fix:** create the dedicated datastore (see README → one-time
  preparation):
  ```bash
  pvesm add dir local-import --path /var/lib/vz/imports --content import
  ```

## Debugging aids

- The VMs are created with a serial console (`serial_device {}`). Read it on
  the host:
  ```bash
  # on Proxmox host
  socat - UNIX-CONNECT:/var/run/qemu-server/<vmid>.serial0
  ```
- Screenshot of the VM console via QEMU monitor:
  ```bash
  # on Proxmox host
  python3 - <<'EOF'
  import socket, json
  s = socket.socket(socket.AF_UNIX); s.connect("/var/run/qemu-server/<vmid>.qmp")
  def r():
      b=b""
      while True:
          c=s.recv(1)
          if not c: break
          b+=c
          if c==b"\n": break
      return b.decode(errors="replace").strip()
  def q(o):
      s.sendall((json.dumps(o)+"\n").encode()); return r()
  r(); q({"execute":"qmp_capabilities"})
  print(q({"execute":"screendump","arguments":{"filename":"/tmp/scr.png"}}))
  EOF
  tesseract /tmp/scr.png stdout
  ```
- The Talos dashboard's on-screen log is a good real-time source once the
  node is up.
