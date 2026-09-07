# Three VMs on the Proxmox host, each attached to the Debian netinst ISO.
#
# These come up as blank machines sitting in the Debian installer - Terraform
# creates the hardware, it does not install the OS. See README.md for what the
# guests need before ./k3s-airgap-installer.run can use them.

locals {
  # Stable ordering so plan output and the summary table read the same way.
  node_names = sort(keys(var.nodes))
}

resource "proxmox_virtual_environment_vm" "node" {
  for_each = var.nodes

  node_name   = var.pve_node
  vm_id       = each.value.vm_id
  name        = "${var.vm_name_prefix}${each.key}"
  description = coalesce(each.value.description, "Managed by Terraform - airgapped k3s node")
  tags        = var.tags

  started = var.start_on_create
  on_boot = true

  # Without this, `terraform destroy` fails on a running VM.
  stop_on_destroy = true

  machine = var.machine_type
  bios    = "seabios"

  # virtio-scsi-single is what makes the per-disk iothread below worth having.
  scsi_hardware = "virtio-scsi-single"

  # Disk first, CD second. A blank disk is not bootable so the firmware falls
  # through to the ISO for the install, and once Debian is on disk the VM boots
  # straight into it without anyone having to detach the ISO.
  boot_order = ["scsi0", "ide2"]

  operating_system {
    type = "l26"
  }

  cpu {
    cores   = coalesce(each.value.cores, var.default_cores)
    sockets = 1
    type    = var.cpu_type
  }

  memory {
    dedicated = coalesce(each.value.memory, var.default_memory)
  }

  disk {
    datastore_id = var.datastore_id
    interface    = "scsi0"
    size         = coalesce(each.value.disk_size, var.default_disk_size)
    file_format  = "raw"
    discard      = "on"
    ssd          = true
    iothread     = true
  }

  # Longhorn's disk. Kept separate from the boot disk so Longhorn owns a whole
  # device: the node-prep playbook puts a filesystem on it and mounts it at
  # /var/lib/longhorn. Deliberately excluded from backups - Longhorn already
  # keeps a replica of every volume on each of the other nodes, so backing this
  # up stores the same data three times over.
  dynamic "disk" {
    for_each = coalesce(each.value.data_disk_size, var.data_disk_size) > 0 ? [1] : []
    content {
      datastore_id = coalesce(var.data_disk_datastore_id, var.datastore_id)
      interface    = "scsi1"
      size         = coalesce(each.value.data_disk_size, var.data_disk_size)
      file_format  = "raw"
      discard      = "on"
      ssd          = true
      iothread     = true
      backup       = false
    }
  }

  cdrom {
    file_id   = var.iso_file_id
    interface = "ide2"
  }

  network_device {
    bridge      = var.network_bridge
    model       = "virtio"
    mac_address = each.value.mac_address
    vlan_id     = var.vlan_id
  }

  agent {
    # The preseed installs qemu-guest-agent, so this is on by default. The
    # timeout has to outlast the unattended Debian install on a first apply:
    # nothing can answer until the guest has finished installing and rebooted.
    enabled = var.qemu_agent_enabled
    timeout = var.qemu_agent_timeout
    type    = "virtio"
  }

  # Gives `qm terminal <vmid>` on the PVE host as a fallback when the graphical
  # console is not usable.
  serial_device {}
}
