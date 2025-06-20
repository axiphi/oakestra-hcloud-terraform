output "proxy_client_config_udp" {
  description = "Wireguard (via UDP) configuration for proxy clients"
  value       = [for config in data.wireguard_config_document.proxy_client_udp : config.conf]
  sensitive   = true
}

output "proxy_client_config_tcp" {
  description = "Wireguard (via TCP) configuration for proxy clients"
  value       = [for config in data.wireguard_config_document.proxy_client_tcp : config.conf]
  sensitive   = true
}
