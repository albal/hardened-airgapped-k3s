# Architecture

How the pieces fit together, and why they are arranged this way.

The whole design follows from one constraint: **the cluster nodes can never
reach the internet.** Everything that would normally be fetched on demand — a
container image, a Helm chart, a `.deb`, an installer script — has to be
identified, downloaded and carried across the gap in advance. Most of the
apparent complexity here is that constraint working itself out.

---

## 1. Two stages, one boundary

```mermaid
flowchart LR
    subgraph connected["Connected build host"]
        direction TB
        versions["config/versions.env<br/><i>every pin in one file</i>"]
        dl["scripts/01-download-artifacts.sh"]
        artifacts[("artifacts/<br/>~1.9 GB")]
        build["scripts/02-build-installer.sh"]
        img["installer image<br/>~2.4 GB"]
        run["dist/k3s-airgap-installer.run<br/><b>~1.9 GB, one file</b>"]

        versions --> dl --> artifacts --> build --> img --> run
    end

    subgraph airgap[" "]
        gap["✂ airgap<br/><i>USB / one-way transfer</i>"]
    end

    subgraph isolated["Airgapped network"]
        direction TB
        ws["Workstation<br/><i>Docker only</i>"]
        n1["node 1"]
        n2["node 2"]
        n3["node 3"]
        ws -->|SSH| n1
        ws -->|SSH| n2
        ws -->|SSH| n3
    end

    run --> gap --> ws

    style gap fill:#fff3cd,stroke:#856404,color:#856404
    style run fill:#d4edda,stroke:#155724,color:#155724
```

The `.run` file is a shell script with a gzipped Docker image appended to it.
Running it loads the image and starts the installer container; nothing else has
to exist on the airgapped side except Docker.

**Why a container rather than a tarball of scripts:** the installer needs
Ansible, `helm`, `kubectl`, `skopeo` and a matched set of Python libraries. On an
airgapped host you cannot install those. Shipping them inside an image is the
only way to guarantee the versions that were tested are the versions that run.

---

## 2. What is in the bundle, and who consumes it

```mermaid
flowchart TB
    subgraph bundle["/opt/airgap inside the installer image"]
        k3s["k3s/<br/>binary, install.sh<br/>+ image tarballs"]
        harbor["harbor/<br/>chart"]
        longhorn["longhorn/<br/>chart + image list"]
        kubevip["kube-vip/<br/>manifest template"]
        demo["demo/<br/>k3s-node-demo.tar"]
        debs["debs/<br/>per OS release"]
    end

    subgraph nodes["Every node"]
        agentimg["/var/lib/rancher/k3s/agent/images/<br/><i>k3s imports these at startup</i>"]
        apt["dpkg"]
    end

    k3s -->|"ansible copy"| agentimg
    harbor -->|"images ride along in k3s/"| agentimg
    longhorn -->|"images ride along in k3s/"| agentimg
    kubevip -->|"image rides along in k3s/"| agentimg
    debs -->|"only packages that are absent"| apt
    demo -->|"skopeo push"| hb["Harbor registry<br/><i>in the cluster</i>"]

    style hb fill:#cce5ff,stroke:#004085,color:#004085
```

Every image tarball is placed in the **same directory as the k3s bundle**, and
`roles/airgap` in the vendored collection copies `*.tar.zst` from there into
`/var/lib/rancher/k3s/agent/images/`. k3s imports whatever it finds there at
startup, so Harbor, Longhorn and kube-vip all have their images in containerd
before anything tries to pull them. That is the whole trick to a working
airgapped install, and it needs no code of our own.

The demo image is deliberately **not** preloaded. It is pushed into Harbor and
pulled back out again, so the demo proves the registry actually works rather
than quietly using a local copy.

---

## 3. Provisioning the nodes (optional)

