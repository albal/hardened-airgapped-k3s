# The data disk is optional and overridable per node. Getting this wrong is
# quiet and expensive: no disk means the Longhorn node-prep playbook fails, and
# a wrongly-sized one means storage that does not fit what was planned.

mock_provider "proxmox" {}

variables {
  pve_token_secret = "mock-secret-not-used"
  nodes = {
    "k3s-node-1" = { vm_id = 9101, mac_address = "BC:24:11:C3:00:01" }
    "k3s-node-2" = { vm_id = 9102, mac_address = "BC:24:11:C3:00:02" }
  }
}

run "zero_means_no_data_disk_at_all" {
  command = plan

  variables {
    data_disk_size = 0
  }

  assert {
    condition     = length(proxmox_virtual_environment_vm.node["k3s-node-1"].disk) == 1
    error_message = "data_disk_size = 0 should leave only the boot disk"
  }

  assert {
    condition     = proxmox_virtual_environment_vm.node["k3s-node-1"].disk[0].interface == "scsi0"
    error_message = "the one remaining disk should be the boot disk"
  }
}

run "a_node_can_override_the_global_size" {
  command = plan

  variables {
    data_disk_size = 128
    nodes = {
      "k3s-node-1" = { vm_id = 9101, mac_address = "BC:24:11:C3:00:01", data_disk_size = 512 }
      "k3s-node-2" = { vm_id = 9102, mac_address = "BC:24:11:C3:00:02" }
    }
  }

  assert {
    condition = length([
      for d in proxmox_virtual_environment_vm.node["k3s-node-1"].disk : d
      if d.interface == "scsi1" && d.size == 512
    ]) == 1
    error_message = "a per-node data_disk_size should win over the global default"
  }

  assert {
    condition = length([
      for d in proxmox_virtual_environment_vm.node["k3s-node-2"].disk : d
      if d.interface == "scsi1" && d.size == 128
    ]) == 1
    error_message = "a node without an override should still get the global size"
  }
}

run "a_node_can_opt_out_while_others_keep_theirs" {
  command = plan

  variables {
    data_disk_size = 128
    nodes = {
      "k3s-node-1" = { vm_id = 9101, mac_address = "BC:24:11:C3:00:01", data_disk_size = 0 }
      "k3s-node-2" = { vm_id = 9102, mac_address = "BC:24:11:C3:00:02" }
    }
  }

  assert {
    condition     = length(proxmox_virtual_environment_vm.node["k3s-node-1"].disk) == 1
    error_message = "a per-node 0 should remove that node's data disk only"
  }

  assert {
    condition     = length(proxmox_virtual_environment_vm.node["k3s-node-2"].disk) == 2
    error_message = "one node opting out must not affect the others"
  }
}

run "data_disk_can_live_on_its_own_datastore" {
  command = plan

  variables {
    datastore_id           = "local-lvm"
    data_disk_datastore_id = "fast-nvme"
  }

  assert {
    condition = alltrue([
      for d in proxmox_virtual_environment_vm.node["k3s-node-1"].disk :
      d.datastore_id == (d.interface == "scsi1" ? "fast-nvme" : "local-lvm")
    ])
    error_message = "the data disk should honour data_disk_datastore_id while the boot disk stays put"
  }
}

run "data_disk_defaults_to_the_main_datastore" {
  command = plan

  assert {
    condition = alltrue([
      for d in proxmox_virtual_environment_vm.node["k3s-node-1"].disk : d.datastore_id == var.datastore_id
    ])
    error_message = "with no override both disks should land on datastore_id"
  }
}
