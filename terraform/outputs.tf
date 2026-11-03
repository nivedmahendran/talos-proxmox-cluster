output "kubeconfig" {
  description = "kubectl kubeconfig for the cluster"
  value       = talos_cluster_kubeconfig.kubeconfig.kubeconfig_raw
  sensitive   = true
}

output "talosconfig" {
  description = "talosctl client configuration"
  value       = data.talos_client_configuration.client.talos_config
  sensitive   = true
}

output "control_plane_nodes" {
  description = "Control plane node IPs"
  value       = local.control_ips
}

output "worker_nodes" {
  description = "Worker node IPs"
  value       = local.worker_ips
}

output "cluster_endpoint" {
  description = "Kubernetes API endpoint"
  value       = "https://10.10.10.200:6443"
}
