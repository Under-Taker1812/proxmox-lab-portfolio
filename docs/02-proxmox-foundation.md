# Proxmox Foundation

The physical layer: 4 servers, clustered, and the one VM template every workload in this lab is cloned from.

> ⚠️ **This is the single canonical source for "how a VM gets created" in this repo.** Cluster deployment docs later on (Rancher, Ceph) all clone from the template built here — they don't repeat the steps, they link back to this page.

## Why cluster the hypervisor layer at all

A Proxmox cluster isn't required to run VMs — a single standalone node works fine. It's worth doing anyway for two reasons that matter once the lab grows past "one server":

- **One web UI, one login, for every node.** Managing 4 nodes separately means 4 logins, 4 places to check status, and no shared view of where anything is running.
- **Ceph needs a cluster underneath it anyway.** The shared storage pool (see [`04-ceph-storage.md`](04-ceph-storage.md)) requires the nodes to already be clustered — clustering isn't optional once shared storage is the goal.

## Hardware

| Node | Role | Management IP |
|---|---|---|
| `proxmox-1` | Cluster member — hosts the pinned Rancher + observability hub | `<mgmt-ip-1>` |
| `proxmox-2` | Cluster member | `<mgmt-ip-2>` |
| `proxmox-3` | Cluster member | `<mgmt-ip-3>` |
| `proxmox-4` | Cluster member | `<mgmt-ip-4>` |

All four are HP ProLiant Gen9 servers on the same management VLAN. Network segmentation (why management traffic is on its own VLAN) is covered in [`03-networking-vlan-design.md`](03-networking-vlan-design.md).

> ⚠️ **Lab-only:** all four nodes share one root password and one Proxmox realm login. In a real production estate this would be per-admin accounts with RBAC (Proxmox supports this natively) — skipped here because the lab has exactly one operator.

## Installing Proxmox VE

