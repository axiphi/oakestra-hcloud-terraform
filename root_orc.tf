resource "hcloud_network_subnet" "root" {
  network_id   = hcloud_network.this.id
  type         = "cloud"
  network_zone = "eu-central"
  ip_range     = local.root_subnet_ipv4_cidr
}

data "cloudinit_config" "root_orc" {
  gzip          = true
  base64_encode = true

  part {
    content_type = "text/cloud-config"
    content = yamlencode({
      bootcmd = [
        "cloud-init-per once disable-hc-net systemctl mask --now hc-net-ifup@enp7s0.service hc-net-scan.service",
        <<-EOT
          cloud-init-per once write-dhcp-conf tee -a /etc/dhcp/dhclient.conf <<EOF
          prepend domain-name-servers 185.12.64.2;
          prepend domain-name-servers 185.12.64.1;
          EOF
        EOT
        ,
        <<-EOT
          cloud-init-per once write-enp7s0-conf tee /etc/network/interfaces.d/99-enp7s0 <<EOF
          auto enp7s0
          iface enp7s0 inet dhcp
            up ip route add default via ${local.hcloud_gateway_ipv4} dev enp7s0 src ${local.root_orc_ipv4} metric 1002 mtu 1450
            up ip route add ${local.wireguard_subnet_ipv4_cidr} via ${local.hcloud_gateway_ipv4} dev enp7s0 src ${local.root_orc_ipv4} metric 1002 mtu 1350
          EOF
        EOT
        ,
        "cloud-init-per once restart-networking systemctl restart networking.service",
      ]
      apt = {
        sources = {
          docker = {
            source    = "deb https://download.docker.com/linux/debian $RELEASE stable"
            keyserver = "https://download.docker.com/linux/debian/gpg"
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
      write_files = [
        {
          path = "/etc/systemd/system/docker.service.d/override.conf"
          # Having options in /etc/docker/daemon.json, conflicts with passing command line arguments to dockerd,
          # so we override the systemd service to not pass any.
          content     = <<-EOT
            [Service]
            ExecStart=
            ExecStart=/usr/bin/dockerd
          EOT
          owner       = "root:root"
          permissions = "0644"
        },
        {
          path = "/etc/docker/daemon.json"
          content = jsonencode({
            containerd = "/run/containerd/containerd.sock"
            hosts      = ["fd://"]
            "registry-mirrors" = [
              "https://${local.registry_ipv4}:${local.registry_local_port}",
              "https://${local.registry_ipv4}:${local.registry_docker_hub_port}",
              "https://${local.registry_ipv4}:${local.registry_ghcr_io_port}"
            ]
            # Setting up proper certificate validation shouldn't be necessary for this, but here is the docs for it:
            # https://docs.docker.com/engine/security/certificates/
            "insecure-registries" = [
              "${local.registry_ipv4}:${local.registry_local_port}",
              "${local.registry_ipv4}:${local.registry_docker_hub_port}",
              "${local.registry_ipv4}:${local.registry_ghcr_io_port}"
            ]
          })
          owner       = "root:root"
          permissions = "0644"
        },
        {
          path = "/etc/iptables/rules.v4"
          # Watchtower tries to check docker.io for updated images when their name does not contain a host part (like ghcr.io).
          # We use the registry mirror functionality of docker to locally override images that also exist in remote repositories.
          # In order for this to work, we need to stop Watchtower from making the request to docker.io and force it to use its
          # secondary mechanism which is a plain Docker image pull (which internally uses our registry mirrors).
          # We achieve this via a special docker network and an iptables rule that blocks outbound traffic from its container ip range.
          content     = <<-EOT
            *filter
            :DOCKER-USER - [0:0]
            -A DOCKER-USER -s ${cidrsubnet(var.watchtower_subnet_ipv4_cidr, 2, 2)} -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
            -A DOCKER-USER -s ${cidrsubnet(var.watchtower_subnet_ipv4_cidr, 2, 2)} -j REJECT
            COMMIT
          EOT
          owner       = "root:root"
          permissions = "0640"
        },
        {
          path = "/etc/docker-compose/oakestra-root-orc/docker-compose.yml",
          content = yamlencode({
            services = {
              "watchtower" = {
                image   = "containrrr/watchtower:1.7.1"
                restart = "always"
                ports   = ["${local.watchtower_port}:8080"]
                environment = [
                  # the local docker registry notifies watchtower when an image was uploaded
                  "WATCHTOWER_HTTP_API_UPDATE=true",
                  "WATCHTOWER_HTTP_API_TOKEN=${random_password.watchtower.result}",
                  # we're only updating oakestra containers, which we explicitly label
                  "WATCHTOWER_LABEL_ENABLE=true",
                  # no need to keep unused images
                  "WATCHTOWER_CLEANUP=true",
                  # we're only updating stateless containers, so this should help with removing temporary state
                  "WATCHTOWER_REMOVE_VOLUMES=true",
                  # when a faulty image is uploaded that keeps crashing its container, this will allow fixing it by uploading again
                  "WATCHTOWER_INCLUDE_RESTARTING=true",
                  # we block watchtower's head requests on purpose, so errors are expected
                  "WATCHTOWER_WARN_ON_HEAD_FAILURE=never"
                ]
                volumes = [{
                  type   = "bind"
                  source = "/var/run/docker.sock"
                  target = "/var/run/docker.sock"
                }]
                networks = ["watchtower"]
              }
              "root-system-manager" = {
                image   = "oakestra/oakestra/root-system-manager:${var.oakestra_version}"
                restart = "always"
                ports = [
                  "10000:10000",
                  "50052:50052"
                ]
                environment = [
                  "CLOUD_MONGO_URL=root-mongo",
                  "CLOUD_MONGO_PORT=10007",
                  "CLOUD_SCHEDULER_URL=cloud-scheduler",
                  "CLOUD_SCHEDULER_PORT=10004",
                  "RESOURCE_ABSTRACTOR_URL=root-resource-abstractor",
                  "RESOURCE_ABSTRACTOR_PORT=11011",
                  "NET_PLUGIN_URL=root-service-manager",
                  "NET_PLUGIN_PORT=10099",
                  "JWT_GENERATOR_URL=jwt-generator",
                  "JWT_GENERATOR_PORT=10011"
                ]
                labels = {
                  "com.centurylinklabs.watchtower.enable" = "true"
                }
              }
              "root-resource-abstractor" = {
                image   = "oakestra/oakestra/root-resource-abstractor:${var.oakestra_version}"
                restart = "always"
                ports   = var.debug_ports_enabled ? ["11011:11011"] : []
                environment = [
                  "RESOURCE_ABSTRACTOR_PORT=11011",
                  "CLOUD_MONGO_URL=root-mongo",
                  "CLOUD_MONGO_PORT=10007"
                ]
                labels = {
                  "com.centurylinklabs.watchtower.enable" = "true"
                }
              }
              "cloud-scheduler" = {
                image   = "oakestra/oakestra/cloud-scheduler:${var.oakestra_version}"
                restart = "always"
                ports   = var.debug_ports_enabled ? ["10004:10004"] : []
                environment = [
                  "MY_PORT=10004",
                  "SYSTEM_MANAGER_URL=root-system-manager",
                  "SYSTEM_MANAGER_PORT=10000",
                  "RESOURCE_ABSTRACTOR_URL=root-resource-abstractor",
                  "RESOURCE_ABSTRACTOR_PORT=11011",
                  "REDIS_ADDR=redis://:cloudRedis@root-redis:6379",
                  "CLOUD_MONGO_URL=root-mongo",
                  "CLOUD_MONGO_PORT=10007"
                ]
                labels = {
                  "com.centurylinklabs.watchtower.enable" = "true"
                }
              }
              "root-service-manager" = {
                image   = "oakestra/oakestra-net/root-service-manager:${var.oakestra_version}"
                restart = "always"
                ports   = ["10099:10099"]
                environment = [
                  "MY_PORT=10099",
                  "SYSTEM_MANAGER_URL=root-system-manager",
                  "SYSTEM_MANAGER_PORT=10000",
                  "CLOUD_MONGO_URL=root-mongo-net",
                  "CLOUD_MONGO_PORT=10008",
                  "JWT_GENERATOR_URL=jwt-generator",
                  "JWT_GENERATOR_PORT=10011"
                ]
                labels = {
                  "com.centurylinklabs.watchtower.enable" = "true"
                }
              }
              "jwt-generator" = {
                image       = "oakestra/oakestra/jwt-generator:${var.oakestra_version}"
                restart     = "always"
                ports       = var.debug_ports_enabled ? ["10011:10011"] : []
                environment = ["JWT_GENERATOR_PORT=10011"]
                labels = {
                  "com.centurylinklabs.watchtower.enable" = "true"
                }
              }
              "dashboard" = {
                image   = "oakestra/dashboard:${var.oakestra_dashboard_version}"
                restart = "always"
                ports   = ["80:80"]
                environment = [
                  "API_ADDRESS=${local.root_orc_ipv4}:10000",
                ]
                labels = {
                  "com.centurylinklabs.watchtower.enable" = "true"
                }
              }
              "root-mongo" = {
                image   = "mongo:8.0"
                restart = "always"
                command = ["mongod", "--port", "10007"]
                ports   = var.debug_ports_enabled ? ["10007:10007"] : []
              }
              "root-mongo-net" = {
                image   = "mongo:8.0"
                restart = "always"
                command = ["mongod", "--port", "10008"]
                ports   = var.debug_ports_enabled ? ["10008:10008"] : []
              }
              "root-redis" = {
                image   = "redis:7.4.2"
                restart = "always"
                command = ["redis-server", "--requirepass", "cloudRedis"]
                ports   = var.debug_ports_enabled ? ["6379:6379"] : []
              }
            }
            networks = {
              default = {
                ipam = {
                  config = [
                    {
                      subnet = var.container_subnet_ipv4_cidr
                    }
                  ]
                }
              }
              watchtower = {
                ipam = {
                  config = [
                    {
                      subnet   = var.watchtower_subnet_ipv4_cidr
                      gateway  = cidrhost(var.watchtower_subnet_ipv4_cidr, 1)
                      ip_range = cidrsubnet(var.watchtower_subnet_ipv4_cidr, 2, 2)
                    }
                  ]
                }
              }
            }
          })
          owner       = "root:root"
          permissions = "0644"
        },
        {
          path        = "/usr/local/lib/systemd/system/oakestra-root-orc.service"
          content     = <<-EOT
            [Unit]
            Description=Oakestra Root Orchestrator (via Docker Compose)
            After=docker.service
            Requires=docker.service

            [Service]
            Type=simple
            Restart=always
            WorkingDirectory=/etc/docker-compose/oakestra-root-orc
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
            cd /etc/docker-compose/oakestra-root-orc
          EOT
          owner       = "root:root"
          permissions = "0644"
        }
      ]
      runcmd = ["systemctl enable --now oakestra-root-orc"]
    })
  }
}

resource "hcloud_server" "root_orc" {
  name        = "${var.setup_name}-root-orc"
  image       = "debian-12"
  server_type = var.root_orc_server_type
  datacenter  = data.hcloud_datacenter.this.name
  ssh_keys    = [hcloud_ssh_key.this.id]
  user_data   = data.cloudinit_config.root_orc.rendered

  network {
    network_id = hcloud_network_subnet.root.network_id
    ip         = local.root_orc_ipv4
  }

  public_net {
    ipv4_enabled = false
    ipv6_enabled = false
  }

  depends_on = [hcloud_server.registry]
}
