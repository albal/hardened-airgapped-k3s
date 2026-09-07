# Tests

```sh
make test              # everything that runs without a cluster
make test-terraform    # terraform test, mocked provider     (~10s)
make test-ansible      # unit + static checks                (~30s)
make test-integration  # playbooks against systemd containers (~4 min, needs Docker)
```

`make test` is what CI runs on every pull request. `test-integration` needs
Docker and privileged containers, so it is a local and on-demand target.

## What is covered

| Suite | Where | Covers |
|---|---|---|
| `terraform/tests/*.tftest.hcl` | `make test-terraform` | VM shape (disks, agent, boot order, MACs) and every `validation` block, with a mocked Proxmox provider — no credentials, no network |
| `tests/ansible/unit/` | `make test-ansible` | The disk-selection rules, against fake sysfs trees |
| `tests/ansible/run-static.sh` | `make test-ansible` | Playbook syntax (including the vendored `site.yml`), `ansible-lint`, `yamllint` |
| `tests/ansible/run-integration.sh` | `make test-integration` | Preflight assertions, offline package staging and idempotency, and the Longhorn prerequisites — against real systemd containers over SSH |

## What is deliberately *not* covered, and why

Being straight about the gaps is more useful than a green tick that means less
than it looks like it does.

- **Kernel modules and iscsid.** A container has no `/lib/modules` of its own,
  and loading a module from one would affect the host kernel. Those two tasks
  carry `tags: [iscsi]` and the integration suite runs `--skip-tags iscsi`. They
  are exercised on real nodes.
- **Which disk gets formatted, on real hardware.** A container cannot present a
  spare `/dev/sd*`, and the detection deliberately skips `loop*`. The *rules*
  are unit-tested exhaustively against fake sysfs trees — including the case
  that actually bit us, where a hot-plugged disk enumerates ahead of the boot
  disk so the empty one is `sda` and root is on `sdb`. The final mile is
  verified on VMs.
- **A real Proxmox API.** `mock_provider` checks the plan, not the apply.
  `terraform/check-token.sh` is the live-credential check.
- **The full bundle build.** ~2 GB of downloads and a 2.4 GB image; far too slow
  for a pull request. Run `make all` before shipping.
- **A whole cluster.** k3s, Longhorn and Harbor coming up together is verified
  by running the installer against real nodes.

## Adding to the suites

The integration harness has one rule worth knowing: **capture the run, then
match it.** Piping straight into `grep` does not work, because `set -o pipefail`
is on and most of these playbooks are *expected* to fail — the pipeline would
report the playbook's exit status rather than whether the message appeared. Use
the `expect_output` helper, which also prints the last lines of a failed run so
you can see what actually happened.

**Run it the way CI does, at least once.** The harness prefers the full
installer image and falls back to a minimal ansible runner when it is absent —
which is what a GitHub runner always gets. The two are not interchangeable: the
installer image bakes in `/opt/airgap/debs`, the minimal runner has nothing
there, and that difference passed locally and failed in CI. `MINIMAL_RUNNER=1
make test-integration` forces the fallback even when the installer image is
built.

Each test also sets up its own preconditions. Tests that share a container are
otherwise order-dependent: a test asserting "this fails when the packages are
missing" proves nothing if an earlier test installed them.
