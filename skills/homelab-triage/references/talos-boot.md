# Talos node boot failures

## 1. "This program can only be run on AMD64 processors with v2 microarchitecture support" → kernel panic

- **Symptom:** after GRUB auto-boot: `executing /sbin/init` then
  `Kernel panic - not syncing: Attempted to kill init!`. Node pings but the
  Talos API (50000) never listens.
- **Root cause:** Talos 1.14 binaries require **x86-64-v2**. Default QEMU CPU
  model `qemu64` is too old (no SSE4.2/POPCNT).
- **Fix:** `cpu { cores = 2; type = "x86-64-v2-AES" }` in Terraform
  (`proxmox_virtual_environment_vm`).

## 2. GRUB renders, then nothing; no dashboard/API

- **Root cause:** legacy SeaBIOS. Talos 1.14 images are UEFI-first.
- **Fix:**
  ```hcl
  bios   = "ovmf"
  machine = "q35"
  efi_disk { datastore_id = "local-lvm"; type = "4m"; pre_enrolled_keys = false }
  ```

## 3. Dashboard: "failed to validate config acquired via platform nocloud"

- **Root cause:** `talosctl gen config` (v1.14) emits a multi-document bundle
  (`UnattendedInstallConfig`, `HostnameConfig`, `ResolverConfig`...). Slicing to
  "first document" or mixing manual `machine.network.hostname`/`nameservers`/
  `machine.install` patches conflicts.
- **Fix:** boot into maintenance mode and let the `siderolabs/talos` provider
  apply the canonical config, then bootstrap. Don't hand-build user-data.

## Notes

- Static IPs: cloud-init `ip_config` provides them; machine config sets them too.
- Talos API = 50000; k8s API = 6443.
- Serial console: VM must define `serial_device {}`; read via
  `socat - UNIX-CONNECT:/var/run/qemu-server/<vmid>.serial0`.
