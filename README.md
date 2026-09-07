# hardened-airgapped-k3s

Build a 3-node [k3s](https://k3s.io) cluster with a private [Harbor](https://goharbor.io)
registry on bare-metal Ubuntu/Debian machines that have **no internet access**.

Everything ships as one self-executing file. On the airgapped side you run it, it
asks for the node IPs and the root password, and about fifteen minutes later you
have a cluster, a registry you can push your own images to, and a worked example:
an nginx pod on each node serving a page that says *Node 1*, *Node 2*, *Node 3*
along with that machine's details.

```
   connected build host                    airgap                 airgapped site
┌─────────────────────────┐                  ┊         ┌───────────────────────────┐
│ 01-download-artifacts   │  k3s + images    ┊         │  workstation with Docker  │
│ 02-build-installer      │  harbor chart    ┊  USB    │    ./…installer.run       │
│                         │  demo image      ┊  ────►  │        │ ssh              │
│   → …installer.run      │  ansible, helm   ┊         │        ▼                  │
└─────────────────────────┘                  ┊         │  node1  node2  node3      │
                                             ┊         └───────────────────────────┘
```

## What you get

| | |
|---|---|
| **Cluster** | k3s with embedded etcd on all three nodes, so it survives losing one |
| **VIP** *(optional)* | One floating address for the API, ingress and registry, so none of them depend on a single machine |
| **Storage** | Longhorn as the default StorageClass, replicating volumes across each node's second disk |
| **Registry** | Harbor, on Longhorn storage, reachable at `http://<vip-or-node1>:30002` and wired into every node's containerd |
| **Example** | An nginx DaemonSet pulled *from Harbor*, one pod per node, each page identifying its own machine |
| **Outputs** | `kubeconfig`, Harbor admin password, install log and a `SUMMARY.md` |

[`architecture.md`](architecture.md) has the diagrams: the two build stages, the
install sequence, the runtime topology and where every image comes from.

The k3s install itself is done by the upstream
[`k3s-io/k3s-ansible`](https://github.com/k3s-io/k3s-ansible) collection, vendored
here as a git submodule and driven in its airgap mode. This repository adds the
artifact bundling, the offline OS-package staging, Harbor, the demo, and the
single-file installer around it.

---

## Requirements

**Build host** (needs internet, once): Linux, Docker, `curl`, `tar`, ~4 GB free disk.
`zstd` is used if present.

**Airgapped workstation**: Linux with Docker and ~4 GB free disk. It must be able
to reach the nodes over SSH. It does **not** need to be a cluster node.

**Cluster nodes** (3 recommended): Ubuntu 22.04/24.04/26.04 LTS or Debian 12/13, x86-64,
2 vCPU / 4 GB RAM / 20 GB boot disk each, plus **a second empty disk for
Longhorn** (128 GB by default), with

- SSH reachable, root login with a password (or a sudo-capable user),
- `python3` installed — Ansible cannot run without it,
- unique hostnames, and clocks within 30s of each other (etcd is unforgiving).

Nothing else is required on the nodes: no Docker, no apt mirror, no internet.

If the nodes do not exist yet and you run Proxmox, [`terraform/`](terraform/)
creates the three VMs and installs Debian 13 or Ubuntu 26.04 LTS on them
unattended, from an ISO it builds for you.

---

## Build (on the connected host)

```sh
git clone --recurse-submodules <this repo>
cd hardened-airgapped-k3s
make all
```

That runs two stages:

1. **`scripts/01-download-artifacts.sh`** downloads into `artifacts/`:
   the k3s binary, install script and airgap image bundle (checksums verified
   against the release); the Harbor chart *and the exact images that chart
   renders* — the list is extracted with `helm template`, never hand-maintained;
   `helm` and `kubectl`; the demo image, built here from `nginx:alpine`; and
   `.deb` packages for the handful of OS dependencies an airgapped node cannot
   apt-get for itself.
2. **`scripts/02-build-installer.sh`** bakes all of that, plus Ansible and the
   `k3s-ansible` submodule, into a Docker image, then appends the image to a shell
   header to produce:

```
dist/k3s-airgap-installer.run          (~830 MB)
dist/k3s-airgap-installer.run.sha256
```

Versions are pinned in [`config/versions.env`](config/versions.env) — change them
there and re-run `make all`.

## Install (on the airgapped side)

Copy both files across, then:

```sh
sha256sum -c k3s-airgap-installer.run.sha256
./k3s-airgap-installer.run
```

```
  ? How many nodes [3]:
  ? IP address of node 1: 10.20.0.11
  ? IP address of node 2: 10.20.0.12
  ? IP address of node 3: 10.20.0.13
  ? SSH user [root]:
  ? SSH port [22]:
  ? Password for root@<node>:
```

It then works through twelve steps: connectivity, preflight, offline OS packages,
k3s, kubeconfig, data disks, Longhorn, Harbor, image push, demo deploy,
verification, summary. Results
land in `./k3s-airgap-output/`:

```
kubeconfig                 point KUBECONFIG at this
harbor-admin-password      admin password (mode 0600)
SUMMARY.md                 URLs, node table, how to push your own images
nodes.tsv, node-demo.yaml, cluster.env, logs/
```

Then:

```sh
export KUBECONFIG=$PWD/k3s-airgap-output/kubeconfig
kubectl get nodes -o wide
curl http://10.20.0.12:30080/          # -> "Node 2" and that machine's details
```

### Options

| Flag | Effect |
|---|---|
| `--output DIR` | where to write kubeconfig/passwords/logs |
| `--vip ADDRESS` | floating IP for the API, ingress and registry |
| `--vip-interface NIC` | NIC the VIP binds to (default: each node's default route) |
| `--no-vip` | do not configure a VIP, without being asked |
| `--skip-longhorn` | do not touch the data disks or install Longhorn |
| `--skip-harbor` | do not install Harbor (implies `--skip-demo`) |
| `--skip-demo` | do not deploy the example workload |
| `--reset` | uninstall k3s from the nodes |
| `--verify` | check the payload checksum before loading |
| `--load-only` | just `docker load` the image and exit |
| `-y` | do not ask for confirmation |

Non-interactive (for CI):

```sh
K3S_NODE_IPS=10.20.0.11,10.20.0.12,10.20.0.13 \
K3S_SSH_USER=root K3S_SSH_PASSWORD=... ASSUME_YES=1 \
./k3s-airgap-installer.run
```

`K3S_EXTRA_SERVER_ARGS` / `K3S_EXTRA_AGENT_ARGS` pass extra flags through to k3s.

---

## Loading your own images into Harbor

Harbor is published on a NodePort over plain HTTP, and every k3s node already
trusts it via `/etc/rancher/k3s/registries.yaml`. From any machine that can reach
it:

```sh
# one-time, on the pushing client:
echo '{"insecure-registries":["10.20.0.11:30002"]}' | sudo tee /etc/docker/daemon.json
sudo systemctl restart docker

docker login 10.20.0.11:30002                       # admin / <harbor-admin-password>
docker tag myapp:1.0 10.20.0.11:30002/library/myapp:1.0
docker push          10.20.0.11:30002/library/myapp:1.0
```

Then reference `10.20.0.11:30002/library/myapp:1.0` in a manifest. The installer
does exactly this for the demo image using `skopeo`, so the demo is a genuine
end-to-end test of the registry rather than a preloaded image.

Harbor's own images come from the airgap bundle: they are imported into each
node's containerd at k3s startup, so Harbor can start without a registry to pull
itself from.

---

## The virtual IP

Optional, and off unless you give it an address. Without one, everything is
reached per node and node 1 is a single point of failure for new image pulls —
which is the honest answer when there is no stable address to hand out.

With one, a single address serves all three:

```sh
./k3s-airgap-installer.run --vip 192.168.10.200
```

| | |
|---|---|
| `:6443` | the Kubernetes API — the emitted kubeconfig points here |
| `:80` / `:443` | Traefik, so Ingress resources work against one address |
| `:30002` | Harbor, so image pulls survive losing the node that first served them |

kube-vip runs as a DaemonSet on the servers in ARP mode; the address lives on
one node at a time and moves when that node goes away.

**Ingress needs nothing installed.** k3s already ships Traefik, and its
ServiceLB binds `:80`/`:443` on *every* node — so the VIP, being an address on
one of those nodes, answers on those ports with no load-balancer integration at
all. The demo gets an `Ingress` alongside its NodePort when a VIP is configured:
`http://<vip>/` balances across all three pods, so repeated requests report
different nodes, while `http://<node>:30080/` still shows that node's own page.

Two things worth knowing:

- **The nodes still join through node 1** when k3s is installed. Pointing the
  join at the VIP deadlocks: the VIP only exists once kube-vip is running, which
  needs the API the join is trying to reach. The VIP goes into the API
  certificate's SANs from the first start, so it is valid the moment it appears.
- **The address must be free and on the nodes' subnet.** kube-vip uses ARP.
  Preflight checks both, and refuses an address that already answers and is not
  a Kubernetes API server.

## Storage: Longhorn

Longhorn replicates every volume across the nodes, so a pod keeps its data when
the machine under it dies. It needs a whole disk per node, which is what the
second disk is for.

The installer formats that disk `ext4`, labels it `longhorn` and mounts it at
`/var/lib/longhorn` before installing the chart. The mount is by **label, not by
device path** — and that is not fussiness. Attaching a disk to a running Proxmox
VM can enumerate it *ahead* of the boot disk: on this cluster two nodes ended up
with the new disk as `/dev/sda` and root on `/dev/sdb`, while the third had it
the other way round. A hardcoded `/dev/sdb` would have reformatted root on two
of three machines.

For the same reason the playbook never takes a device name on trust. It only
touches a disk that has **no signature at all** — no partition table, no
filesystem, no LVM or RAID metadata — and stops rather than guessing if it finds
more than one candidate. Point `longhorn_data_device` at a specific disk to
override it.

```sh
kubectl get storageclass                       # 'longhorn' alongside k3s's local-path
kubectl -n longhorn-system get nodes.longhorn.io
```

**Longhorn is the default StorageClass.** A PVC that names no class gets
replicated storage rather than a directory pinned to one node. k3s's
`local-path` is still installed and usable by name, but the installer demotes it
so exactly one class claims the default — two would make the choice arbitrary.

**Harbor's volumes are on Longhorn**, which is the point: on `local-path` the
registry volume, and so every image in it, lived on whichever node happened to
schedule the pod first. With `--skip-longhorn` it falls back to `local-path`.

A PVC's class cannot be changed once it has bound, so this takes effect on a
first install; moving an existing Harbor means deleting its volumes. The
installer reads the existing class and reuses it rather than failing.

Usable capacity is the disk size divided by the replica count, not multiplied by
the node count: 128 GB disks with 3 replicas is ~128 GB of volumes, stored three
times.

The Longhorn UI has no authentication of its own, so it stays on a ClusterIP:

```sh
kubectl -n longhorn-system port-forward svc/longhorn-frontend 8080:80
```

Set `LONGHORN_UI_NODEPORT` in `config/versions.env` to publish it on every node
instead — reasonable on an isolated network, not otherwise.

## How the demo works

`demo/nginx/` builds a small image whose entrypoint renders a page at container
start. The installer deploys it as a **DaemonSet** with a **NodePort Service**
using `externalTrafficPolicy: Local`, so a request to a node's IP is always
answered by the pod on that node — each node IP shows its own page.

Per-node facts (OS, kernel, CPUs, memory, IP) are gathered by Ansible and handed
to the pods in a ConfigMap keyed by node name, rather than via a `hostPath` mount,
which keeps the namespace enforceable at the `restricted` Pod Security Standard.
The pods run as uid 101, non-root, read-only root filesystem, all capabilities
dropped.

## Tests

```sh
make test              # lint, unit and plan tests - no cluster needed
make test-integration  # playbooks against throwaway containers
```

GitHub Actions runs `make test` on every pull request. What is covered, and what
deliberately is not, is in [tests/README.md](tests/README.md).

## Layout

```
terraform/                   optional: create the three VMs on Proxmox
config/versions.env          every pinned version, in one place
scripts/                     stage 1 (download) and stage 2 (build)
docker/                      installer image + self-extracting header
installer/                   what runs on the airgapped side (entrypoint + libs)
ansible/playbooks/           preflight, offline packages, post-install
k3s-ansible/                 upstream k3s-io/k3s-ansible (submodule)
harbor/values-base.yaml      Harbor values, shared by the image list and the install
longhorn/values-base.yaml    Longhorn values
artifacts/kube-vip/          (generated) kube-vip manifest, from the pinned image
tests/                       unit, static and integration suites
architecture.md              how it all fits together, with diagrams
demo/                        the "Node N" image and its manifests
```

## Notes and limits

- **Without a VIP, Harbor's URL is node 1's IP**, so if node 1 is down new image
  pulls fail (running pods are unaffected). Pass `--vip` to fix that.
- **Harbor serves plain HTTP.** Fine on an isolated network, and it avoids
  distributing a CA to every client. For a hardened production build, enable
  `expose.tls` in `harbor/values-base.yaml` and add the CA to each node's
  `registries.yaml`.
- **k3s re-applies its bundled manifests every time a server starts**, which
  would put `local-path`'s default-class flag straight back and leave two classes
  claiming to be default. The installer drops a `local-storage.yaml.skip` file so
  k3s stops re-applying that one manifest; the StorageClass and its provisioner
  are untouched and still usable by name. The trade-off is that a k3s upgrade no
  longer refreshes the local-path provisioner - delete the `.skip` file on each
  server if you want that back.
- k3s runs with `secrets-encryption` enabled and a `0600` kubeconfig.
- Only Debian-family nodes are supported, because that is what the offline `.deb`
  staging covers. Add releases to `OFFLINE_DEB_IMAGES` in `config/versions.env`
  if you run something else — the id is `${ID}-${VERSION_ID}` from the node's
  `/etc/os-release`, and a release with no staged `.debs` fails preflight rather
  than installing half a cluster.
- **Longhorn needs `open-iscsi` on every node**, which Debian and Ubuntu do not
  install by default and an airgapped node cannot fetch. It is staged with the
  other offline `.debs`; the node-prep playbook stops with an explicit message if
  it is missing.
- **Ubuntu Server runs `multipathd`; Debian does not.** Left alone it claims the
  `/dev/sd*` devices Longhorn creates when attaching a volume, and volumes fail
  to mount. The node-prep playbook blacklists them — unless multipathd is
  managing real multipath devices, in which case it stops and leaves the
  decision to you rather than risking your existing storage.
