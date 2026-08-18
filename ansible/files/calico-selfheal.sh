#!/usr/bin/env bash
# calico-selfheal.sh — detects and repairs the "Calico blocked by the rancher-webhook" deadlock automatically.
#
# THE DEADLOCK THIS FIXES (see docs/troubleshooting/observability-hub.md#bug-8 and ../TROUBLESHOOTING.md):
#   Boot → RKE2 re-runs helm-install-rke2-calico → recreates the Installation CR
#        → the calico-system namespace gets garbage-collected → tigera-operator asks to recreate it
#           → the rancher-webhook needs Rancher to authenticate the request, but cattle-cluster-agent
#             can't connect yet → returns Unauthorized → the request is DENIED
#              → Calico never installs → no calico-node to hold routes/NAT
#                 → the agent can never reach Rancher either ⟲ a fully self-locking loop
#   The deceptive symptom: the node is Ready, zero pods report errors, everything looks "green" — but
#   NO new pod can ever be scheduled. Existing pods keep running only because their veth/iptables
#   state is still held in the kernel.
#
# DESIGN PRINCIPLES:
#   1. Absolute silence when the cluster is healthy (exit 0, no log noise).
#   2. The repair action must MATCH the actual problem, and never escalate across categories:
#        - namespace missing / calico-node not Ready → the FULL repair path (touches the webhook)
#        - namespace+node healthy, only the token is stale → the TOKEN-ONLY path, which NEVER touches the webhook
#      (Version 1 escalated from a token problem straight to deleting the webhook — a real test run
#       proved that was wrong: deleting the webhook config did nothing for a stale token when the
#       namespace/node were already healthy.)
#   3. A proven, mandatory order: delete the webhook CONFIG → wait for Calico to come up →
#      ONLY THEN restart the webhook POD. Reversing this order deadlocks the cluster completely
#      (hit this exact failure during earlier debugging).
#   4. The cluster must never permanently lose the Rancher webhook: a backup is kept and re-applied
#      if Rancher doesn't restore it on its own.
#   5. The final proof is a REAL POD, never a bare `kubectl get pods` read.
#   6. Rate limit: too many repairs within an hour means something else is actually wrong — stop and alert a human.
#   7. Wait by POLLING the real condition, never by trusting `rollout status`'s own timeout.
#      (v1 used `rollout status --timeout=180s`, which timed out on this hub even while the rollout
#       was actually succeeding — misread as a failed repair.)

set -uo pipefail

KUBECTL="/var/lib/rancher/rke2/bin/kubectl"
export KUBECONFIG="/etc/rancher/rke2/rke2.yaml"
CNI_KUBECONFIG="/etc/cni/net.d/calico-kubeconfig"

TAG="calico-selfheal"
STATE_DIR="/var/lib/calico-selfheal"
REPAIR_LOG="${STATE_DIR}/repairs.log"      # 1 line per repair: epoch + type (used for rate limiting)
EVENT_LOG="${STATE_DIR}/selfheal.log"      # narrative log, PERSISTS across reboots
WEBHOOK_BACKUP="${STATE_DIR}/rancher-webhook-backup.yaml"

MAX_REPAIRS_PER_HOUR=3
WAIT_CALICO_SEC=240
WAIT_WEBHOOK_SEC=150
WAIT_POD_SEC=90
WAIT_TOKEN_SEC=300      # calico-node rollout + install-cni rewriting the token: takes ~230s on this hub
KTIMEOUT="--request-timeout=20s"

