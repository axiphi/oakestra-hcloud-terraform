resource "hcloud_network_subnet" "registry" {
  network_id   = hcloud_network.this.id
  type         = "cloud"
  network_zone = "eu-central"
  ip_range     = local.registry_subnet_ipv4_cidr
}

resource "hcloud_primary_ip" "registry" {
  name          = "${var.setup_name}-registry"
  datacenter    = data.hcloud_datacenter.this.name
  type          = "ipv4"
  assignee_type = "server"
  auto_delete   = false
}

locals {
  # Most of this is copied from the defaults of the registry image.
  # Modified/added values are marked.
  shared_registry_config = {
    version = 0.1
    log = {
      fields = {
        service = "registry"
      }
    }
    storage = {
      cache = {
        blobdescriptor = "inmemory"
      }
      filesystem = {
        rootdirectory = "/var/lib/registry"
      }
    }
    health = {
      storagedriver = {
        enabled   = true
        interval  = "10s"
        threshold = 3
      }
    }
    http = {
      addr = ":5000"
      headers = {
        "X-Content-Type-Options" = ["nosniff"]
      }
      # Added: Configure TLS.
      tls = {
        certificate = "/etc/docker/registry/cert.pem"
        key         = "/etc/docker/registry/key.pem"
      }
    }
  }
}

resource "wireguard_asymmetric_key" "local" {}

resource "wireguard_asymmetric_key" "remote" {}

data "wireguard_config_document" "local" {
  private_key = wireguard_asymmetric_key.local.private_key
  addresses   = ["${local.wireguard_local_ipv4}/32"]
  # Hetzner's private networks add additional overhead, so to get the network consistently working we need a low MTU
  mtu = 1350

  peer {
    public_key  = wireguard_asymmetric_key.remote.public_key
    endpoint    = "${hcloud_primary_ip.registry.ip_address}:51820"
    allowed_ips = [local.wireguard_subnet_ipv4_cidr, local.hcloud_subnet_ipv4_cidr]
  }
}

data "wireguard_config_document" "remote" {
  private_key = wireguard_asymmetric_key.remote.private_key
  addresses   = ["${local.wireguard_remote_ipv4}/32"]
  listen_port = 51820

  peer {
    public_key  = wireguard_asymmetric_key.local.public_key
    allowed_ips = [local.wireguard_subnet_ipv4_cidr]
  }
}

resource "hcloud_network_route" "this" {
  network_id  = hcloud_network.this.id
  destination = "0.0.0.0/0"
  gateway     = local.registry_ipv4
}

