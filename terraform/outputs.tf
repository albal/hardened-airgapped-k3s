output "vms" {
  description = "Created VMs, keyed by name."
  value = {
    for name, vm in proxmox_virtual_environment_vm.node : name => {
      vm_id       = vm.vm_id
      node        = vm.node_name
      mac_address = try(vm.network_device[0].mac_address, null)
      console     = "${trimsuffix(var.pve_endpoint, "/")}/?console=kvm&novnc=1&vmid=${vm.vm_id}&node=${vm.node_name}"
    }
  }
}

output "mac_addresses" {
  description = "MAC addresses, for creating DHCP reservations before the guests are installed."
  value       = { for name, vm in proxmox_virtual_environment_vm.node : name => try(vm.network_device[0].mac_address, null) }
}

output "ipv4_addresses" {
  description = <<-EOT
    Guest IP addresses. Empty until qemu-guest-agent is installed in the guests
    and qemu_agent_enabled is set to true.
  EOT
  value       = { for name, vm in proxmox_virtual_environment_vm.node : name => try(vm.ipv4_addresses, []) }
}

output "next_steps" {
  description = "What to do once Terraform has created the VMs."
  value       = <<-EOT
    ${length(local.node_names)} VM(s) created on ${var.pve_node}: ${join(", ", local.node_names)}

    They are powered on and sitting in the Debian installer. For each one, open
    the Proxmox console and install Debian with:

      * a distinct hostname (Kubernetes uses it as the node name)
      * SSH server selected in tasksel, and root login permitted with a password
      * a static IP, or a DHCP reservation for the MAC above
      * the standard system utilities task (this brings in python3, which Ansible needs)

    Then, from a workstation that can reach them:

      ./dist/k3s-airgap-installer.run
  EOT
}
