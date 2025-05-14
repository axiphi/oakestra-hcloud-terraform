resource "null_resource" "oakestra_data_dir" {
  triggers = {
    oakestra_data_dir = local.oakestra_data_dir
  }

  provisioner "local-exec" {
    command = "mkdir -p '${self.triggers.oakestra_data_dir}'"
  }

  provisioner "local-exec" {
    when    = destroy
    command = "rm -rf ${self.triggers.oakestra_data_dir}"
  }
}

resource "local_sensitive_file" "wireguard_config" {
  filename        = "${null_resource.oakestra_data_dir.triggers.oakestra_data_dir}/wg-${var.setup_name}.conf"
  content         = data.wireguard_config_document.local.conf
  file_permission = "0600"
}

resource "local_sensitive_file" "ssh_key" {
  filename        = "${null_resource.oakestra_data_dir.triggers.oakestra_data_dir}/ssh_key"
  content         = tls_private_key.ssh_client.private_key_openssh
  file_permission = "0600"
}

resource "local_file" "ssh_known_hosts" {
  filename = "${null_resource.oakestra_data_dir.triggers.oakestra_data_dir}/ssh_known_hosts"
  content = join("\n", concat(
    [
      "${local.registry_ipv4} ${chomp(tls_private_key.ssh_server.public_key_openssh)}",
      "${local.root_orc_ipv4} ${chomp(tls_private_key.ssh_server.public_key_openssh)}"
    ],
    [for cluster in local.clusters : "${cluster.orc_ipv4} ${chomp(tls_private_key.ssh_server.public_key_openssh)}"],
    [for worker in local.workers : "${worker.ipv4} ${chomp(tls_private_key.ssh_server.public_key_openssh)}"]
  ))
  file_permission = "0600"
}

resource "local_file" "ssh_config" {
  filename = "${null_resource.oakestra_data_dir.triggers.oakestra_data_dir}/ssh_config"
  content = join("\n", concat(
    [
      <<-EOT
        Host registry
         HostName ${local.registry_ipv4}
         User root
         IdentityFile ${local_sensitive_file.ssh_key.filename}
         UserKnownHostsFile ${local_file.ssh_known_hosts.filename}
      EOT
      ,
      <<-EOT
        Host root-orc
         HostName ${local.root_orc_ipv4}
         User root
         IdentityFile ${local_sensitive_file.ssh_key.filename}
         UserKnownHostsFile ${local_file.ssh_known_hosts.filename}
      EOT
    ],
    [for cluster in local.clusters : (
      <<-EOT
        Host ${cluster.name}-orc
         HostName ${cluster.orc_ipv4}
         User root
         IdentityFile ${local_sensitive_file.ssh_key.filename}
         UserKnownHostsFile ${local_file.ssh_known_hosts.filename}
      EOT
    )],
    [for worker in local.workers : (
      <<-EOT
        Host ${worker.name}
         HostName ${worker.ipv4}
         User root
         IdentityFile ${local_sensitive_file.ssh_key.filename}
         UserKnownHostsFile ${local_file.ssh_known_hosts.filename}
      EOT
    )]
  ))
  file_permission = "0644"
}

locals {
  worker_names = [for worker in local.workers : worker.name]
}

resource "local_file" "init_script" {
  filename        = "${null_resource.oakestra_data_dir.triggers.oakestra_data_dir}/init.sh"
  content         = <<-EOT
    # This file must be used with "source" *from bash*
    # you cannot run it directly

    if [ "$${BASH_SOURCE-}" = "$0" ]; then
      echo "You must source this script: \$ source $0" >&2
      exit 33
    fi

    ${var.setup_name}-up() {
      sudo wg-quick up "${local_sensitive_file.wireguard_config.filename}"
    }

    ${var.setup_name}-down() {
      sudo wg-quick down "${local_sensitive_file.wireguard_config.filename}"
    }

    ${var.setup_name}-ssh() {
      ssh -F "${local_file.ssh_config.filename}" "$@"
    }

    ${var.setup_name}-image-push() {
      if [ $# -ne 1 ]; then
          echo "Error: ${var.setup_name}-image-push expects exactly one argument." >&2
          return 1
      fi

      if command -v pv 2>&1 >/dev/null; then
        docker save "$1" | pv -s $(docker image inspect "$1" --format='{{.Size}}') | gzip | ${var.setup_name}-ssh -q registry "zcat | restore-image.sh \"$1\""
      else
        docker save "$1" | gzip | ${var.setup_name}-ssh -q registry "zcat | restore-image.sh \"$1\""
      fi
    }

    ${var.setup_name}-nodeengine-push() {
      if [ $# -ne 2 ]; then
        echo "Error: ${var.setup_name}-nodeengine-push expects exactly two arguments." >&2
        return 1
      fi

      for worker in '${join("' '", local.worker_names)}'; do
        ${var.setup_name}-ssh -q "$${worker}" "systemctl stop nodeengine.service"
        scp -q -p -F "/home/phiber/.local/share/oakestra-dev/oaks-1000/ssh_config" "$1" "$${worker}:/usr/local/bin/NodeEngine"
        scp -q -p -F "/home/phiber/.local/share/oakestra-dev/oaks-1000/ssh_config" "$2" "$${worker}:/usr/local/bin/nodeengined"
        ${var.setup_name}-ssh -q "$${worker}" "systemctl start nodeengine.service"
      done
    }

    ${var.setup_name}-netmanager-push() {
      if [ $# -ne 1 ]; then
        echo "Error: ${var.setup_name}-netmanager-push expects exactly one argument." >&2
        return 1
      fi

      for worker in '${join("' '", local.worker_names)}'; do
        ${var.setup_name}-ssh -q "$${worker}" "systemctl stop netmanager.service"
        scp -q -p -F "/home/phiber/.local/share/oakestra-dev/oaks-1000/ssh_config" "$1" "$${worker}:/usr/local/bin/NetManager"
        ${var.setup_name}-ssh -q "$${worker}" "systemctl start netmanager.service"
      done
    }
  EOT
  file_permission = "0744"
}
