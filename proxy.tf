locals {
  hcloud_architecture_to_udp2raw_binary = {
    "arm" = "udp2raw_arm_asm_aes"
    "x86" = "udp2raw_amd64_hw_aes"
  }
  udp2raw_binary = local.hcloud_architecture_to_udp2raw_binary[data.hcloud_server_type.this[var.proxy_server_type].architecture]
}

resource "hcloud_network_route" "proxy" {
  network_id  = hcloud_network.this.id
  destination = local.proxy_client_subnet_ipv4_cidr
  gateway     = local.proxy_server_ipv4
}

resource "hcloud_primary_ip" "proxy_server" {
  count         = var.proxy_client_count > 0 ? 1 : 0
  name          = "${var.setup_name}-proxy"
  datacenter    = data.hcloud_datacenter.this.name
  type          = "ipv4"
  assignee_type = "server"
  auto_delete   = false
}

resource "random_password" "udp2raw" {
  length  = 20
  special = false
}

resource "wireguard_asymmetric_key" "proxy_server" {
  count = var.proxy_client_count > 0 ? 1 : 0
}

resource "wireguard_asymmetric_key" "proxy_client" {
  count = var.proxy_client_count
}

data "wireguard_config_document" "proxy_server" {
  count       = var.proxy_client_count > 0 ? 1 : 0
  private_key = wireguard_asymmetric_key.proxy_server[0].private_key
  addresses   = ["${local.proxy_server_wireguard_ipv4}/32"]
  listen_port = 51820
  mtu         = 1200

  dynamic "peer" {
    for_each = range(var.proxy_client_count)
    content {
      public_key  = wireguard_asymmetric_key.proxy_client[peer.key].public_key
      allowed_ips = ["${cidrhost(local.proxy_client_subnet_ipv4_cidr, 2 + peer.key)}/32"]
    }
  }
}

data "wireguard_config_document" "proxy_client_udp" {
  count       = var.proxy_client_count
  private_key = wireguard_asymmetric_key.proxy_client[count.index].private_key
  addresses   = ["${cidrhost(local.proxy_client_subnet_ipv4_cidr, 2 + count.index)}/32"]
  mtu         = 1200

  peer {
    public_key  = wireguard_asymmetric_key.proxy_server[0].public_key
    endpoint    = "${hcloud_primary_ip.proxy_server[0].ip_address}:51820"
    allowed_ips = ["${local.proxy_server_wireguard_ipv4}/32", local.wireguard_subnet_ipv4_cidr, local.hcloud_subnet_ipv4_cidr]
  }
}

data "wireguard_config_document" "proxy_client_tcp" {
  count       = var.proxy_client_count
  private_key = wireguard_asymmetric_key.proxy_client[count.index].private_key
  addresses   = ["${cidrhost(local.proxy_client_subnet_ipv4_cidr, 2 + count.index)}/32"]
  mtu         = 1200
  pre_up      = ["udp2raw -c -l 127.0.0.1:51820 -r ${hcloud_primary_ip.proxy_server[0].ip_address}:51819 -k '${random_password.udp2raw.result}' --raw-mode faketcp -a --log-level 3 &"]
  post_down   = ["pkill -f 'udp2raw -c -l 127.0.0.1:51820'"]

  peer {
    public_key  = wireguard_asymmetric_key.proxy_server[0].public_key
    endpoint    = "127.0.0.1:51820"
    allowed_ips = ["${local.proxy_server_wireguard_ipv4}/32", local.wireguard_subnet_ipv4_cidr, local.hcloud_subnet_ipv4_cidr]
  }
}

data "cloudinit_config" "proxy_server" {
  count         = var.proxy_client_count > 0 ? 1 : 0
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
          Destination = ${local.wireguard_subnet_ipv4_cidr}
          Gateway = ${local.hcloud_gateway_ipv4}
          Metric = 1002
          EOF
        EOT
        ,
        "cloud-init-per once restart-networking systemctl restart systemd-networkd.service",
      ],
      package_update = true
      packages = concat(var.additional_packages, [
        "iptables-persistent",
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
          content     = data.wireguard_config_document.proxy_server[0].conf
        }]
      }
      write_files = [
        {
          path        = "/etc/iptables/rules.v4"
          content     = <<-EOT
            *filter
            :FORWARD DROP [0:0]
            :INPUT ACCEPT [0:0]
            -A FORWARD -i wg0 -o enp7s0 -j ACCEPT
            -A FORWARD -i enp7s0 -o wg0 -j ACCEPT
            -A INPUT -i eth0 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
            -A INPUT -i eth0 -p udp --dport 51820 -j ACCEPT
            -A INPUT -i eth0 -p tcp --dport 51819 -j ACCEPT
            -A INPUT -i eth0 -j DROP
            COMMIT
          EOT
          owner       = "root:root"
          permissions = "0640"
        },
        {
          path        = "/usr/local/lib/systemd/system/udp2raw.service"
          content     = <<-EOT
            [Unit]
            Description=Wireguard over TCP via udp2raw
            After=netfilter-persistent.service
            After=network.target

            [Service]
            Type=simple
            ExecStart=/usr/local/bin/udp2raw -s -l 0.0.0.0:51819 -r 127.0.0.1:51820 -k '${random_password.udp2raw.result}' --raw-mode faketcp -a --log-level 3
            Restart=always
            RestartSec=5

            [Install]
            WantedBy=multi-user.target
          EOT
          owner       = "root:root"
          permissions = "0644"
        }
      ]
      runcmd = [
        "curl --location --silent https://github.com/wangyu-/udp2raw/releases/latest/download/udp2raw_binaries.tar.gz | sudo tar --extract --gzip --transform='s|${local.udp2raw_binary}|udp2raw|' --directory='/usr/local/bin' --file=- ${local.udp2raw_binary}",
        "systemctl daemon-reload",
        "systemctl enable --now udp2raw"
      ]
    })
  }
}

resource "hcloud_server" "proxy_server" {
  count       = var.proxy_client_count > 0 ? 1 : 0
  name        = "${var.setup_name}-proxy"
  image       = "ubuntu-24.04"
  server_type = var.proxy_server_type
  datacenter  = data.hcloud_datacenter.this.name
  ssh_keys    = [hcloud_ssh_key.this.id]
  user_data   = data.cloudinit_config.proxy_server[0].rendered

  network {
    network_id = hcloud_network_subnet.root.network_id
    ip         = local.proxy_server_ipv4
  }

  public_net {
    ipv4_enabled = true
    ipv4         = hcloud_primary_ip.proxy_server[0].id
    ipv6_enabled = false
  }
}