data "cloudinit_config" "registry" {
  gzip          = true
  base64_encode = true

  part {
    content_type = "text/cloud-config"
    content = yamlencode({
      bootcmd = [
        "sysctl -w net.ipv4.ip_forward=1",
        "cloud-init-per once disable-hc-net systemctl mask --now hc-net-ifup@enp7s0.service hc-net-scan.service",
        <<-EOT
          cloud-init-per once write-enp7s0-conf tee /etc/systemd/network/99-enp7s0.network <<EOF
          [Match]
          Name = enp7s0

          [Network]
          DHCP = ipv4

          [Link]
          MTUBytes = 1350

          [Route]
          Destination = ${local.proxy_client_subnet_ipv4_cidr}
          Gateway = ${local.hcloud_gateway_ipv4}
          Metric = 1002
          EOF
        EOT
        ,
        "cloud-init-per once restart-networking systemctl restart systemd-networkd.service",
      ]
      apt = {
        sources = {
          docker = {
            source    = "deb https://download.docker.com/linux/ubuntu $RELEASE stable"
            keyserver = "https://download.docker.com/linux/ubuntu/gpg"
            keyid     = "9DC858229FC7DD38854AE2D88D81803C0EBFCD88"
          }
        }
      }
      package_update = true
      packages = concat(var.additional_packages, [
        "iptables-persistent",
        "docker-ce",
        "docker-ce-cli",
        "containerd.io",
        "docker-compose-plugin"
      ])
      ssh_pwauth = false
      chpasswd = {
        expire = false
      }
      ssh_keys = {
        ed25519_private = tls_private_key.ssh_server.private_key_openssh
        ed25519_public  = tls_private_key.ssh_server.public_key_openssh
      }
      wireguard = {
        interfaces = [{
          name        = "wg0"
          config_path = "/etc/wireguard/wg0.conf"
          content     = data.wireguard_config_document.remote.conf
        }]
      }
      write_files = [
        {
          path = "/etc/iptables/rules.v4"
          # These iptables rules do three things:
          # - NAT-less forwarding between the WireGuard network and the local Hetzner network (wg0 <-> enp7s0).
          # - Forwarding of the local Hetzner network to the internet (outbound only) with NAT (enp7s0 -> eth0).
          # - Blocking all inbound connections to this machine from the internet other than for the WireGuard tunnel.
          # NOTE: We need to use the DOCKER-USER instead of the FORWARD chain,
          #       because otherwise Docker inserts its own rules before these ones.
          content     = <<-EOT
            *filter
            :DOCKER-USER - [0:0]
            :INPUT ACCEPT [0:0]
            -A DOCKER-USER -i wg0 -o enp7s0 -j ACCEPT
            -A DOCKER-USER -i enp7s0 -o wg0 -j ACCEPT
            -A DOCKER-USER -i enp7s0 -o eth0 -j ACCEPT
            -A DOCKER-USER -i eth0 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
            -A DOCKER-USER -i eth0 -j DROP
            -A INPUT -i eth0 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
            -A INPUT -i eth0 -p udp --dport 51820 -j ACCEPT
            -A INPUT -i eth0 -j DROP
            COMMIT
            *mangle
            :PREROUTING ACCEPT [0:0]
            -A PREROUTING -i enp7s0 -j MARK --set-mark 0x400
            COMMIT
            *nat
            :POSTROUTING ACCEPT [0:0]
            -A POSTROUTING -o eth0 -m mark --mark 0x400 -j SNAT --to-source ${hcloud_primary_ip.registry.ip_address}
            COMMIT
          EOT
          owner       = "root:root"
          permissions = "0640"
        },
        {
          path        = "/usr/local/bin/wait-for-it.sh",
          content     = file("${path.module}/scripts/wait-for-it.sh")
          owner       = "root:root"
          permissions = "0755"
        },
        {
          path        = "/usr/local/bin/normalize-image.sh",
          content     = file("${path.module}/scripts/normalize-image.sh")
          owner       = "root:root"
          permissions = "0755"
        },
        {
          path        = "/usr/local/bin/restore-image.sh",
          content     = <<-EOT
            #!/usr/bin/env sh

            normalized_image="$(normalize-image.sh $1)"
            retagged_image="localhost:${local.registry_local_port}/$${normalized_image}:${var.oakestra_version}"

            docker load
            docker tag "$1" "$${retagged_image}"
            docker push "$${retagged_image}"

            docker rmi "$1"
            docker rmi "$${retagged_image}"
          EOT
          owner       = "root:root"
          permissions = "0755"
        },
        {
          path = "/etc/docker-compose/oakestra-registries/docker-compose.yml",
          content = yamlencode({
            services = {
              "registry-local" = {
                image   = "registry:2.8.3"
                restart = "always"
                ports   = ["${local.registry_local_port}:5000"]
                configs = [
                  {
                    source = "registry-config-local"
                    target = "/etc/docker/registry/config.yml"
                  },
                  {
                    source = "registry-cert"
                    target = "/etc/docker/registry/cert.pem"
                  },
                  {
                    source = "registry-key"
                    target = "/etc/docker/registry/key.pem"
                  }
                ]
              }
              "registry-docker-hub" = {
                image   = "registry:2.8.3"
                restart = "always"
                ports   = ["${local.registry_docker_hub_port}:5000"]
                configs = [
                  {
                    source = "registry-config-docker-hub"
                    target = "/etc/docker/registry/config.yml"
                  },
                  {
                    source = "registry-cert"
                    target = "/etc/docker/registry/cert.pem"
                  },
                  {
                    source = "registry-key"
                    target = "/etc/docker/registry/key.pem"
                  }
                ]
              }
              "registry-ghcr-io" = {
                image   = "registry:2.8.3"
                restart = "always"
                ports   = ["${local.registry_ghcr_io_port}:5000"]
                configs = [
                  {
                    source = "registry-config-ghcr-io"
                    target = "/etc/docker/registry/config.yml"
                  },
                  {
                    source = "registry-cert"
                    target = "/etc/docker/registry/cert.pem"
                  },
                  {
                    source = "registry-key"
                    target = "/etc/docker/registry/key.pem"
                  }
                ]
              }
            }
            configs = {
              "registry-config-local" = {
                content = yamlencode(merge(local.shared_registry_config, {
                  notifications = {
                    endpoints = concat(
                      [
                        {
                          name = "watchtower-root-orc"
                          url  = "http://${local.root_orc_ipv4}:${local.watchtower_port}/v1/update"
                          headers = {
                            "Authorization" = ["Bearer ${random_password.watchtower.result}"]
                          }
                          timeout   = "30s"
                          threshold = 3
                          backoff   = "30s"
                          ignore = {
                            actions    = ["pull"]
                            mediatypes = ["application/octet-stream"]
                          }
                        }
                      ],
                      [
                        for cluster in local.clusters : {
                          name = "watchtower-${cluster.name}-orc"
                          url  = "http://${cluster.orc_ipv4}:${local.watchtower_port}/v1/update"
                          headers = {
                            "Authorization" = ["Bearer ${random_password.watchtower.result}"]
                          }
                          timeout   = "30s"
                          threshold = 3
                          backoff   = "30s"
                          ignore = {
                            actions    = ["pull"]
                            mediatypes = ["application/octet-stream"]
                          }
                        }
                      ]
                    )
                  }
                }))
              }
              "registry-config-docker-hub" = {
                content = yamlencode(merge(local.shared_registry_config, {
                  proxy = {
                    remoteurl = "https://registry-1.docker.io"
                  }
                }))
              }
              "registry-config-ghcr-io" = {
                content = yamlencode(merge(local.shared_registry_config, {
                  proxy = {
                    remoteurl = "https://ghcr.io"
                  }
                }))
              }
              "registry-cert" = {
                content = tls_self_signed_cert.registry.cert_pem
              }
              "registry-key" = {
                content = tls_self_signed_cert.registry.private_key_pem
              }
            }
            networks = {
              default = {
                ipam = {
                  config = [{
                    subnet = var.container_subnet_ipv4_cidr
                  }]
                }
              }
            }
          })
          owner       = "root:root"
          permissions = "0644"
        },
        {
          path        = "/usr/local/lib/systemd/system/oakestra-registries.service"
          content     = <<-EOT
            [Unit]
            Description=Oakestra Development Container Registries (via Docker Compose)
            After=docker.service
            Requires=docker.service

            [Service]
            Type=simple
            Restart=always
            WorkingDirectory=/etc/docker-compose/oakestra-registries
            ExecStart=/usr/bin/docker compose up
            ExecStop=/usr/bin/docker compose down

            [Install]
            WantedBy=multi-user.target
          EOT
          owner       = "root:root"
          permissions = "0644"
        },
        {
          path        = "/root/.bashrc"
          content     = <<-EOT
            cd /etc/docker-compose/oakestra-registries
          EOT
          owner       = "root:root"
          permissions = "0644"
        }
      ]
      runcmd = ["systemctl enable --now oakestra-registries"]
    })
  }
}

