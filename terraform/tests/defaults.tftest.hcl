# Shape of the VMs Terraform will actually create.
#
# mock_provider means these run with no Proxmox, no credentials and no network,
# so they are safe on any machine and in CI. They check the plan, which is where
# every mistake that matters here shows up: a disk on the wrong interface, a
# data disk that silently vanished, an agent timeout too short to survive the
# unattended OS install.

mock_provider "proxmox" {}

variables {
  pve_token_secret = "mock-secret-not-used"
  nodes = {
    "k3s-node-1" = { vm_id = 9101, mac_address = "BC:24:11:C3:00:01" }
    "k3s-node-2" = { vm_id = 9102, mac_address = "BC:24:11:C3:00:02" }
    "k3s-node-3" = { vm_id = 9103, mac_address = "BC:24:11:C3:00:03" }
  }
}

run "creates_one_vm_per_node" {
  command = plan

  assert {
    condition     = length(proxmox_virtual_environment_vm.node) == 3
    error_message = "expected 3 VMs, one per entry in var.nodes"
  }

  assert {
    condition     = proxmox_virtual_environment_vm.node["k3s-node-2"].vm_id == 9102
    error_message = "each VM must take the vm_id from its own nodes entry"
  }

  assert {
    condition     = proxmox_virtual_environment_vm.node["k3s-node-1"].name == "k3s-node-1"
    error_message = "the VM name should be the nodes map key (no prefix configured)"
  }
}

run "boot_disk_is_scsi0_at_the_default_size" {
  command = plan

  assert {
    condition = length([
      for d in proxmox_virtual_environment_vm.node["k3s-node-1"].disk : d
      if d.interface == "scsi0" && d.size == 40
    ]) == 1
    error_message = "node 1 should have exactly one 40 GB boot disk on scsi0"
  }
}

run "data_disk_is_a_separate_128g_device_excluded_from_backups" {
  command = plan

  # This is the disk Longhorn takes over. It has to be a whole separate device -
  # the node-prep playbook only formats a disk with no signature on it at all.
  assert {
    condition = length([
      for d in proxmox_virtual_environment_vm.node["k3s-node-3"].disk : d
      if d.interface == "scsi1" && d.size == 128
    ]) == 1
    error_message = "each node should get one 128 GB data disk on scsi1"
  }

  # Longhorn already keeps a replica on every node, so letting Proxmox back this
  # up as well would store the same data three times over.
  assert {
    condition = alltrue([
      for d in proxmox_virtual_environment_vm.node["k3s-node-3"].disk : d.backup == false
      if d.interface == "scsi1"
    ])
    error_message = "the Longhorn data disk must be excluded from Proxmox backups"
  }

  assert {
    condition     = length(proxmox_virtual_environment_vm.node["k3s-node-2"].disk) == 2
    error_message = "a node should have exactly two disks: boot and data"
  }
}

run "guest_agent_outlasts_the_unattended_install" {
  command = plan

  # Terraform does not consider a VM created until the agent answers, and on a
  # first apply nothing can answer until the OS has installed and rebooted -
  # roughly ten minutes. The provider's own 15m default leaves little room.
  assert {
    condition     = proxmox_virtual_environment_vm.node["k3s-node-1"].agent[0].enabled == true
    error_message = "the guest agent should be declared: the installer media installs it"
  }

  assert {
    condition     = proxmox_virtual_environment_vm.node["k3s-node-1"].agent[0].timeout == "30m"
    error_message = "the agent timeout must outlast the unattended OS install"
  }
}

run "boots_from_disk_then_falls_through_to_the_iso" {
  command = plan

  # A blank disk is not bootable, so the firmware falls through to the ISO for
  # the install and boots the installed system afterwards - without anyone
  # having to detach the media between the two.
  assert {
    condition     = proxmox_virtual_environment_vm.node["k3s-node-1"].boot_order == tolist(["scsi0", "ide2"])
    error_message = "boot order must be disk first, CD second"
  }

  assert {
    condition     = proxmox_virtual_environment_vm.node["k3s-node-1"].cdrom[0].interface == "ide2"
    error_message = "the ISO must be on ide2, which is what boot_order names"
  }

  assert {
    condition     = proxmox_virtual_environment_vm.node["k3s-node-1"].cdrom[0].file_id == var.iso_file_id
    error_message = "the CD-ROM should carry the configured install ISO"
  }
}

run "destroy_is_possible_and_macs_are_honoured" {
  command = plan

  # Without stop_on_destroy, `terraform destroy` fails on a running VM.
  assert {
    condition     = proxmox_virtual_environment_vm.node["k3s-node-1"].stop_on_destroy == true
    error_message = "stop_on_destroy must be set or destroy fails on a running VM"
  }

  # The install media identifies each machine by MAC to decide its hostname, so
  # a dropped MAC would give every node the same name.
  assert {
    condition     = proxmox_virtual_environment_vm.node["k3s-node-2"].network_device[0].mac_address == "BC:24:11:C3:00:02"
    error_message = "the configured MAC must reach the NIC: the installer keys hostnames off it"
  }

  assert {
    condition     = proxmox_virtual_environment_vm.node["k3s-node-1"].scsi_hardware == "virtio-scsi-single"
    error_message = "virtio-scsi-single is what makes the per-disk iothread meaningful"
  }
}

run "outputs_describe_every_node" {
  command = plan

  assert {
    condition     = length(output.mac_addresses) == 3
    error_message = "mac_addresses should list every node, for DHCP reservations"
  }

  assert {
    condition     = can(regex("k3s-node-2", output.next_steps))
    error_message = "next_steps should name the nodes it created"
  }
}