1. Boot the target server from a Proxmox VE installer USB.
2. Run through the graphical installer: accept the EULA, pick the install disk, set locale/timezone, set the root password and admin email, fill in the static network config for that node.
3. Let it finish and reboot — **remove the USB before the reboot completes**, or it'll boot back into the installer.
4. Confirm the node is reachable: `https://<node-ip>:8006` (self-signed cert — browser will warn, that's expected) or SSH as `root`.

> 💡 **HP Gen9 quirk worth knowing:** these servers' GRUB is old enough that it doesn't load the ISO9660 filesystem (what the installer USB uses) by default, and pressing F11 for the boot menu is a tight window. If the server boots past that window into the old OS instead of the installer, recovery is: drop to the `grub>` prompt, `insmod iso9660`, then `ls (hdN)/` through each disk until the USB is found, then `chainloader (hdN)/efi/boot/grubx64.efi` and `boot`. Using GRUB's `configfile` command instead of `chainloader` fails here — the old GRUB environment is missing a symbol (`grub_calloc`) that a newer GRUB config expects, and it crashes instead of chaining properly.

## Forming the cluster

Once all four nodes have Proxmox installed independently:

1. On the first node's web UI: **Datacenter → Cluster → Create Cluster**, give it a name.
2. Copy the **Join Information** token it generates.
3. On each remaining node: **Datacenter → Cluster → Join Cluster**, paste the token.

Verify from any node: `pvecm status` should list all 4 members.

> 🚨 **Two commands that will cost you physical console access if run on a live node.** Recovery requires a monitor and keyboard plugged directly into the server — there is no remote path back once `pve-cluster` is down.

```bash
# NEVER run these on a node you're currently relying on to reach the cluster:
systemctl stop pve-cluster    # kills the web UI, SSH, and the login realm on that node
systemctl stop corosync       # drops the node out of the cluster mid-operation
```

If it happens anyway: log in at the physical console and run `systemctl start pve-cluster && systemctl start corosync && systemctl restart pvedaemon pveproxy`.

## Removing a node from the cluster

```bash
# Power the node off first, then run this from a DIFFERENT, still-healthy node:
pvecm delnode <node-name>
pvecm status   # confirm it's gone
```

The GUI equivalent only works once the target node shows offline (red) in the sidebar — right-click its name → **Remove**.

## Building the VM template

Every VM in this lab — Rancher, the observability hub, every Kubernetes node — is a **Full Clone** of one template. Building it once, correctly, means every clone downstream inherits the same clean baseline.

### 1. Install the base OS

Boot a fresh VM from an Ubuntu Server ISO, install normally, reboot, detach the ISO. Nothing special yet — this is a throwaway install that becomes the template.

### 2. Attach a Cloud-Init drive

This is the step that's easy to skip and breaks everything downstream if you do: **VM → Hardware → Add → CloudInit Drive**. Without it, Proxmox has no way to inject SSH keys, users, or network config into clones — every clone would need manual setup.

### 3. Configure Cloud-Init

**VM → Cloud-Init**, set:

| Field | Value used here |
|---|---|
| User | `master` |
| Password | *(placeholder — set your own; see the lab-only note below)* |
| SSH public key | `ssh-ed25519 AAAA...<redacted> proxmox-cluster` |
| IP config | DHCP |
| Upgrade packages | Yes |

> ⚠️ **Lab-only:** the actual password on this cloud-init config is a single short string, reused across every VM in the lab. It's acceptable here because the whole environment is single-operator and network-isolated behind a VLAN with no internet-facing exposure — it is **not** a pattern to copy into anything internet-reachable.

### 4. Install baseline packages

```bash
sudo apt update && sudo apt upgrade -y
sudo apt install -y curl wget vim net-tools iputils-ping \
  openssh-server ca-certificates gnupg htop qemu-guest-agent
```

| Package | Why it's here |
|---|---|
| `qemu-guest-agent` | lets Proxmox read the VM's real IP/memory and shut it down cleanly from the UI, instead of a hard power cut |
| `ca-certificates gnupg` | needed before adding any third-party apt repo (Docker, Kubernetes) later |
| everything else | baseline tooling every downstream role needs regardless of what it becomes |

Enable the agent on the Proxmox side too — **VM → Options → QEMU Guest Agent → Enable** — then confirm it's actually running: `systemctl status qemu-guest-agent` should show `active (running)`. It's a static unit; it doesn't need `systemctl enable`, Proxmox activates it.

### 5. Clean the VM before templating it

Every one of these matters — skipping any of them means every clone inherits a value that's supposed to be unique per-VM:

```bash
sudo -i
rm -f /etc/ssh/ssh_host_*        # host keys — a clone must generate its own, not share the template's
truncate -s 0 /etc/machine-id     # shared machine-id across clones causes DHCP lease conflicts
cloud-init clean                  # cloud-init tracks "have I already initialized this instance" — reset it
truncate -s 0 ~/.bash_history && history -c
apt clean
poweroff
```

### 6. Convert to template

```bash
qm template <vmid>
```

Or via the UI: right-click the VM → **Convert to template**. A template can be converted back to a regular VM (`qm set <vmid> --template 0`) if it needs edits later — but if you do that, repeat step 5 before converting it back, otherwise every future clone inherits whatever state the edit session left behind.

## Cloning a VM from the template

This is the operation every other doc in this repo means when it says "provision a new VM":

```bash
qm clone <template_vmid> <new_vmid> --name <name> --full
```

**Full Clone**, not linked clone — a linked clone stays dependent on the template's disk existing forever, which defeats the point of an immutable, reusable template. On first boot, cloud-init runs automatically: creates the `master` user, injects the SSH key, requests a DHCP lease, and the new IP shows up in **Summary** within seconds thanks to `qemu-guest-agent`.

> In this repo, this exact clone operation is what [`ansible/playbooks/01-create-vms.yml`](../ansible/playbooks/01-create-vms.yml) automates — same underlying `qm clone`, driven by the Proxmox API instead of the UI.

## Troubleshooting the template flow

**Cloud-init shows as disabled on a clone.** Happens if a VM was installed from ISO and cloud-init already ran and locked itself once before templating. Fix: `sudo cloud-init clean && sudo reboot`, then confirm with `sudo cloud-init status` → should read `status: done`.

**SSH host key mismatch when connecting to a new clone.** Expected if that IP was previously assigned to a different VM — SSH remembers the old fingerprint. Fix: `ssh-keygen -f '/root/.ssh/known_hosts' -R '<ip>'`, then reconnect.
