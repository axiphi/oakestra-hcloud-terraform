resource "hcloud_network_subnet" "cluster" {
  for_each     = { for cluster in local.clusters : cluster.name => cluster }
  network_id   = hcloud_network.this.id
  type         = "cloud"
  network_zone = "eu-central"
  ip_range     = each.value.subnet_ipv4_cidr
}

data "cloudinit_config" "cluster_orc" {
  for_each      = { for cluster in local.clusters : cluster.name => cluster }
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
            up ip route add default via ${local.hcloud_gateway_ipv4} dev enp7s0 src ${each.value.orc_ipv4} metric 1002 mtu 1450
            up ip route add ${local.wireguard_subnet_ipv4_cidr} via ${local.hcloud_gateway_ipv4} dev enp7s0 src ${each.value.orc_ipv4} metric 1002 mtu 1350
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
          path        = "/etc/iptables/rules.v4"
          content     = <<-EOT
            *filter
            :DOCKER-USER - [0:0]
            -A DOCKER-USER -s ${cidrsubnet(var.watchtower_subnet_ipv4_cidr, 2, 2)} -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
            -A DOCKER-USER -s ${cidrsubnet(var.watchtower_subnet_ipv4_cidr, 2, 2)} -j DROP
            COMMIT
          EOT
          owner       = "root:root"
          permissions = "0640"
        },
        {
          path = "/etc/docker-compose/oakestra-cluster-orc/docker-compose.yml",
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
              "cluster-scheduler" = {
                image   = "oakestra/oakestra/cluster-scheduler:${var.oakestra_version}"
                restart = "always"
                ports   = var.debug_ports_enabled ? ["10105:10105"] : []
                environment = [
                  "MY_PORT=10105",
                  "CLUSTER_MANAGER_URL=cluster-manager",
                  "CLUSTER_MANAGER_PORT=10100",
                  "CLUSTER_MONGO_URL=cluster-mongo",
                  "CLUSTER_MONGO_PORT=10107",
                  "REDIS_ADDR=redis://:clusterRedis@cluster-redis:6479"
                ]
                labels = {
                  "com.centurylinklabs.watchtower.enable" = "true"
                }
              }
              "cluster-service-manager" = {
                image   = "oakestra/oakestra-net/cluster-service-manager:${var.oakestra_version}"
                restart = "always"
                ports   = var.debug_ports_enabled ? ["10110:10110"] : []
                environment = [
                  "MY_PORT=10110",
                  "MQTT_BROKER_PORT=10003",
                  "MQTT_BROKER_URL=cluster-mqtt",
                  "ROOT_SERVICE_MANAGER_URL=${local.root_orc_ipv4}",
                  "ROOT_SERVICE_MANAGER_PORT=10099",
                  "SYSTEM_MANAGER_URL=cluster-manager",
                  "SYSTEM_MANAGER_PORT=10000",
                  "CLUSTER_MONGO_URL=cluster-mongo-net",
                  "CLUSTER_MONGO_PORT=10108"
                ]
                labels = {
                  "com.centurylinklabs.watchtower.enable" = "true"
                }
              }
              "cluster-manager" = {
                image   = "oakestra/oakestra/cluster-manager:${var.oakestra_version}"
                restart = "always"
                ports   = ["10100:10100"]
                environment = [
                  "MY_PORT=10100",
                  "SYSTEM_MANAGER_URL=${local.root_orc_ipv4}",
                  "SYSTEM_MANAGER_PORT=10000",
                  "CLUSTER_SERVICE_MANAGER_ADDR=cluster-service-manager",
                  "CLUSTER_SERVICE_MANAGER_PORT=10110",
                  "CLUSTER_MONGO_URL=cluster-mongo",
                  "CLUSTER_MONGO_PORT=10107",
                  "CLUSTER_SCHEDULER_URL=cluster-scheduler",
                  "CLUSTER_SCHEDULER_PORT=10105",
                  "MQTT_BROKER_URL=cluster-mqtt",
                  "MQTT_BROKER_PORT=10003",
                  "CLUSTER_NAME=${each.value.name}",
                  "CLUSTER_LOCATION=${each.value.location}"
                ]
                labels = {
                  "com.centurylinklabs.watchtower.enable" = "true"
                }
              }
              "cluster-mongo" = {
                image   = "mongo:8.0"
                restart = "always"
                command = ["mongod", "--port", "10107"]
                ports   = var.debug_ports_enabled ? ["10107:10107"] : []
              }
              "cluster-mongo-net" = {
                image   = "mongo:8.0"
                restart = "always"
                command = ["mongod", "--port", "10108"]
                ports   = var.debug_ports_enabled ? ["10108:10108"] : []
              }
              "cluster-redis" = {
                image   = "redis:7.4.2"
                restart = "always"
                command = ["redis-server", "--requirepass", "clusterRedis", "--port", "6479"]
                ports   = var.debug_ports_enabled ? ["6479:6479"] : []
              }
              "cluster-mqtt" = {
                image   = "eclipse-mosquitto:1.6"
                restart = "always"
                ports   = ["10003:10003"]
                configs = [{
                  source = "cluster-mqtt-config"
                  target = "/mosquitto/config/mosquitto.conf"
                }]
              }
            }
            configs = {
              "cluster-mqtt-config" = {
                content = <<-EOT
                  listener 10003
                  allow_anonymous true
                EOT
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
          path        = "/usr/local/lib/systemd/system/oakestra-cluster-orc.service"
          content     = <<-EOT
            [Unit]
            Description=Oakestra Cluster Orchestrator (via Docker Compose)
            After=docker.service
            Requires=docker.service

            [Service]
            Type=simple
            Restart=always
            WorkingDirectory=/etc/docker-compose/oakestra-cluster-orc
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
            cd /etc/docker-compose/oakestra-cluster-orc
          EOT
          owner       = "root:root"
          permissions = "0644"
        }
      ]
      runcmd = ["systemctl enable --now oakestra-cluster-orc"]
    })
  }
}

resource "hcloud_server" "cluster_orc" {
  for_each    = { for cluster in local.clusters : cluster.name => cluster }
  name        = "${var.setup_name}-${each.key}-orc"
  image       = "debian-12"
  server_type = each.value.orc_server_type
  datacenter  = data.hcloud_datacenter.this.name
  ssh_keys    = [hcloud_ssh_key.this.id]
  user_data   = data.cloudinit_config.cluster_orc[each.key].rendered

  network {
    network_id = hcloud_network_subnet.cluster[each.key].network_id
    ip         = each.value.orc_ipv4
  }

  public_net {
    ipv4_enabled = false
    ipv6_enabled = false
  }

  depends_on = [hcloud_server.registry]
}
