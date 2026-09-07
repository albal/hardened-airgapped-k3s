# ---------------------------------------------------------------------------
# Proxmox connection
# ---------------------------------------------------------------------------
variable "pve_endpoint" {
  description = "Proxmox VE API endpoint, including the port."
  type        = string
  default     = "https://pve.office.tsew.net:8006/"
}

variable "pve_node" {
  description = "Name of the Proxmox node the VMs are created on."
  type        = string
  default     = "pve"
}

variable "pve_token_id" {
  description = "API token id, in the form user@realm!tokenname."
  type        = string
  default     = "root@pam!terraform"

  validation {
    condition     = can(regex("^[^!]+@[^!]+![^!]+$", var.pve_token_id))
    error_message = "pve_token_id must look like 'root@pam!terraform'."
  }
}

variable "pve_token_secret" {
  description = <<-EOT
    The API token secret (the UUID shown once when the token was created).
    Leave empty to fall back to the PROXMOX_VE_API_TOKEN environment variable.
  EOT
  type        = string
  sensitive   = true
  default     = ""
}

variable "pve_insecure" {
  description = "Skip TLS verification. Needed while Proxmox uses its self-signed certificate."
  type        = bool
  default     = true
}

# ---------------------------------------------------------------------------
# Hardware
# ---------------------------------------------------------------------------
variable "iso_file_id" {
  description = <<-EOT
    Install media, as a Proxmox volume id ('<storage>:iso/<file>').
    /var/lib/vz is the 'local' storage, so a file dropped in
    /var/lib/vz/template/iso/ is addressed as local:iso/<file>.
  EOT
  type        = string
  default     = "local:iso/debian-13.6.0-amd64-netinst.iso"
}

variable "datastore_id" {
  description = "Storage for the VM disks. 'local-lvm' is the Proxmox default."
  type        = string
  default     = "local-lvm"
}

variable "network_bridge" {
  description = "Bridge the VMs attach to."
  type        = string
  default     = "vmbr0"
}

variable "vlan_id" {
  description = "VLAN tag for the VM NICs. null leaves the NIC untagged."
  type        = number
  default     = null
}

variable "cpu_type" {
  description = "QEMU CPU model. 'host' is fastest and fine when you do not live-migrate."
  type        = string
  default     = "host"
}

variable "machine_type" {
  description = "QEMU machine type."
  type        = string
  default     = "q35"
}

variable "default_cores" {
  description = "vCPUs per VM unless overridden per node."
  type        = number
  default     = 4
}

variable "default_memory" {
  description = "RAM in MB per VM unless overridden per node. k3s plus Harbor wants 8 GB."
  type        = number
  default     = 8192
}

variable "default_disk_size" {
  description = "Boot disk size in GB per VM unless overridden per node."
  type        = number
  default     = 40
}

variable "data_disk_size" {
  description = <<-EOT
    Size in GB of the second disk on each VM, given to Longhorn for replicated
    storage. Set to 0 to attach no data disk at all.

    Longhorn keeps a full replica per node, so usable capacity is roughly this
    size divided by the replica count, not multiplied by the node count.
  EOT
  type        = number
  default     = 128
}

variable "data_disk_datastore_id" {
  description = "Storage for the data disks. Defaults to datastore_id."
  type        = string
  default     = null
}

variable "qemu_agent_enabled" {
  description = <<-EOT
    Whether the VMs are configured to expect the QEMU guest agent.

    The preseed ISO installs qemu-guest-agent, so this is on by default: Proxmox
    then reports guest IPs and hostnames, `terraform output ipv4_addresses`
    works, and a graceful shutdown actually shuts the guest down rather than
    pulling the virtual power cord.

    Set it to false if you install the guests by hand from the stock ISO without
    the agent. Terraform waits for the agent to answer before it considers a VM
    created, so declaring an agent that never runs makes every apply hang until
    qemu_agent_timeout expires.
  EOT
  type        = bool
  default     = true
}

variable "qemu_agent_timeout" {
  description = <<-EOT
    How long to wait for the guest agent to answer.

    This has to cover a first apply, where the VM is created, boots the preseed
    ISO and installs Debian before anything can respond - about ten minutes per
    node. The provider's own default of 15m leaves very little room for a slow
    mirror, so this is deliberately generous.
  EOT
  type        = string
  default     = "30m"
}

variable "start_on_create" {
  description = "Power the VMs on after creating them, so they land in the Debian installer."
  type        = bool
  default     = true
}

# ---------------------------------------------------------------------------
# The VMs themselves
# ---------------------------------------------------------------------------
variable "vm_name_prefix" {
  description = "Prefixed to every key in `nodes` to form the VM name."
  type        = string
  default     = ""
}

variable "nodes" {
  description = <<-EOT
    The VMs to create, keyed by name. Every field except vm_id is optional and
    falls back to the default_* variables.

    mac_address is required when installing from the preseed ISO: one ISO
    installs every machine, and the installer tells the nodes apart by MAC to
    decide which hostname (and static address) each one gets.

    ip_address/gateway/nameservers are optional. Leave them out and the guest
    takes its address from DHCP; set them and the preseed configures the
    interface statically, so you know every node's address before it boots.
  EOT
  type = map(object({
    vm_id       = number
    cores       = optional(number)
    memory      = optional(number)
    disk_size   = optional(number)
    mac_address = optional(string)
    description = optional(string)

    # Consumed by build-preseed-iso.sh, not by the VM resource itself.
    ip_address  = optional(string) # e.g. "10.20.0.11/24"
    gateway     = optional(string) # e.g. "10.20.0.1"
    nameservers = optional(string) # comma separated, e.g. "10.20.0.1,1.1.1.1"

    data_disk_size = optional(number) # overrides var.data_disk_size for this node
  }))

  validation {
    condition     = length(var.nodes) > 0
    error_message = "At least one node must be defined."
  }

  validation {
    condition     = length(distinct([for n in var.nodes : n.vm_id])) == length(var.nodes)
    error_message = "Each node needs a unique vm_id."
  }

  validation {
    condition = alltrue([
      for n in var.nodes :
      n.mac_address == null || can(regex("^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$", coalesce(n.mac_address, "")))
    ])
    error_message = "mac_address must be six colon-separated hex octets, e.g. BC:24:11:00:00:01."
  }

  validation {
    condition = alltrue([
      for n in var.nodes :
      n.ip_address == null || can(regex("^([0-9]{1,3}\\.){3}[0-9]{1,3}/[0-9]{1,2}$", coalesce(n.ip_address, "")))
    ])
    error_message = "ip_address must include the prefix length, e.g. \"10.20.0.11/24\"."
  }
}

variable "tags" {
  description = "Tags applied to every VM."
  type        = list(string)
  default     = ["terraform", "k3s"]
}
