# Skills

Reusable OpenCode skills for this homelab stack.

## homelab-triage

A low-token diagnostic reference for the Proxmox → Talos → Kubernetes →
Tailscale → GitLab stack. Symptom → root-cause → fix quick-seek table, with
deeper per-domain references.

### Install

Copy the skill into OpenCode's global skills directory:

```bash
cp -r homelab-triage ~/.config/opencode/skills/
```

Or, for a project-local install, copy it to `.opencode/skills/` in the target
repo. It then auto-loads when a matching problem is described.
