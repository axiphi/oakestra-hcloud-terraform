terraform {
  required_version = ">=1.8.0"

  required_providers {
    null = {
      source  = "hashicorp/null"
      version = ">=3.2.3"
    }

    random = {
      source  = "hashicorp/random"
      version = ">=3.6.3"
    }

    tls = {
      source  = "hashicorp/tls"
      version = ">=4.0.6"
    }

    local = {
      source  = "hashicorp/local"
      version = ">=2.5.2"
    }

    cloudinit = {
      source  = "hashicorp/cloudinit"
      version = ">=2.3.5"
    }

    wireguard = {
      source  = "OJFord/wireguard"
      version = ">=0.3.2"
    }

    hcloud = {
      source  = "hetznercloud/hcloud"
      version = ">=1.45"
    }
  }
}

provider "hcloud" {
  token = var.hcloud_token
}