# Does the calico-node DaemonSet have every node's pod fully Ready?
# Compares desiredNumberScheduled vs numberReady rather than counting "≥1 pod Ready" —
# on a multi-node cluster (e.g. a 2-node test cluster), losing Calico on one node while the
# other still has it would let "≥1" PASS while half the cluster is actually broken. Same
# false-pass-check family documented elsewhere in this repo.
calico_ds_ok() {
    local out d r
    out=$(k -n calico-system get ds calico-node \
          -o jsonpath='{.status.desiredNumberScheduled}|{.status.numberReady}' 2>/dev/null) || return 1
    d=${out%%|*}; r=${out##*|}
    [ -n "$d" ] || return 1
    [ "$d" -ge 1 ] 2>/dev/null || return 1
    [ "${r:-0}" -eq "$d" ] 2>/dev/null
}

# Poll until the CNI token is valid, or time out. Returns 0 if valid.
wait_token() {
    local deadline=$(( $(date -u +%s) + $1 ))
    while [ "$(date -u +%s)" -lt "$deadline" ]; do
        if "$KUBECTL" --kubeconfig="$CNI_KUBECONFIG" $KTIMEOUT auth whoami >/dev/null 2>&1; then
            return 0
        fi
        sleep 10
    done
    return 1
}

# Writes to ALL 3 destinations:
#   - the systemd journal (view with: journalctl -t calico-selfheal)
#   - stdout (also captured into the unit's journal)
#   - the PERSISTENT file $EVENT_LOG — because this bug fires exactly at BOOT time, and some VMs'
#     journald is configured with Storage=volatile, which loses logs across a reboot — exactly the
#     evidence that matters most here.
log()  {
    logger -t "$TAG" -- "$*"
    echo "[$(date -u +%H:%M:%S)] $*"
    printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >> "$EVENT_LOG" 2>/dev/null || true
}
k()    { "$KUBECTL" $KTIMEOUT "$@"; }

mkdir -p "$STATE_DIR"; touch "$REPAIR_LOG" "$EVENT_LOG"

# ─── 0. If the apiserver isn't ready yet, exit silently (still booting / restarting) ───
if ! k get --raw='/readyz' >/dev/null 2>&1; then
    exit 0
fi

# ─── 1. Diagnose ─────────────────────────────────────────────────────────────
ns_ok=1; node_ok=1; token_ok=1

k get ns calico-system >/dev/null 2>&1 || ns_ok=0

if [ "$ns_ok" = 1 ]; then
    calico_ds_ok || node_ok=0
else
    node_ok=0
fi

if [ -r "$CNI_KUBECONFIG" ]; then
    "$KUBECTL" --kubeconfig="$CNI_KUBECONFIG" $KTIMEOUT auth whoami >/dev/null 2>&1 || token_ok=0
else
    token_ok=0
fi

# Cluster is healthy → stay silent. This is the path taken 99% of the time.
if [ "$ns_ok" = 1 ] && [ "$node_ok" = 1 ] && [ "$token_ok" = 1 ]; then
    exit 0
fi

log "PROBLEM DETECTED — calico_ns=$ns_ok calico_node_ready=$node_ok cni_token=$token_ok"

# ─── 2. Rate limit ────────────────────────────────────────────────────────────
now=$(date -u +%s)
recent=$(awk -v n="$now" '$1 > n-3600' "$REPAIR_LOG" 2>/dev/null | wc -l)
if [ "$recent" -ge "$MAX_REPAIRS_PER_HOUR" ]; then
    log "STOPPING: $recent repair(s) already run in the last hour (cap: $MAX_REPAIRS_PER_HOUR). Something else is wrong — needs a human. Not attempting another repair."
    exit 1
fi

# ─── 3. TOKEN REPAIR: Calico is otherwise fine, only the token is stale ───────────────────────────
#     This path NEVER touches the Rancher webhook. A healthy namespace and calico-node mean
#     the webhook has nothing to do with this problem — deleting the webhook config here
#     would be a pointless invasive action (this was v1's bug, caught during earlier testing).
if [ "$ns_ok" = 1 ] && [ "$node_ok" = 1 ] && [ "$token_ok" = 0 ]; then
    log "TOKEN REPAIR: Calico is healthy, only the CNI token is stale → rollout restart ds/calico-node"
    echo "$now token rollout-restart" >> "$REPAIR_LOG"
    k -n calico-system rollout restart ds/calico-node >/dev/null 2>&1

    if wait_token "$WAIT_TOKEN_SEC"; then
        log "✅ TOKEN REPAIR SUCCEEDED: the CNI token is valid again (the rollout restart was enough)"
        exit 0
    fi

    # Escalates WITHIN THE SAME PROBLEM CATEGORY: deletes the calico-node pod directly so its
    # install-cni initContainer runs from scratch. Still never touches the webhook.
    log "Rollout restart wasn't enough after ${WAIT_TOKEN_SEC}s → deleting the calico-node pod directly"
    k -n calico-system delete pod -l k8s-app=calico-node --wait=false >/dev/null 2>&1

    if wait_token 180; then
        log "✅ TOKEN REPAIR SUCCEEDED after deleting the calico-node pod"
        exit 0
    fi

    log "❌ TOKEN REPAIR FAILED — the CNI token is still invalid. NOT escalating to the webhook path (unrelated). Needs a human: journalctl -t $TAG"
    exit 1
fi

# ─── 4. FULL REPAIR: break the webhook ⟷ Calico deadlock ────────────────────────
#     Only reached when the namespace is missing OR calico-node isn't Ready — i.e. the
#     webhook genuinely is the bottleneck.
log "FULL REPAIR: starting to break the webhook ⟷ Calico deadlock"
echo "$now full ns=$ns_ok node=$node_ok token=$token_ok" >> "$REPAIR_LOG"

# 4a. Back up the webhook config, then delete it.
#     failurePolicy=Ignore is deliberately NOT used: the webhook is actively DENYING (it responds
#     normally) — failurePolicy only matters when the webhook itself errors or is unreachable.
if k get validatingwebhookconfiguration rancher.cattle.io >/dev/null 2>&1; then
    k get validatingwebhookconfiguration rancher.cattle.io -o yaml > "$WEBHOOK_BACKUP" 2>/dev/null \
        && log "Backed up the webhook config → $WEBHOOK_BACKUP"
    k delete validatingwebhookconfiguration rancher.cattle.io >/dev/null 2>&1 \
        && log "Deleted ValidatingWebhookConfiguration rancher.cattle.io (restored in step 4c)"
else
    log "The webhook config didn't exist to begin with — skipping the delete step"
fi

# 4b. Wait for tigera-operator to recreate the namespace + bring calico-node up.
#     calico-node/typha use hostNetwork → they don't need the CNI to start.
#     This is exactly the point where the loop gets broken.
log "Waiting for tigera-operator to rebuild calico-system (up to ${WAIT_CALICO_SEC}s)"
deadline=$(( $(date -u +%s) + WAIT_CALICO_SEC ))
calico_up=0
while [ "$(date -u +%s)" -lt "$deadline" ]; do
    if calico_ds_ok; then calico_up=1; break; fi
    sleep 10
done

if [ "$calico_up" = 1 ]; then
    log "Calico is up (calico-node fully Ready on every node)"
else
    log "WARNING: Calico still isn't up after ${WAIT_CALICO_SEC}s — continuing anyway to restore the webhook"
fi

# 4c. ONLY AFTER Calico is up does the webhook pod get restarted → it re-applies its own config.
#     This order is mandatory: deleting the webhook pod BEFORE the cluster can schedule a new one
#     loses the running instance entirely → a fully closed deadlock.
log "Restarting deploy/rancher-webhook so it re-applies its own webhook config"
k -n cattle-system rollout restart deploy/rancher-webhook >/dev/null 2>&1

deadline=$(( $(date -u +%s) + WAIT_WEBHOOK_SEC ))
webhook_back=0
while [ "$(date -u +%s)" -lt "$deadline" ]; do
    if k get validatingwebhookconfiguration rancher.cattle.io >/dev/null 2>&1; then
        webhook_back=1; break
    fi
    sleep 10
done

# 4d. Safety net: if Rancher doesn't restore it on its own, re-apply from the backup.
#     The cluster must never be left without admission validation permanently.
if [ "$webhook_back" = 1 ]; then
    log "The webhook config restored itself"
elif [ -s "$WEBHOOK_BACKUP" ]; then
    log "The webhook config did NOT restore itself → re-applying from the backup"
    k apply -f "$WEBHOOK_BACKUP" >/dev/null 2>&1 \
        && log "Re-applied the webhook config from the backup" \
        || log "ERROR: re-applying the webhook config from the backup FAILED — needs manual attention"
else
    log "ERROR: the webhook config never came back and no backup exists — the cluster is missing Rancher's admission validation"
fi

# 4e. Clean up any crashing cattle-cluster-agent pod (it was crashing because pod networking was broken earlier).
agent_bad=$(k -n cattle-system get pods -l app=cattle-cluster-agent --no-headers 2>/dev/null \
            | awk '{split($2,a,"/"); if (a[2] != "" && a[1] != a[2]) print $1}')
if [ -n "$agent_bad" ]; then
    log "Deleting the broken cattle-cluster-agent pod so it gets recreated with working CNI"
    for p in $agent_bad; do k -n cattle-system delete pod "$p" --wait=false >/dev/null 2>&1; done
fi

# ─── 5. Verify with a REAL POD — the only trustworthy evidence ───────────────────
pod="selfheal-probe-$$-$(date -u +%s)"
log "Verifying with a real pod: $pod"
k run "$pod" --image=busybox --restart=Never --command -- sh -c 'exit 0' >/dev/null 2>&1

deadline=$(( $(date -u +%s) + WAIT_POD_SEC ))
pod_ok=0
while [ "$(date -u +%s)" -lt "$deadline" ]; do
    st=$(k get pod "$pod" --no-headers 2>/dev/null | awk '{print $3}')
    case "$st" in
        Succeeded|Completed) pod_ok=1; break ;;
        Error|CrashLoopBackOff) break ;;
    esac
    sleep 5
done
k delete pod "$pod" --wait=false >/dev/null 2>&1

if [ "$pod_ok" = 1 ]; then
    log "✅ SELF-HEAL SUCCEEDED — the cluster can schedule new pods again"
    exit 0
fi

log "❌ SELF-HEAL FAILED — the cluster still can't schedule new pods. Needs a human: journalctl -t $TAG"
exit 1
