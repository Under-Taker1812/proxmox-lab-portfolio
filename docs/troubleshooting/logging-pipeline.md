# Logging Pipeline Bugs

> 📜 **Historical note before reading:** these bugs were found running a per-cluster Rancher Logging operator (Fluentd + a `Logging`/`FluentbitAgent` custom-resource stack) — the architecture this lab used *before* switching to the much simpler design in [`08-observability-hub.md`](../08-observability-hub.md) (a plain `fluent-bit` DaemonSet forwarding straight to the centralized hub, no operator, no per-cluster Elasticsearch). Some of these bugs are specific to the operator this lab no longer runs; they're kept here because the underlying lessons — Ceph, sysctl, etcd I/O — apply regardless of which logging stack sits on top.

## Why the operator got retired

Bugs #4, #5, and #7 below all trace back to the same root frustration: **the operator added a translation layer between "what I set in Helm values" and "what actually gets scheduled,"** and that layer had its own bugs, its own CRDs, and its own failure modes to learn on top of Kubernetes' own. Running `fluent-bit` directly — one DaemonSet, one ConfigMap, no operator reconciling anything on top — removed an entire category of bugs by removing the layer that caused them. That trade-off (less abstraction, more explicit config) is a recurring theme in this repo's architecture decisions.

## Bug — new node missing the storage VLAN interface

**Symptom:** an Elasticsearch PVC stuck `Pending`, CSI logs showing `rados: ret=-110, Connection timed out`.

**Root cause:** a node added to the cluster *after* the storage VLAN was already set up didn't inherit the second NIC every earlier node had — it had no route to any Ceph monitor at all.

```bash
ip addr show <storage-nic>   # no address assigned — this is the tell
ping <a-ceph-monitor-ip>     # times out, confirming no route exists
```

**Fix — assign it, then persist the assignment** (a live `ip addr add` doesn't survive reboot):
```yaml
# /etc/netplan/60-storage.yaml
network:
  version: 2
  ethernets:
    <storage-nic>:
      addresses:
        - <storage-vlan-ip>/24
```

**The lesson:** every "add a node" runbook needs to include storage-VLAN NIC setup explicitly — it's easy to assume a template already covers it when the template was built *before* the storage VLAN existed.

## Bug — Elasticsearch stuck in `Init`, kernel setting too low

**Symptom:** the ES pod stuck at `Init:0/1`, or its `configure-sysctl` init container failing outright.

**Root cause:** Elasticsearch 8.x requires `vm.max_map_count ≥ 262144` (Linux defaults to roughly a quarter of that). The chart's usual fix — a privileged init container that sets this automatically — was blocked by this cluster's pod security policy.

**Fix — set it on the host directly, and disable the init container that would otherwise try and fail:**
```bash
sysctl -w vm.max_map_count=262144
echo "vm.max_map_count=262144" >> /etc/sysctl.conf
```
```
--set sysctlInitContainer.enabled=false
```

## Bug — a recreated pod can't remount its volume

**Symptom:** `an operation with the given Volume ID already exists` in the CSI logs; the PVC shows `Bound`, but the new pod sits in `ContainerCreating` indefinitely.

**Root cause:** the CSI node plugin keeps an in-memory lock per volume ID. Deleting and recreating a pod fast enough means kubelet's own volume-manager cache still thinks the old mount is active when the CSI plugin gets the request for the new one — and it refuses, correctly by its own logic, to double-mount.

**Fix, and the order matters:**
```bash
kubectl delete pod <old-pod> -n <namespace>          # release kubelet's cache first
systemctl restart rke2-agent                          # on the node that had the stuck mount
kubectl delete pod -n kube-system -l app=csi-rbdplugin --field-selector spec.nodeName=<node>
```

## Bug — a Helm flag's type wasn't what it looked like

**Symptom:** `cannot unmarshal bool into Go struct field ... nodeSelector of type string`.

**Root cause:** `--set nodeSelector.monitoring=true` — Helm's `--set` infers types, and `true` gets parsed as a boolean. Kubernetes' `nodeSelector` field expects string values (`"true"`, not `true`) even for what reads like a boolean flag.

**Fix:** `--set-string nodeSelector.monitoring=true` — forces string type regardless of what the value looks like.

## Bug — a failed Helm install left permanent wreckage behind

**Symptom:** every subsequent `helm install` attempt for the same chart failed with `already exists` on resources that were never successfully installed.

**Root cause:** a Helm `pre-install` hook creates resources (ServiceAccount, Role, ConfigMap, a one-shot Job) *before* the main install runs. When the hook itself fails, Helm doesn't roll those resources back — they're orphaned, and they collide with the next install attempt.

**Fix — clean up every resource type the hook could have created, in an order that respects Kubernetes' own dependency order, before retrying:**
```bash
kubectl delete deployment,service,job,pod,replicaset -n <ns> -l app=<app> 2>/dev/null
kubectl delete serviceaccount pre-install-<app> -n <ns> 2>/dev/null
kubectl delete role,rolebinding pre-install-<app> -n <ns> 2>/dev/null
kubectl delete configmap <app>-helm-scripts -n <ns> 2>/dev/null
helm uninstall <app> -n <ns> --no-hooks 2>/dev/null
# then confirm genuinely empty before reinstalling:
kubectl get all,configmap,secret,serviceaccount,role,rolebinding -n <ns> | grep -i <app>
```

## Bug — slow disk made `etcd` reject writes mid-install

**Symptom:** `Error: UPGRADE FAILED: ... etcdserver: request timed out` while a chart with many CRDs was installing.

**Root cause:** this control-plane VM's underlying disk had write latency in the 100–340ms range — well past etcd's own ~100ms warning threshold. Installing many CRDs at once means many etcd writes in a short window; a slow disk simply couldn't commit them fast enough, and etcd timed the operation out.

**Diagnosis:**
```bash
kubectl -n kube-system logs etcd-<node> --tail=20 | grep -E "apply request took too long|request timed out"
```

**Fix:** most of the time, the CRDs *did* get created before the timeout — `kubectl get crd | grep <name>` confirms this — so the fix is usually just retrying the main chart install without reinstalling CRDs that already exist, not chasing a disk upgrade for a one-time install operation.

## Bug — one `nodeSelector` silently starved an entire DaemonSet

**Symptom:** after pinning the logging stack to a dedicated node with `nodeSelector.monitoring=true`, the log-shipping DaemonSet ended up with **one pod**, on that one labeled node — instead of one pod per node, which is the entire point of a DaemonSet.

**Root cause:** the chart applied its root-level `nodeSelector` to *every* component it manages, including the DaemonSet whose whole job is to run everywhere. The result: logs from every other node in the cluster silently stopped being collected — nothing errored, the DaemonSet just had far fewer replicas than it should have, and that's easy to not notice unless something is actively counting pods against node count.

**Fix required going past the Helm values entirely** — this operator version managed the DaemonSet's scheduling through its own custom resource, not the field the chart's values file suggested:
```bash
kubectl patch logging <name> -n <ns> --type='json' -p='[{"op":"remove","path":"/spec/fluentbit"}]'
# then clear nodeSelector on the FluentbitAgent CR the operator actually reads
```

**The lesson that generalizes beyond this specific chart:** whenever a `nodeSelector` or `affinity` rule is meant for *one* component of a multi-component chart, verify — by counting pods against node count, not by trusting the values file — that it didn't silently apply to a component that needs to run everywhere.
