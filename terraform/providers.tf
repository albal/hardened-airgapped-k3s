# Authentication uses a Proxmox API token, not a password.
#
# Create it once on the PVE host:
#
#   pveum user token add root@pam terraform --privsep 0
#
# --privsep 0 matters: with privilege separation on, a fresh token inherits no
# permissions at all and every call comes back 403.
#
# The secret is only shown once. Put it in terraform.tfvars (gitignored) or
# export PROXMOX_VE_API_TOKEN='root@pam!terraform=<secret>' instead.
provider "proxmox" {
  endpoint  = var.pve_endpoint
  api_token = var.pve_token_secret == "" ? null : "${var.pve_token_id}=${var.pve_token_secret}"

  # Proxmox ships a self-signed certificate unless you have replaced it.
  insecure = var.pve_insecure
}
