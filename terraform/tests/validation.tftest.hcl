# Every `validation` block in variables.tf, proven to fire.
#
# These guards exist because each mistake they catch is otherwise silent and
# expensive: a duplicate vm_id clobbers an existing VM, a malformed MAC means
# the install media cannot tell the nodes apart, and an address without a prefix
# length produces a guest with a broken network configuration.
#
# Each negative case is paired with a positive control, so a rule that rejects
# everything - which would "pass" a negative-only test - still fails here.

mock_provider "proxmox" {}

variables {
  pve_token_secret = "mock-secret-not-used"
  nodes = {
    "k3s-node-1" = { vm_id = 9101, mac_address = "BC:24:11:C3:00:01" }
  }
}

run "rejects_an_empty_node_map" {
  command = plan

  variables {
    nodes = {}
  }

  expect_failures = [var.nodes]
}

run "rejects_duplicate_vm_ids" {
  command = plan

  variables {
    nodes = {
      "k3s-node-1" = { vm_id = 9101, mac_address = "BC:24:11:C3:00:01" }
      "k3s-node-2" = { vm_id = 9101, mac_address = "BC:24:11:C3:00:02" }
    }
  }

  expect_failures = [var.nodes]
}

run "rejects_a_malformed_mac" {
  command = plan

  variables {
    nodes = {
      "k3s-node-1" = { vm_id = 9101, mac_address = "not-a-mac" }
    }
  }

  expect_failures = [var.nodes]
}

run "rejects_an_address_without_a_prefix_length" {
  command = plan

  variables {
    nodes = {
      "k3s-node-1" = { vm_id = 9101, mac_address = "BC:24:11:C3:00:01", ip_address = "10.20.0.11" }
    }
  }

  expect_failures = [var.nodes]
}

run "rejects_a_token_id_that_is_not_user_realm_token" {
  command = plan

  variables {
    pve_token_id = "root@pam"
  }

  expect_failures = [var.pve_token_id]
}

# --- positive controls ----------------------------------------------------

run "accepts_a_well_formed_node" {
  command = plan

  variables {
    pve_token_id = "root@pam!terraform"
    nodes = {
      "k3s-node-1" = {
        vm_id       = 9101
        mac_address = "bc:24:11:c3:00:01"
        ip_address  = "10.20.0.11/24"
        gateway     = "10.20.0.1"
        nameservers = "10.20.0.1,1.1.1.1"
      }
    }
  }

  assert {
    condition     = length(proxmox_virtual_environment_vm.node) == 1
    error_message = "a fully-specified node should be accepted"
  }
}

run "accepts_a_node_with_no_optional_fields" {
  command = plan

  variables {
    nodes = {
      "k3s-node-1" = { vm_id = 9101 }
    }
  }

  assert {
    condition     = length(proxmox_virtual_environment_vm.node) == 1
    error_message = "mac_address and addressing are optional and may be omitted"
  }
}
