variable "hcloud_token" {
  type      = string
  sensitive = true
}

variable "setup_name" {
  type        = string
  description = <<-EOT
    The name for the whole Oakestra setup, used for local domains and more.
    Must have a length between 1 and 16 characters and should not contain special characters other than '-' and '_'.
  EOT

  validation {
    condition     = can(regex("^[0-9A-Za-z_-]{1,10}$", var.setup_name))
    error_message = "Must have a length between 1 and 10 characters and should not contain special characters other than '-' and '_'."
  }
}

variable "oakestra_version" {
  type        = string
  description = <<-EOT
    The version of Oakestra that is used to deploy its docker containers and binaries.
    Oakestra docker images that are pushed to the local registry will replace the default one for that version.
  EOT
}

variable "oakestra_dashboard_version" {
  type        = string
  description = <<-EOT
    The version of Oakestra that is used to deploy its dashboard docker container.
    Oakestra docker images that are pushed to the local registry will replace the default one for that version.
  EOT
}

variable "datacenter" {
  type        = string
  description = "The datacenter where servers will be provisioned."
  default     = "fsn1-dc14"
}

variable "registry_server_type" {
  type        = string
  description = "The Hetzner Cloud server type for the container registries."
  default     = "cax11"
}

variable "root_orc_server_type" {
  type        = string
  description = "The Hetzner Cloud server type for the root orchestrator."
  default     = "cax11"
}

variable "clusters" {
  type = list(object({
    orc_server_type = string
    location        = string
    workers = list(object({
      server_type = string
    }))
  }))
  default = [{
    orc_server_type = "cax11"
    location        = "48.1507,11.5691,1000"
    workers = [{
      server_type = "cax11"
    }]
  }]
}

variable "node_subnet_ipv4_cidr" {
  type        = string
  nullable    = false
  default     = "10.44.0.0/16"
  description = "The IPv4 subnet for the nodes being provisioned."

  validation {
    condition     = can(cidrhost(var.node_subnet_ipv4_cidr, 0))
    error_message = "Must be valid IPv4 CIDR."
  }

  validation {
    condition     = endswith(var.node_subnet_ipv4_cidr, "/16")
    error_message = "Currently only /16 subnets are supported."
  }
}

variable "container_subnet_ipv4_cidr" {
  type        = string
  nullable    = false
  default     = "172.18.0.0/16"
  description = "The IPv4 subnet for containers launched on servers."

  validation {
    condition     = can(cidrhost(var.container_subnet_ipv4_cidr, 0))
    error_message = "Must be valid IPv4 CIDR."
  }
}

variable "watchtower_subnet_ipv4_cidr" {
  type        = string
  nullable    = false
  default     = "192.168.0.0/30"
  description = "The IPv4 subnet for Watchtower launched on servers."

  validation {
    condition     = can(cidrhost(var.watchtower_subnet_ipv4_cidr, 0))
    error_message = "Must be valid IPv4 CIDR."
  }

  validation {
    condition     = endswith(var.watchtower_subnet_ipv4_cidr, "/30")
    error_message = "Currently only /30 subnets are supported."
  }
}

variable "additional_packages" {
  type        = list(string)
  nullable    = false
  default     = []
  description = "Additional packages to be installed on each node."
}
