# Proxmox VMs for the k3s cluster

Creates three VMs on the Proxmox host `pve`
(<https://pve.office.tsew.net:8006>), each attached to an install ISO, ready to
run the airgapped installer against.

Debian 13 and Ubuntu 26.04 LTS are both supported. They use completely
different unattended-install mechanisms — debian-installer preseed and
subiquity autoinstall — and `build-install-iso.sh` picks the right one by
looking at what is actually inside the ISO.

Run `build-install-iso.sh` first and the guests install themselves — UK locale,
GMT, root password, per-node hostnames — so `terraform apply` leaves you with
three finished Debian nodes. See [Unattended install with
preseed](#unattended-install-with-preseed).

## One-time setup on the Proxmox host

```sh
pveum user token add root@pam terraform --privsep 0
```

`--privsep 0` matters. With privilege separation left on, a new token starts
with no permissions of its own and every API call comes back `403`. The secret
is printed once and cannot be retrieved again.

If the token already exists and was created without that flag, you do not need
to recreate it — the secret stays valid:

```sh
pveum user token modify root@pam terraform --privsep 0
```

Or, to keep privilege separation on, grant the token rights explicitly:

```sh
pveum acl modify / --tokens 'root@pam!terraform' --roles Administrator
```

## Check the token before applying

```sh
./check-token.sh
```

Confirms the endpoint is reachable, the token authenticates, it actually carries
permissions, the node is visible and the ISO is where `iso_file_id` says it is.
Worth running first: a token without permissions authenticates perfectly and
then fails at VM-create time with nothing but

```
error creating VM: received an HTTP 403 response - Reason: Permission check failed
```

which does not point at privilege separation at all.

## Configure

`terraform.tfvars` is already filled in with your endpoint, node name, ISO path
and three nodes. Paste the token secret into it:

```hcl
pve_token_secret = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
```

That file is gitignored, so the secret stays out of the repository. If you would
rather keep it out of files entirely, leave the variable empty and export:

```sh
export PROXMOX_VE_API_TOKEN='root@pam!terraform=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx'
```

## Apply

```sh
cd terraform
terraform init
./check-token.sh
terraform plan
terraform apply
```

Defaults per VM: 4 vCPU, 8 GB RAM, a 40 GB boot disk and a **128 GB data disk**
on `local-lvm`, one virtio NIC on `vmbr0`, and VM IDs 9101–9103. Change any of it
in `terraform.tfvars`.

The second disk is left completely blank; the airgapped installer formats it and
gives it to Longhorn. Set `data_disk_size = 0` if you do not want one.

Adding the data disk to VMs that already exist is an in-place update — no
rebuild, no reboot. Be aware that a hot-plugged disk can enumerate ahead of the
boot disk, so `/dev/sda` may become the *new* disk and root may move to
`/dev/sdb`. Nothing here depends on those names (the installer selects by
signature and mounts by filesystem label), but do not write scripts of your own
that assume `/dev/sdb` is the data disk.

The disk is first in the boot order and the ISO second. A blank disk is not
bootable, so the firmware falls through to the installer on the first boot, and
once Debian is on disk the VM boots straight into it — you never have to detach
the ISO.

## Unattended install

`build-install-iso.sh` turns a stock ISO into one that installs itself, so
`terraform apply` gives you three finished nodes rather than three consoles
waiting for someone to click through an installer.

| ISO | Mechanism | Config in |
|---|---|---|
| `debian-*-netinst.iso` | preseed, injected into the installer's initrd | `preseed/` |
| `ubuntu-*-live-server-*.iso` | subiquity autoinstall, served from `/nocloud/` | `autoinstall/` |

The flavour is detected from the ISO's contents, not its filename, so a renamed
image still builds correctly. The output is named for the mechanism used —
`…-preseed.iso` or `…-autoinstall.iso` — and re-running with `iso_file_id`
already pointing at a built ISO works, rather than producing
`…-preseed-preseed.iso`.

```sh
./build-install-iso.sh          # build, then upload to Proxmox
```

Then set the ISO it prints in `terraform.tfvars` and apply:

```hcl
iso_file_id = "local:iso/debian-13.6.0-amd64-netinst-preseed.iso"
```

On Debian the preseed goes into the ISO's **initrd** as `/preseed.cfg`, which
debian-installer reads before it asks its first question. On Ubuntu the
autoinstall config is served from `/nocloud/` on the ISO via cloud-init's
NoCloud datasource. Either way there is no HTTP server and nothing typed at the
boot prompt — the two usual ways of doing this — and the boot menu is replaced
with a single entry that starts on its own after one second.

What the guests come up as:

| | |
|---|---|
| Locale | `en_GB.UTF-8`, `GB` country, `gb` console keymap |
| Time zone | `Etc/GMT` — deliberately not `Europe/London`, so servers do not jump an hour in March. The hardware clock is UTC either way. |
| Root password | `password`, with SSH root login and password auth enabled |
| Users | none — the airgapped installer logs in as root |
| Partitioning | whole first disk, one partition, auto-detected so it works as `sda` or `vda` |
| Packages | `python3` (Ansible needs it), `qemu-guest-agent`, `open-iscsi`, `nfs-common` and `cryptsetup` (Longhorn needs them), plus the base server set |
| Disks | the **smallest** disk is the boot disk — that is what keeps the installer off Longhorn's 128 GB data disk |
| Hostname | taken from the `nodes` map by matching the machine's MAC |
| Kernel | `systemd.ssh_auto=no` — stops systemd-ssh-generator probing for an AF_VSOCK device Proxmox does not attach, which otherwise logs an error on every `daemon-reload` and floods the console |

Override any of the first four without editing the template:

```sh
PRESEED_TIMEZONE=Europe/London PRESEED_ROOT_PASSWORD='something better' \
  ./build-install-iso.sh
```

### Ubuntu specifics

Two things differ beyond the config format, and both are handled:

- **The mirror.** Ubuntu's suites do not exist on `deb.debian.org`, so pointing
  autoinstall at the Debian mirror makes every apt call 404 and the install dies
  part-way through installing packages. Ubuntu gets `gb.archive.ubuntu.com`;
  override with `PRESEED_UBUNTU_MIRROR_URL`.
- **Root login.** Ubuntu locks the root account and autoinstall insists on
  creating an unprivileged user, so the late command sets root's password and
  drops in the sshd config the airgapped installer needs. The unprivileged
  account is `ubuntu` by default (`INSTALL_ADMIN_USER`).

Static addressing is netplan on Ubuntu and `/etc/network/interfaces` on Debian;
the builder emits whichever the target uses.

### One ISO, three different machines

A preseed normally bakes in a single hostname, which would give you three nodes
all called the same thing — something Kubernetes will not accept. Instead the
ISO carries a MAC-to-hostname table generated from the `nodes` map in
`terraform.tfvars`, and a late script matches each machine against it. That is
why `mac_address` is required on every node.

The same table optionally carries a static address. Leave `ip_address` out and
the guest uses DHCP; set it and the installer writes a static configuration, so
you know every node's address before it has booted once:

```hcl
"k3s-node-1" = {
  vm_id       = 9101
  mac_address = "BC:24:11:C3:00:01"
  ip_address  = "10.20.0.11/24"
  gateway     = "10.20.0.1"
  nameservers = "10.20.0.1"
}
```

Changing any of that means rebuilding and re-uploading the ISO
(`./build-install-iso.sh --force`) before re-creating the VMs.

Installs take roughly ten minutes per node and run in parallel. Watch one from
the Proxmox console if you like — `terraform output vms` prints direct links —
but nothing needs a keypress.

The build caches the stock ISO next to the preseeded one in `.iso/`, so expect
about 1.5 GB there. Both are gitignored.

### If an install stops

A preseed that misses a question does not error — the installer quietly puts a
dialog on a console nobody is watching, and the machine sits there. Two places
to look:

- **A dialog on the console.** Some question in `preseed/preseed.cfg.tmpl` was
  not answered. Note which one and add it.
- **The `[!!] Choose the next step` menu.** A step returned "backed up".
  `grep -i finish-install /var/log/syslog` on tty2 (Alt-F2 in the console) names
  the script that did it.

`/var/log/d-i-finish.log`, both in the installer and copied onto the installed
system, records which node the machine was matched to and what was configured.

Three things that bit during development, in case you change the template:

- Packages added to `pkgsel/include` bring their own debconf questions.
  `keyboard-configuration` asks for a layout *and* a variant; answering only
  `xkb-keymap` leaves the variant question to stop the install.
- Do not `apt-get` from `late_command` via `in-target` with `DEBIAN_FRONTEND`
  overridden. It desynchronises d-i's debconf passthrough and the *next* step
  fails with a misleading "backed up".
- `/etc/vconsole.conf` on Debian is a symlink to `/etc/default/keyboard`.
  Writing both means the second write silently destroys the first.

## After apply

With the preseed ISO, the nodes install themselves, reboot into Debian and are
ready. Confirm one with:

```sh
ssh root@<node-ip>        # password: password
```

Then, from a workstation that can reach all three:

```sh
../dist/k3s-airgap-installer.run
```

If you used the **stock** ISO instead, the VMs are sitting at the installer and
you get to do it by hand. Four things matter for the k3s installer that follows:

| | Why |
|---|---|
| **A distinct hostname per VM** | Kubernetes uses the hostname as the node name; duplicates fail preflight |
| **SSH server** (select it in tasksel) | the installer reaches the nodes over SSH |
| **Root login with a password** | set `PermitRootLogin yes` in `/etc/ssh/sshd_config`, or use a sudo-capable user |
| **"standard system utilities"** in tasksel | this is what brings in `python3`, which Ansible cannot run without |

Give each machine a static IP, or add a DHCP reservation for the MAC address
Terraform assigned — `terraform output mac_addresses`.

### Guest agent

On by default. The preseed installs `qemu-guest-agent`, so Proxmox reports each
guest's IP and hostname, `terraform output ipv4_addresses` is populated, and a
shutdown asks the guest to shut down rather than cutting its power.

Terraform treats a VM as created only once the agent answers, and on a first
apply nothing can answer until Debian has finished installing and rebooted —
so `qemu_agent_timeout` defaults to `30m` rather than the provider's `15m`.
Expect a first `terraform apply` to sit for roughly ten minutes per node while
the installs run. That is the agent being waited for, not a hang.

Set `qemu_agent_enabled = false` if you install the guests by hand from the
stock ISO without the agent. Declaring an agent that never runs makes every
apply wait out the full timeout.

## Security note

The root password is `password` and root may log in over SSH with it. That is
what makes the unattended install work, and it is fine on an isolated lab
network. Before these machines see anything real:

```sh
passwd                                        # on each node
rm /etc/ssh/sshd_config.d/99-k3s-installer.conf   # once you have keys in place
systemctl restart ssh
```

The password is baked into the ISO in plain text, so treat the built ISO as a
credential too — it is in `.iso/`, which is gitignored.

## Destroy

```sh
terraform destroy
```

`stop_on_destroy` is set, so running VMs are powered off first.
