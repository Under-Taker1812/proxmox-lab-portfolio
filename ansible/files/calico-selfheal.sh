#!/usr/bin/env bash
# calico-selfheal.sh — tự phát hiện + tự gỡ deadlock "Calico bị rancher-webhook chặn"
#
# BỆNH NÓ CHỮA (xem rke2-calico-netfilter-bugs.md Bug #5):
#   Boot → RKE2 chạy lại helm-install-rke2-calico → tạo lại Installation CR
#        → namespace calico-system bị GC → tigera-operator xin tạo lại
#           → rancher-webhook cần Rancher để xác thực, nhưng cattle-cluster-agent
#             chưa kết nối được → trả Unauthorized → TỪ CHỐI
#              → Calico không cài → không có calico-node giữ route/NAT
#                 → agent vĩnh viễn không tới được Rancher ⟲ vòng tự khoá
#   Triệu chứng lừa người: node Ready, 0 pod lỗi, mọi thứ "xanh" — nhưng
#   KHÔNG tạo được pod mới nào. Pod cũ sống nhờ veth/iptables còn trong kernel.
#
# NGUYÊN TẮC THIẾT KẾ:
#   1. Im lặng tuyệt đối khi cụm lành (exit 0, không log rác).
#   2. Hành động TƯƠNG XỨNG với bệnh, và KHÔNG leo thang chéo:
#        - ns mất / calico-node không Ready  → đường SỬA ĐẦY ĐỦ (đụng webhook)
#        - ns+node khoẻ, chỉ token hỏng      → đường SỬA TOKEN, TUYỆT ĐỐI không đụng webhook
#      (Bản v1 leo thang từ token sang xoá webhook — test 14/08 07:12 chứng minh là sai:
#       xoá webhook config không giúp gì cho token khi ns/node đều khoẻ.)
#   3. Đúng THỨ TỰ đã chứng minh: xoá webhook CONFIG → chờ Calico lên →
#      MỚI restart webhook POD. Đảo thứ tự là chết cứng (đã mắc 07/08).
#   4. Không bao giờ để cụm mất webhook Rancher vĩnh viễn: có backup, tự apply lại
#      nếu Rancher không tự phục hồi.
#   5. Bằng chứng cuối cùng là POD THẬT, không tin `kubectl get pods` suông.
#   6. Rate limit: hỏng quá nhiều lần/giờ nghĩa là nguyên nhân khác → dừng, hú người.
#   7. Chờ bằng cách POLL điều kiện thật, không tin timeout của `rollout status`.
#      (v1 dùng `rollout status --timeout=180s` → timeout trên hub này → tưởng
#       sửa nhẹ thất bại trong khi nó đang thành công.)

set -uo pipefail

KUBECTL="/var/lib/rancher/rke2/bin/kubectl"
export KUBECONFIG="/etc/rancher/rke2/rke2.yaml"
CNI_KUBECONFIG="/etc/cni/net.d/calico-kubeconfig"

TAG="calico-selfheal"
STATE_DIR="/var/lib/calico-selfheal"
REPAIR_LOG="${STATE_DIR}/repairs.log"      # 1 dòng/lần sửa: epoch + loại (cho rate limit)
EVENT_LOG="${STATE_DIR}/selfheal.log"      # log tường thuật, BỀN qua reboot
WEBHOOK_BACKUP="${STATE_DIR}/rancher-webhook-backup.yaml"

MAX_REPAIRS_PER_HOUR=3
WAIT_CALICO_SEC=240
WAIT_WEBHOOK_SEC=150
WAIT_POD_SEC=90
WAIT_TOKEN_SEC=300      # calico-node roll xong + install-cni ghi lai token: do that ~230s tren hub nay
KTIMEOUT="--request-timeout=20s"