```mermaid
flowchart TB
    tfvars["terraform.tfvars<br/><i>node names, MACs, IPs</i>"]

    subgraph iso["build-install-iso.sh"]
        detect{"What is in<br/>the ISO?"}
        preseed["Debian: preseed<br/>injected into the initrd"]
        auto["Ubuntu: autoinstall<br/>served from /nocloud/"]
        detect -->|"/install.amd"| preseed
        detect -->|"/casper"| auto
    end

    tfvars --> iso
    preseed --> out["…-preseed.iso"]
    auto --> out2["…-autoinstall.iso"]
    out --> pve
    out2 --> pve

    tfvars --> tf["terraform apply"]
    tf --> pve["Proxmox"]
    pve --> vms["3 VMs<br/>40 GB boot + 128 GB data"]
    vms -->|"unattended install"| ready["Debian 13 / Ubuntu 26.04<br/>hostname from MAC"]
```

One ISO installs all three machines. A preseed normally bakes in a single
hostname, which would produce three identically-named nodes — something
Kubernetes will not accept. Instead the ISO carries a **MAC-to-hostname table**
generated from `terraform.tfvars`, and a late script matches each machine
against it.

The flavour is detected from the ISO's *contents*, not its filename, because
Debian and Ubuntu share no configuration format: debian-installer reads a
preseed, Ubuntu Server runs subiquity autoinstall.

---

## 4. What the installer does

```mermaid
sequenceDiagram
    autonumber
    participant Op as Operator
    participant C as Installer container
    participant A as Ansible
    participant N as Nodes
    participant K as Cluster API

    Op->>C: ./k3s-airgap-installer.run
    C->>Op: node IPs, root password, VIP?
    C->>C: write inventory + vars.yml
    C->>N: SSH reachable? python3 present?
    C->>A: 00-preflight
    A->>N: OS, arch, RAM, disk, clock, VIP free?
    C->>C: render kube-vip manifest
    Note over C,N: manifest is copied to the nodes<br/>BEFORE k3s starts
    C->>A: 10-offline-packages
    A->>N: install only what is missing
    C->>A: k3s-ansible site.yml
    A->>N: distribute artifacts, install k3s
    N->>K: cluster up, kube-vip claims the VIP
    C->>A: 30-post-install
    A->>C: kubeconfig (pointed at the VIP)
    C->>K: Longhorn, then Harbor on Longhorn
    C->>K: push demo image, deploy DaemonSet
    C->>Op: SUMMARY.md, kubeconfig, password
```

The ordering matters in two places:

- **kube-vip is rendered before the k3s install**, because the manifest is
  delivered through the collection's `extra_manifests`, which copies it into
  `/var/lib/rancher/k3s/server/manifests/` during the prereq role. k3s applies
  whatever is in that directory as soon as its API is up, so the VIP appears
  without a second pass.
- **Longhorn is installed before Harbor**, because Harbor's volumes land on it.

---

## 5. Runtime topology

```mermaid
flowchart TB
    subgraph clients["Clients"]
        kubectl["kubectl"]
        browser["browser / docker push"]
    end

    vip{{"VIP<br/>kube-vip, ARP<br/><i>lives on one node at a time</i>"}}

    subgraph cluster["3 servers, embedded etcd"]
        direction TB
        subgraph n1["node 1"]
            k1["k3s server"]
            t1["Traefik + klipper-lb<br/>:80 :443"]
            l1["Longhorn<br/>/var/lib/longhorn"]
        end
        subgraph n2["node 2"]
            k2["k3s server"]
            t2["klipper-lb :80 :443"]
            l2["Longhorn"]
        end
        subgraph n3["node 3"]
            k3["k3s server"]
            t3["klipper-lb :80 :443"]
            l3["Longhorn"]
        end
        hb["Harbor<br/>NodePort 30002"]
        demo["node-demo DaemonSet<br/>NodePort 30080"]
    end

    kubectl -->|":6443"| vip
    browser -->|":80 ingress<br/>:30002 registry"| vip
    vip -.->|"currently held by"| n1
    browser -->|"per-node :30080"| demo

    l1 <-->|"replicas"| l2
    l2 <-->|"replicas"| l3
    l1 <-->|"replicas"| l3
    hb -->|"PVCs"| l1

    style vip fill:#d4edda,stroke:#155724,color:#155724
```