resource "hcloud_server" "registry" {
  name = "${var.setup_name}-registry"
  # the WireGuard module of cloud-init is only supported on Ubuntu
  image       = "ubuntu-24.04"
  server_type = var.registry_server_type
  datacenter  = data.hcloud_datacenter.this.name
  ssh_keys    = [hcloud_ssh_key.this.id]
  user_data   = data.cloudinit_config.registry.rendered

  network {
    network_id = hcloud_network_subnet.registry.network_id
    ip         = local.registry_ipv4
  }

  public_net {
    ipv4_enabled = true
    ipv4         = hcloud_primary_ip.registry.id
    ipv6_enabled = false
  }

  connection {
    type        = "ssh"
    host        = hcloud_primary_ip.registry.ip_address
    user        = "root"
    private_key = tls_private_key.ssh_client.private_key_openssh
  }

  provisioner "remote-exec" {
    inline = [
      "echo 'Waiting for registries to come up...'",
      "wait-for-it.sh -q -t 60 localhost:${local.registry_local_port} || exit 1",
      "wait-for-it.sh -q -t 60 localhost:${local.registry_docker_hub_port} || exit 1",
      "wait-for-it.sh -q -t 60 localhost:${local.registry_ghcr_io_port} || exit 1",
      "echo 'Done with waiting for registries.'",
    ]
  }
}