# DaemonSet calico-node đủ pod Ready trên MỌI node chưa?
# Dùng desiredNumberScheduled vs numberReady chứ KHÔNG đếm "≥1 pod Ready" —
# trên cụm nhiều node (vd k8s-demo 2 node), 1 node mất Calico mà node kia còn
# thì "≥1" vẫn PASS trong khi cụm đã hỏng một nửa. Cùng họ lỗi "check giả pass".
calico_ds_ok() {
    local out d r
    out=$(k -n calico-system get ds calico-node \
          -o jsonpath='{.status.desiredNumberScheduled}|{.status.numberReady}' 2>/dev/null) || return 1
    d=${out%%|*}; r=${out##*|}
    [ -n "$d" ] || return 1
    [ "$d" -ge 1 ] 2>/dev/null || return 1
    [ "${r:-0}" -eq "$d" ] 2>/dev/null
}

# Poll cho tới khi token CNI hợp lệ, hoặc hết hạn. Trả 0 nếu hợp lệ.
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

# Ghi ra CẢ 3 chỗ:
#   - journal systemd (xem bằng: journalctl -t calico-selfheal)
#   - stdout (đi vào journal của unit)
#   - file BỀN $EVENT_LOG — vì bug này nổ đúng lúc BOOT, mà journald trên một số VM
#     để Storage=volatile → log biến mất sau reboot, tức mất đúng bằng chứng cần nhất.
log()  {
    logger -t "$TAG" -- "$*"
    echo "[$(date -u +%H:%M:%S)] $*"
    printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >> "$EVENT_LOG" 2>/dev/null || true
}
k()    { "$KUBECTL" $KTIMEOUT "$@"; }

mkdir -p "$STATE_DIR"; touch "$REPAIR_LOG" "$EVENT_LOG"

# ─── 0. Nếu apiserver chưa sẵn sàng thì thoát im lặng (đang boot / đang restart) ───
if ! k get --raw='/readyz' >/dev/null 2>&1; then
    exit 0
fi

# ─── 1. Chẩn đoán ─────────────────────────────────────────────────────────────
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

# Cụm lành → im lặng. Đây là đường đi 99% số lần chạy.
if [ "$ns_ok" = 1 ] && [ "$node_ok" = 1 ] && [ "$token_ok" = 1 ]; then
    exit 0
fi

log "PHÁT HIỆN SỰ CỐ — calico_ns=$ns_ok calico_node_ready=$node_ok cni_token=$token_ok"

# ─── 2. Rate limit ────────────────────────────────────────────────────────────
now=$(date -u +%s)
recent=$(awk -v n="$now" '$1 > n-3600' "$REPAIR_LOG" 2>/dev/null | wc -l)
if [ "$recent" -ge "$MAX_REPAIRS_PER_HOUR" ]; then
    log "DỪNG: đã sửa $recent lần trong 1 giờ qua (trần $MAX_REPAIRS_PER_HOUR). Nguyên nhân khác — cần người xem. KHÔNG tự sửa nữa."
    exit 1
fi

# ─── 3. SỬA TOKEN: Calico còn sống, chỉ token hỏng ───────────────────────────
#     Đường này TUYỆT ĐỐI không đụng webhook Rancher. Namespace và calico-node đều
#     khoẻ nghĩa là webhook không liên quan gì tới bệnh này — xoá webhook config ở
#     đây là hành động xâm lấn vô ích (bug của bản v1, test 14/08 phơi ra).
if [ "$ns_ok" = 1 ] && [ "$node_ok" = 1 ] && [ "$token_ok" = 0 ]; then
    log "SỬA TOKEN: Calico khoẻ, chỉ token CNI hỏng → rollout restart ds/calico-node"
    echo "$now token rollout-restart" >> "$REPAIR_LOG"
    k -n calico-system rollout restart ds/calico-node >/dev/null 2>&1

    if wait_token "$WAIT_TOKEN_SEC"; then
        log "✅ SỬA TOKEN THÀNH CÔNG: token CNI hợp lệ lại (rollout restart là đủ)"
        exit 0
    fi

    # Leo thang TRONG CÙNG NHÓM BỆNH: xoá thẳng pod calico-node để initContainer
    # install-cni chạy lại từ đầu. Vẫn không đụng gì tới webhook.
    log "Rollout restart chưa đủ sau ${WAIT_TOKEN_SEC}s → xoá thẳng pod calico-node"
    k -n calico-system delete pod -l k8s-app=calico-node --wait=false >/dev/null 2>&1

    if wait_token 180; then
        log "✅ SỬA TOKEN THÀNH CÔNG sau khi xoá pod calico-node"
        exit 0
    fi

    log "❌ SỬA TOKEN THẤT BẠI — token CNI vẫn không hợp lệ. KHÔNG tự leo thang sang webhook (không liên quan). Cần người xem: journalctl -t $TAG"
    exit 1
fi

# ─── 4. SỬA ĐẦY ĐỦ: gỡ vòng tự khoá webhook ⟷ Calico ────────────────────────
#     Chỉ tới đây khi ns mất HOẶC calico-node không Ready — tức đúng bệnh mà
#     webhook đang là nút thắt.
log "SỬA ĐẦY ĐỦ: bắt đầu gỡ deadlock webhook ⟷ Calico"
echo "$now full ns=$ns_ok node=$node_ok token=$token_ok" >> "$REPAIR_LOG"

# 4a. Backup webhook config rồi xoá.
#     KHÔNG dùng failurePolicy=Ignore: webhook đang DENY chủ động (trả lời hẳn hoi),
#     failurePolicy chỉ có tác dụng khi webhook lỗi/không reachable.
if k get validatingwebhookconfiguration rancher.cattle.io >/dev/null 2>&1; then
    k get validatingwebhookconfiguration rancher.cattle.io -o yaml > "$WEBHOOK_BACKUP" 2>/dev/null \
        && log "Đã backup webhook config → $WEBHOOK_BACKUP"
    k delete validatingwebhookconfiguration rancher.cattle.io >/dev/null 2>&1 \
        && log "Đã xoá ValidatingWebhookConfiguration rancher.cattle.io (sẽ phục hồi ở bước 4c)"
else
    log "Webhook config vốn đã không tồn tại — bỏ qua bước xoá"
fi

# 4b. Chờ tigera-operator tạo ns + calico-node lên.
#     calico-node/typha dùng hostNetwork → KHÔNG cần CNI để khởi động.
#     Đây chính là chỗ phá được vòng lặp.
log "Chờ tigera-operator dựng lại calico-system (tối đa ${WAIT_CALICO_SEC}s)"
deadline=$(( $(date -u +%s) + WAIT_CALICO_SEC ))
calico_up=0
while [ "$(date -u +%s)" -lt "$deadline" ]; do
    if calico_ds_ok; then calico_up=1; break; fi
    sleep 10
done

if [ "$calico_up" = 1 ]; then
    log "Calico đã lên (calico-node Ready đủ trên mọi node)"
else
    log "CẢNH BÁO: Calico chưa lên sau ${WAIT_CALICO_SEC}s — vẫn tiếp tục để phục hồi webhook"
fi

# 4c. CHỈ SAU KHI Calico lên mới restart webhook pod → nó tự apply lại config.
#     Thứ tự này là bắt buộc: 07/08 đã xoá pod webhook TRƯỚC khi cụm tạo được pod mới
#     → mất luôn bản đang chạy → deadlock khép kín hoàn toàn.
log "Restart deploy/rancher-webhook để nó tự apply lại webhook config"
k -n cattle-system rollout restart deploy/rancher-webhook >/dev/null 2>&1

deadline=$(( $(date -u +%s) + WAIT_WEBHOOK_SEC ))
webhook_back=0
while [ "$(date -u +%s)" -lt "$deadline" ]; do
    if k get validatingwebhookconfiguration rancher.cattle.io >/dev/null 2>&1; then
        webhook_back=1; break
    fi
    sleep 10
done

# 4d. Lưới an toàn: Rancher không tự phục hồi thì apply lại từ backup.
#     Không được để cụm mất admission validation vĩnh viễn.
if [ "$webhook_back" = 1 ]; then
    log "Webhook config đã tự phục hồi"
elif [ -s "$WEBHOOK_BACKUP" ]; then
    log "Webhook config KHÔNG tự phục hồi → apply lại từ backup"
    k apply -f "$WEBHOOK_BACKUP" >/dev/null 2>&1 \
        && log "Đã apply lại webhook config từ backup" \
        || log "LỖI: apply lại webhook config từ backup THẤT BẠI — cần người xử lý"
else
    log "LỖI: webhook config chưa phục hồi và không có backup — cụm đang thiếu admission validation của Rancher"
fi

# 4e. Dọn pod cattle-cluster-agent đang crash (nó crash vì mạng pod hỏng lúc trước).
agent_bad=$(k -n cattle-system get pods -l app=cattle-cluster-agent --no-headers 2>/dev/null \
            | awk '{split($2,a,"/"); if (a[2] != "" && a[1] != a[2]) print $1}')
if [ -n "$agent_bad" ]; then
    log "Xoá pod cattle-cluster-agent đang lỗi để tạo lại với CNI đã lành"
    for p in $agent_bad; do k -n cattle-system delete pod "$p" --wait=false >/dev/null 2>&1; done
fi

# ─── 5. Verify bằng POD THẬT — bằng chứng duy nhất đáng tin ───────────────────
pod="selfheal-probe-$$-$(date -u +%s)"
log "Verify bằng pod thật: $pod"
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
    log "✅ TỰ LÀNH THÀNH CÔNG — cụm tạo được pod mới trở lại"
    exit 0
fi

log "❌ TỰ LÀNH THẤT BẠI — cụm vẫn không tạo được pod mới. Cần người xem: journalctl -t $TAG"
exit 1