**Why the VIP needs no load-balancer integration.** k3s's ServiceLB
(klipper-lb) binds host ports 80 and 443 on *every* node for the Traefik
service. The VIP is simply an address on one of those nodes, so a request to
`http://<vip>/` arrives on a node that is already listening. kube-vip runs with
`svc_enable=false`; nothing else is required.

**What the VIP does not change.** The nodes still join through node 1's real
address when k3s is installed — pointing the join at the VIP would deadlock,
since the VIP only exists once kube-vip is running, which needs the API that the
join is trying to reach. The VIP is added to the API certificate's SANs from the
first start, so it is valid the moment it appears.

---

## 6. Where an image comes from

```mermaid
sequenceDiagram
    participant P as Pod
    participant K as kubelet
    participant C as containerd
    participant R as registries.yaml
    participant H as Harbor

    Note over C: at startup, k3s imported every<br/>*.tar.zst from agent/images/
    P->>K: needs <vip>:30002/library/k3s-node-demo:1.0
    K->>C: pull
    C->>R: how do I reach <vip>:30002?
    R-->>C: http:// endpoint (plain HTTP, no TLS)
    C->>H: GET manifest
    H-->>C: layers
    C-->>K: image ready
```

`registries.yaml` is what makes a plain-HTTP registry work: without the explicit
`http://` endpoint, containerd would assume TLS and fail. It is written to every
node by the collection's `registries_config_yaml`, pointed at the VIP when there
is one.

---

## 7. Storage

```mermaid
flowchart LR
    disk["/dev/sdX<br/><i>second disk, no signature</i>"]
    fs["ext4, LABEL=longhorn"]
    mnt["/var/lib/longhorn"]
    lh["Longhorn"]
    sc["StorageClass<br/><b>longhorn (default)</b>"]
    lp["local-path<br/><i>kept, not default</i>"]
    pvc["Harbor PVCs<br/>registry, db, redis, jobs"]

    disk -->|"node-prep formats it"| fs --> mnt --> lh --> sc --> pvc
    lh -.->|"3 replicas, one per node"| lh
    sc -.->|"demoted, and pinned<br/>so k3s stops re-applying it"| lp

    style sc fill:#d4edda,stroke:#155724,color:#155724
```

The mount is by **filesystem label, not device path**, and the disk is chosen by
*absence of any signature* rather than by name. That is not fastidiousness:
attaching a disk to a running Proxmox VM can enumerate it ahead of the boot
disk, and on this cluster two nodes ended up with the new disk as `/dev/sda` and
root on `/dev/sdb`, while the third was the other way round. Anything that
assumed `/dev/sdb` would have reformatted root on two of three machines.

Usable capacity is the disk size divided by the replica count — 128 GB disks
with 3 replicas gives roughly 128 GB of volumes, stored three times.

---

## 8. Tests and CI

```mermaid
flowchart TB
    subgraph pr["Every pull request (~2 min)"]
        sc["shellcheck + bash -n"]
        al["ansible-lint, yamllint,<br/>--syntax-check"]
        ut["unit: disk selection<br/>vs fake sysfs trees"]
        tt["terraform test<br/>mocked provider"]
    end

    subgraph demand["On demand"]
        it["integration:<br/>playbooks vs systemd containers"]
    end

    subgraph manual["By hand, on real nodes"]
        e2e["full install, VIP failover,<br/>iSCSI, node loss"]
    end

    pr --> demand --> manual

    style pr fill:#d4edda,stroke:#155724,color:#155724
    style manual fill:#fff3cd,stroke:#856404,color:#856404
```

What is *not* covered is written down in [tests/README.md](tests/README.md)
rather than left implied: kernel modules and `iscsid` cannot run in a container,
`mock_provider` checks the plan and not the apply, and a whole cluster coming up
is verified by running the installer against real machines.
