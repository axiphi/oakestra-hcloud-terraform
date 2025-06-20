data "external" "xdg_data_home" {
  program = ["sh", "${path.module}/scripts/json-wrap.sh", "--ignore-error", "printenv", "XDG_DATA_HOME"]
}

data "hcloud_server_type" "this" {
  for_each = toset(concat(
    [var.root_orc_server_type, var.registry_server_type],
    [for cluster in var.clusters : cluster.orc_server_type],
    [for worker in flatten([for cluster in var.clusters : cluster.workers]) : worker.server_type]
  ))
  name = each.key
}

data "hcloud_datacenter" "this" {
  name = var.datacenter
}

data "hcloud_location" "this" {
  id = data.hcloud_datacenter.this.location.id
}

locals {
  hcloud_to_artifact_architecture = {
    "arm" = "arm64"
    "x86" = "amd64"
  }

  base_data_dir     = trimsuffix(pathexpand(coalesce(data.external.xdg_data_home.result.value, "~/.local/share")), "/")
  oakestra_data_dir = "${local.base_data_dir}/oakestra-dev/${var.setup_name}"

  wireguard_subnet_ipv4_cidr = cidrsubnet(var.node_subnet_ipv4_cidr, 2, 0)
  wireguard_local_ipv4       = cidrhost(local.wireguard_subnet_ipv4_cidr, 2)
  wireguard_remote_ipv4      = cidrhost(local.wireguard_subnet_ipv4_cidr, 3)

  proxy_client_subnet_ipv4_cidr = cidrsubnet(var.node_subnet_ipv4_cidr, 2, 1)

  hcloud_subnet_ipv4_cidr = cidrsubnet(var.node_subnet_ipv4_cidr, 2, 2)
  hcloud_gateway_ipv4     = cidrhost(local.hcloud_subnet_ipv4_cidr, 1)

  registry_subnet_ipv4_cidr = cidrsubnet(local.hcloud_subnet_ipv4_cidr, 4, 0)
  registry_ipv4             = cidrhost(local.registry_subnet_ipv4_cidr, 2)
  registry_local_port       = 10500
  registry_docker_hub_port  = 10501
  registry_ghcr_io_port     = 10502

  root_subnet_ipv4_cidr       = cidrsubnet(local.hcloud_subnet_ipv4_cidr, 4, 1)
  root_orc_ipv4               = cidrhost(local.root_subnet_ipv4_cidr, 2)
  proxy_server_ipv4           = cidrhost(local.root_subnet_ipv4_cidr, 3)
  proxy_server_wireguard_ipv4 = "192.168.0.0"

  cluster_subnet_ipv4_cidrs = [for cluster_idx in range(length(var.clusters)) : cidrsubnet(local.hcloud_subnet_ipv4_cidr, 4, 2 + cluster_idx)]
  clusters = [for cluster_idx, cluster in var.clusters : {
    index            = cluster_idx
    name             = "cluster-${cluster_idx + 1}"
    location         = cluster.location
    subnet_ipv4_cidr = local.cluster_subnet_ipv4_cidrs[cluster_idx]
    orc_ipv4         = cidrhost(local.cluster_subnet_ipv4_cidrs[cluster_idx], 2)
    orc_server_type  = cluster.orc_server_type
    workers = [for worker_idx, worker in cluster.workers : {
      index         = worker_idx
      name          = "worker-${cluster_idx + 1}-${worker_idx + 1}"
      ipv4          = cidrhost(local.cluster_subnet_ipv4_cidrs[cluster_idx], 3 + worker_idx)
      server_type   = worker.server_type
      server_arch   = local.hcloud_to_artifact_architecture[data.hcloud_server_type.this[worker.server_type].architecture]
      cluster_index = cluster_idx
      cluster_name  = "cluster-${cluster_idx + 1}"
    }]
  }]
  # flattened version of local.clusters, to make for_each resources easier
  workers = flatten([for cluster in local.clusters : cluster.workers])

  watchtower_port = 8080
}

resource "tls_private_key" "ssh_client" {
  algorithm = "ED25519"
}

resource "tls_private_key" "ssh_server" {
  algorithm = "ED25519"
}

resource "tls_private_key" "registry" {
  algorithm = "ED25519"
}

resource "tls_self_signed_cert" "registry" {
  private_key_pem       = tls_private_key.registry.private_key_pem
  ip_addresses          = [local.registry_ipv4]
  validity_period_hours = 24 * 365 * 10 # 10 years
  allowed_uses = [
    "digital_signature",
    "server_auth"
  ]

  subject {
    common_name  = local.registry_ipv4
    organization = "Oakestra Container Registry (${var.setup_name})"
  }
}

resource "hcloud_network" "this" {
  name     = var.setup_name
  ip_range = local.hcloud_subnet_ipv4_cidr
}

resource "hcloud_ssh_key" "this" {
  name       = var.setup_name
  public_key = tls_private_key.ssh_client.public_key_openssh
}

resource "random_password" "watchtower" {
  length  = 20
  special = false
}
