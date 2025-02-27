data "cloudinit_config" "worker" {
  for_each      = { for worker in local.workers : worker.name => worker }
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
            up ip route add default via ${local.hcloud_gateway_ipv4} dev enp7s0 src ${each.value.ipv4} metric 1002 mtu 1450
            up ip route add ${local.wireguard_subnet_ipv4_cidr} via ${local.hcloud_gateway_ipv4} dev enp7s0 src ${each.value.ipv4} metric 1002 mtu 1350
          EOF
        EOT
        ,
        "cloud-init-per once restart-networking systemctl restart networking.service",
      ]
      package_update = true
      packages       = var.additional_packages
      ssh_pwauth     = false
      chpasswd = {
        expire = false
      }
      ssh_keys = {
        ed25519_private = tls_private_key.ssh_server.private_key_openssh
        ed25519_public  = tls_private_key.ssh_server.public_key_openssh
      }
      write_files = [
        {
          path        = "/usr/local/lib/systemd/system/netmanager.service"
          content     = <<-EOT
            [Unit]
            Description=Oakestra NetManager Service
            After=network.target

            [Service]
            Type=simple
            Restart=always
            RestartSec=5
            ExecStart=/usr/local/bin/NetManager
            StandardOutput=append:/var/log/oakestra/netmanager.log
            StandardError=append:/var/log/oakestra/netmanager.log

            [Install]
            WantedBy=multi-user.target
          EOT
          owner       = "root:root"
          permissions = "0644"
        },
        {
          path        = "/usr/local/lib/systemd/system/nodeengine.service"
          content     = <<-EOT
            [Unit]
            Description=Oakestra NodeEngine Service
            After=network.target

            [Service]
            Type=simple
            Restart=always
            RestartSec=5
            ExecStart=/usr/local/bin/nodeengined
            StandardOutput=append:/var/log/oakestra/nodeengine.log
            StandardError=append:/var/log/oakestra/nodeengine.log

            [Install]
            WantedBy=multi-user.target
          EOT
          owner       = "root:root"
          permissions = "0644"
        },
        {
          path = "/etc/netmanager/tuncfg.json"
          content = jsonencode({
            HostTunnelDeviceName      = "goProxyTun"
            TunnelIP                  = "10.19.1.254"
            ProxySubnetwork           = "10.30.0.0"
            ProxySubnetworkMask       = "255.255.0.0"
            TunnelPort                = 50103
            MTUsize                   = 1450
            TunNetIPv6                = "fcef::dead:beef"
            ProxySubnetworkIPv6       = "fcef::"
            ProxySubnetworkIPv6Prefix = 21
          })
          owner       = "root:root"
          permissions = "0644"
        },
        {
          path = "/etc/netmanager/netcfg.json"
          content = jsonencode({
            NodePublicAddress = "0.0.0.0"
            NodePublicPort    = "50103"
            ClusterUrl        = "0.0.0.0"
            ClusterMqttPort   = "10003"
            Debug             = false
            MqttCert          = ""
            MqttKey           = ""
          })
          owner       = "root:root"
          permissions = "0644"
        },
        {
          path = "/etc/oakestra/conf.json"
          content = jsonencode({
            conf_version         = "1.0"
            cluster_address      = local.clusters[each.value.cluster_index].orc_ipv4
            cluster_port         = 10100
            app_logs             = "/tmp"
            overlay_network      = "default"
            overlay_network_port = 0
            mqtt_cert_file       = ""
            mqtt_key_file        = ""
            addons               = null
            virtualizations = [
              {
                # [sic!]
                "virutalizaiton_name" : "containerd",
                "virutalizaiton_runtime" : "docker",
                "virutalizaiton_active" : true,
                "virutalizaiton_config" : []
              }
            ]
          })
        }
      ]
      runcmd = [
        # install containerd
        "curl --location --silent https://github.com/containerd/containerd/releases/download/v2.0.2/containerd-2.0.2-linux-${each.value.server_arch}.tar.gz | tar --extract --gzip --directory=/usr/local --file=-",
        # install runc
        "curl --location --silent --create-dirs --output /usr/local/sbin/runc https://github.com/opencontainers/runc/releases/download/v1.2.4/runc.${each.value.server_arch}",
        "chmod 0755 /usr/local/sbin/runc",
        # install CNI plugins
        "mkdir -p /opt/cni/bin",
        "curl --location --silent https://github.com/containernetworking/plugins/releases/download/v1.6.2/cni-plugins-linux-${each.value.server_arch}-v1.6.2.tgz | tar --extract --gzip --directory=/opt/cni/bin --file=-",
        # install containerd systemd-service
        "curl --location --silent --create-dirs --output /usr/local/lib/systemd/system/containerd.service https://raw.githubusercontent.com/containerd/containerd/main/containerd.service",
        "chmod 0755 /usr/local/lib/systemd /usr/local/lib/systemd/system",
        # install Oakestra binaries
        join(" && ", [
          "export OAK_TMP=\"$(mktemp -d)\"",
          "curl --location --silent https://github.com/oakestra/oakestra/releases/download/${var.oakestra_version}/NodeEngine_${each.value.server_arch}.tar.gz | tar --extract --gzip \"--directory=$${OAK_TMP}\" --file=-",
          "cp \"$${OAK_TMP}/NodeEngine\" /usr/local/bin/NodeEngine",
          "cp \"$${OAK_TMP}/nodeengined\" /usr/local/bin/nodeengined",
          "rm -r \"$${OAK_TMP}\""
        ]),
        join(" && ", [
          "export OAK_TMP=\"$(mktemp -d)\"",
          "curl --location --silent https://github.com/oakestra/oakestra-net/releases/download/${var.oakestra_version}/NetManager_${each.value.server_arch}.tar.gz | tar --extract --gzip \"--directory=$${OAK_TMP}\" --file=-",
          "cp \"$${OAK_TMP}/NetManager\" /usr/local/bin/NetManager",
          "rm -r \"$${OAK_TMP}\""
        ]),
        "mkdir -p /var/log/oakestra",
        # start containerd and Oakestra
        "systemctl daemon-reload",
        "systemctl enable --now containerd netmanager nodeengine",
      ]
    })
  }
}

resource "hcloud_server" "worker" {
  for_each    = { for worker in local.workers : worker.name => worker }
  name        = "${var.setup_name}-${each.key}"
  image       = "debian-12"
  server_type = each.value.server_type
  datacenter  = data.hcloud_datacenter.this.name
  ssh_keys    = [hcloud_ssh_key.this.id]
  user_data   = data.cloudinit_config.worker[each.key].rendered

  network {
    network_id = hcloud_network_subnet.cluster[each.value.cluster_name].network_id
    ip         = each.value.ipv4
  }

  public_net {
    ipv4_enabled = false
    ipv6_enabled = false
  }

  depends_on = [hcloud_server.registry]
}
