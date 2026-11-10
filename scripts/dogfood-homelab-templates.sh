#!/usr/bin/env bash
# QEMU check of the homelab Ignition templates from a release set, used as
# published: a diskless control plane booted with homelab-control-plane.bu
# (the Butane source, which Ignition reads as is) and a diskless node booted
# with homelab-node.ign (the compiled config) plus the join passphrase the
# control plane generated and shows, passed as the bluefin-cluster.passphrase
# credential. Nothing else is configured: each node pulls its kubeadm and
# homelab sysexts from the boot server through bluefin-sysext-fetch.service,
# the control plane runs kubeadm init and applies the default homelab
# component set, and the node discovers it over mDNS and joins.
#
# Passes when both nodes are Ready, the control plane's applier finished
# (every default component rolled out; monitoring is off, and MetalLB has no
# address pool because the template leaves HOMELAB_METALLB_ADDRESSES
# commented) and a local-path PVC binds; and the add-ons the control-plane
# template enables work over HTTPS through the homelab Gateway (its
# Service's cluster address, by host name, the certificate verified against
# the homelab CA; port 80 redirects before the login): Argo Workflows rejects a request without a token
# and accepts a `kubectl create token` one, the MCP server rejects one
# without a token, answers a read tool with the generated mcp-client token
# and refuses a write tool; the KubeStellar Console is deployed without
# OAuth: /auth/github through the Gateway answers 401 without the generated
# login (also in another spelling) and, with it, redirects and sets a
# kc_auth session cookie that /api/me accepts as the admin; a pod in another
# namespace cannot reach the Console's Service but can through the Gateway;
# the login is on the console (0600 issue file), never in the journal; then
# (dummy) OAuth app files switch it to GitHub sign-in, still behind the login.
# A diskless node keeps /var, and so every container image, in RAM; at the
# guest sizes here kubelet would report DiskPressure and evict pods. Each
# guest therefore gets a blank XFS disk for /var (a var.mount and its
# local-fs.target want passed as credentials, not through the template):
# what a real diskless homelab node needs too.
# Needs guest internet (registry.k8s.io, quay.io, ghcr.io, docker.io);
# DOGFOOD_DNS=<ip> as in dogfood-homelab-cluster.sh.
# Usage: dogfood-homelab-templates.sh <dir with the release set>
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
dir="$(realpath "${1:?usage: $0 <dir>}")"
state="$(realpath -m "${DOGFOOD_STATE:-dist/dogfood-homelab-templates}")"
base_port="${DOGFOOD_PORT:-8781}"
link_port="${DOGFOOD_LINK_PORT:-40180}"
for f in homelab-control-plane.bu homelab-node.ign; do
    [ -f "${dir}/${f}" ] || { echo "ERROR: no ${f} in ${dir}" >&2; exit 1; }
done

rm -rf "${state}"
mkdir -p "${state}"

cat > "${state}/cp.probe" <<'EOF'
journalctl -f -n all -o cat -u bluefin-sysext-fetch.service -u kubeadm-init.service -u bluefin-homelab-apply.service -u 'bluefin-cluster-*' | sed -u 's/^/PROBE-LOG live: /' &
export KUBECONFIG=/etc/kubernetes/admin.conf
for _ in $(seq 360); do pass="$(bluefin-cluster passphrase 2>/dev/null)" && [ -n "${pass}" ] && break; sleep 5; done
# Test only: the host hands it to the node, as a person would.
echo "PROBE cp-passphrase=${pass}"
echo "PROBE cp-fetch=$(systemctl show -P Result bluefin-sysext-fetch.service) $(journalctl -b -o cat -u bluefin-sysext-fetch.service | sed -n 's/.*: merged the \(.*\) sysext(s) for .* (\(.*\))$/\1 via \2/p' | tr ' ' '-')"
echo "PROBE cp-merged=$(ls /usr/lib/extension-release.d | sed 's/^extension-release\.//' | tr '\n' ' ')"
echo "PROBE cp-features=$(cd /etc/sysupdate.d && ls -d *.feature.d | tr '\n' ' ')"
echo "PROBE cp-var=$(findmnt -no SOURCE,FSTYPE /var)"
echo "PROBE cp-conf role=$(sed -n 's/^HOMELAB_ROLE=//p' /etc/bluefin/homelab.conf) mode=$(stat -c %a /etc/bluefin/homelab.conf) set=$(grep -c '^HOMELAB_' /etc/bluefin/homelab.conf)"
ready() { kubectl get nodes -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' 2>/dev/null | grep -c True; }
for i in $(seq 540); do
    [ "$(ready)" -ge 2 ] && break
    [ $((i % 30)) = 0 ] && kubectl get nodes --no-headers 2>&1 | sed 's/^/PROBE-LOG nodes: /'
    sleep 5
done
echo "PROBE cp-nodes-ready=$(ready) nodes=$(kubectl get nodes --no-headers | wc -l)"
# Pods that are not (yet) all ready, with their last log lines and events.
unready() {
    kubectl get pods -A -o wide --no-headers 2>&1 | grep -vE ' ([0-9]+)/\1 +(Running|Completed) ' | sed 's/^/PROBE-LOG unready: /'
    kubectl get pods -A --no-headers 2>/dev/null | grep -vE ' ([0-9]+)/\1 +(Running|Completed) ' | while read -r ns name _; do
        kubectl -n "${ns}" logs "${name}" --all-containers --tail=4 2>&1 | cut -c1-300 | sed "s|^|PROBE-LOG ${name}: |"
        kubectl -n "${ns}" get events --field-selector "involvedObject.name=${name}" --no-headers 2>&1 | tail -n 3 | cut -c1-300 | sed "s|^|PROBE-LOG ${name} event: |"
    done
}
for i in $(seq 720); do
    case "$(systemctl show -P ActiveState bluefin-homelab-apply.service)" in active) break ;; esac
    [ $((i % 24)) = 0 ] && unready
    sleep 5
done
journalctl -b -o cat --no-pager -u bluefin-homelab-apply.service | tail -n 25 | sed 's/^/PROBE-LOG apply: /'
echo "PROBE cp-init=$(systemctl show -P ActiveState kubeadm-init.service) apply=$(systemctl show -P ActiveState bluefin-homelab-apply.service)/$(systemctl show -P Result bluefin-homelab-apply.service)"
echo "PROBE cp-namespaces=$(for ns in argocd cert-manager envoy-gateway-system local-path-storage metallb-system reloader monitoring; do kubectl get ns "${ns}" >/dev/null 2>&1 && printf '%s,' "${ns}"; done)"
echo "PROBE cp-metallb-pools=$(kubectl get ipaddresspools.metallb.io -A --no-headers 2>/dev/null | wc -l)"
cat <<'PVC' | kubectl apply -f - >/dev/null
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: dogfood, namespace: default}
spec: {accessModes: [ReadWriteOnce], resources: {requests: {storage: 16Mi}}}
---
apiVersion: v1
kind: Pod
metadata: {name: dogfood, namespace: default}
spec:
  containers:
  - {name: c, image: registry.k8s.io/pause:3.10.1, volumeMounts: [{name: v, mountPath: /v}]}
  volumes: [{name: v, persistentVolumeClaim: {claimName: dogfood}}]
PVC
for _ in $(seq 60); do [ "$(kubectl get pvc dogfood -o jsonpath='{.status.phase}')" = Bound ] && break; sleep 5; done
echo "PROBE cp-pvc=$(kubectl get pvc dogfood -o jsonpath='{.status.phase}') class=$(kubectl get pvc dogfood -o jsonpath='{.spec.storageClassName}')"
kubectl get nodes -o wide --no-headers | sed 's/^/PROBE-LOG node: /'
kubectl get pods -A --no-headers | sed 's/^/PROBE-LOG pod: /'
kubectl -n envoy-gateway-system get svc --no-headers 2>&1 | sed 's/^/PROBE-LOG svc: /'
# Add-ons, through the Gateway's Service (no MetalLB pool: no external address).
gw="$(kubectl -n envoy-gateway-system get svc -l gateway.envoyproxy.io/owning-gateway-name=homelab -o jsonpath='{.items[0].spec.clusterIP}')"
# The add-on names resolve to the Gateway's Service, and https verifies
# against the homelab CA, fetched as homelab-profile.md tells you to.
ca="${TMPDIR:-/tmp}/homelab-ca.crt"
for _ in $(seq 60); do kubectl -n cert-manager get secret homelab-ca -o jsonpath='{.data.ca\.crt}' 2>/dev/null | base64 -d >"${ca}" 2>/dev/null && [ -s "${ca}" ] && break; sleep 5; done
gwcurl() {
    local host resolve=()
    for host in argo mcp kubestellar; do resolve+=(--resolve "${host}.home.arpa:443:${gw}" --resolve "${host}.home.arpa:80:${gw}"); done
    curl -s --max-time 20 --cacert "${ca}" "${resolve[@]}" "$@"
}
code() { gwcurl -o /dev/null -w '%{http_code}' "$@"; }
for _ in $(seq 60); do [ "$(code https://argo.home.arpa/api/v1/workflows/argo)" != 000 ] && break; sleep 5; done
argo_token="$(kubectl -n argo create token argo-server)"
echo "PROBE cp-argo ready=$(kubectl -n argo get deploy argo-server workflow-controller -o jsonpath='{.items[*].status.readyReplicas}') auth=$(kubectl -n argo get deploy argo-server -o jsonpath='{.spec.template.spec.containers[0].args}' | grep -o 'auth-mode=[a-z]*') notoken=$(code https://argo.home.arpa/api/v1/workflows/argo) token=$(code -H "Authorization: Bearer ${argo_token}" https://argo.home.arpa/api/v1/workflows/argo)"
mcp_token="$(kubectl -n mcp get secret mcp-client-token -o jsonpath='{.data.token}' | base64 -d)"
mcp() {
    gwcurl --max-time 30 -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' "$@" https://mcp.home.arpa/mcp
}
init='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"dogfood","version":"1"}}}'
read_call='{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"namespaces_list","arguments":{}}}'
write_call='{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"resources_create_or_update","arguments":{"resource":"{\"apiVersion\":\"v1\",\"kind\":\"ConfigMap\",\"metadata\":{\"name\":\"dogfood-mcp\",\"namespace\":\"default\"}}"}}}'
mcp -H "Authorization: Bearer ${mcp_token}" -d "${init}" -o /dev/null
read_out="$(mcp -H "Authorization: Bearer ${mcp_token}" -d "${read_call}")"
write_out="$(mcp -H "Authorization: Bearer ${mcp_token}" -d "${write_call}")"
printf '%s\n' "${read_out}" | cut -c1-300 | sed 's/^/PROBE-LOG mcp read: /'
printf '%s\n' "${write_out}" | cut -c1-300 | sed 's/^/PROBE-LOG mcp write: /'
echo "PROBE cp-mcp ready=$(kubectl -n mcp get deploy mcp-kubernetes-mcp-server -o jsonpath='{.status.readyReplicas}') notoken=$(code -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' -d "${init}" https://mcp.home.arpa/mcp) read=$(grep -q 'kube-system' <<<"${read_out}" && echo ok || echo fail) write=$(grep -qE '"isError":true|"error":' <<<"${write_out}" && ! kubectl -n default get configmap dogfood-mcp >/dev/null 2>&1 && echo refused || echo allowed)"
# KubeStellar Console: deployed by default, no OAuth app.
ks_get() { kubectl -n kubestellar-console get "$@"; }
echo "PROBE cp-console ready=$(ks_get deploy kubestellar-console -o jsonpath='{.status.readyReplicas}') sign-in=$(ks_get deploy kubestellar-console -o jsonpath='{.spec.template.metadata.annotations.homelab\.bluefin\.dev/console-sign-in}') oauth-secret=$(ks_get secret kubestellar-console-github-oauth >/dev/null 2>&1 && echo yes || echo no) dev-mode=$(ks_get deploy kubestellar-console -o yaml | grep -c DEV_MODE)"
login="$(ks_get secret kubestellar-console-login -o jsonpath='{.data.password}' | base64 -d)"
ks() { gwcurl "$@"; }
for _ in $(seq 60); do [ "$(ks -o /dev/null -w '%{http_code}' "https://kubestellar.home.arpa/auth/github")" = 401 ] && break; sleep 5; done
ks -D "${TMPDIR:-/tmp}/ks-noauth" -o /dev/null "https://kubestellar.home.arpa/auth/github"
ks -D "${TMPDIR:-/tmp}/ks-login" -o /dev/null -u "admin:${login}" "https://kubestellar.home.arpa/auth/github"
status() { sed -n '1s/^HTTP[^ ]* \([0-9]*\).*/\1/p' "$1"; }
session="$(sed -n 's/^[Ss]et-[Cc]ookie: kc_auth=\([^;]*\);.*/\1/p' "${TMPDIR:-/tmp}/ks-login")"
me="$(ks -b "kc_auth=${session}" "https://kubestellar.home.arpa/api/me")"
printf '%s\n' "${me}" | cut -c1-200 | sed 's/^/PROBE-LOG console me: /'
echo "PROBE cp-console-gate noauth=$(status "${TMPDIR:-/tmp}/ks-noauth") challenge=$(grep -ci '^www-authenticate: basic' "${TMPDIR:-/tmp}/ks-noauth") variant=$(ks -o /dev/null -w '%{http_code}' "https://kubestellar.home.arpa/AUTH/GitHub/") wrong=$(ks -o /dev/null -w '%{http_code}' -u admin:wrong "https://kubestellar.home.arpa/auth/github") manifest=$(ks -o /dev/null -w '%{http_code}' "https://kubestellar.home.arpa/auth/manifest/setup") login=$(status "${TMPDIR:-/tmp}/ks-login") location=$(sed -n 's/^[Ll]ocation: //p' "${TMPDIR:-/tmp}/ks-login" | tr -d '\r') cookie=$([ -n "${session}" ] && echo kc_auth || echo none) me=$(ks -o /dev/null -w '%{http_code}' -b "kc_auth=${session}" "https://kubestellar.home.arpa/api/me") me-nocookie=$(ks -o /dev/null -w '%{http_code}' "https://kubestellar.home.arpa/api/me") role=$(grep -o '"role":"[a-z]*"' <<<"${me}" | cut -d'"' -f4) user=$(grep -o '"github_login":"[a-z-]*"' <<<"${me}" | cut -d'"' -f4)"
# NetworkPolicy: a pod in another namespace reaches the Console only through the Gateway.
np() { kubectl -n default run "np-$1" --image=docker.io/library/busybox:1.37.0 --restart=Never --rm -i --quiet --pod-running-timeout=5m --command -- sh -c "$2" >/dev/null 2>&1 && echo ok || echo blocked; }
echo "PROBE cp-console-netpol direct=$(np direct 'wget -T 10 -q -O /dev/null http://kubestellar-console.kubestellar-console.svc:8080/watchdog/health') gateway=$(np gateway "wget -T 10 -q -O /dev/null --header 'Host: kubestellar.home.arpa' https://${gw}/watchdog/health")"
issue=/run/issue.d/51-kubestellar-console.issue
echo "PROBE cp-console-issue mode=$(stat -c %a "${issue}") url=$(grep -c '^KubeStellar Console: https://kubestellar.home.arpa (user admin, password ' "${issue}") login=$(grep -cF "password ${login})" "${issue}") journal=$(journalctl -b -o cat | grep -cF "${login}")"
# TLS: the certificate verifies against the homelab CA; port 80 redirects
# before the login gate, so no password or cookie is taken over plain HTTP,
# and the kc_auth session cookie is Secure (never sent back over HTTP).
sed -n 's/^[Ss]et-[Cc]ookie: kc_auth=[^;]*/kc_auth=<value>/p' "${TMPDIR:-/tmp}/ks-login" | tr -d '\r' | sed 's/^/PROBE-LOG console cookie: /'
echo "PROBE cp-gateway-tls ready=$(kubectl -n envoy-gateway-system get certificate homelab-tls -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}') verify=$(gwcurl -o /dev/null -w '%{ssl_verify_result}' https://kubestellar.home.arpa/watchdog/health) issuer=$(kubectl -n envoy-gateway-system get certificate homelab-tls -o jsonpath='{.spec.issuerRef.name}') http=$(code -u "admin:${login}" http://kubestellar.home.arpa/auth/github) location=$(gwcurl -o /dev/null -w '%{redirect_url}' http://kubestellar.home.arpa/auth/github) http-argo=$(code http://argo.home.arpa/api/v1/workflows/argo) secure=$(grep -i '^set-cookie: kc_auth=' "${TMPDIR:-/tmp}/ks-login" | grep -ci '; *secure')"
# GitHub sign-in instead: dummy OAuth app files roll the Console over.
install -d -m 0700 /etc/bluefin/homelab.d/kubestellar-console
printf %s dummy-client-id > /etc/bluefin/homelab.d/kubestellar-console/github-client-id
printf %s dummy-client-secret > /etc/bluefin/homelab.d/kubestellar-console/github-client-secret
chmod 0600 /etc/bluefin/homelab.d/kubestellar-console/*
systemctl restart bluefin-homelab-apply.service
journalctl -b -o cat --no-pager -u bluefin-homelab-apply.service | grep -E 'kubestellar|failed' | tail -n 8 | sed 's/^/PROBE-LOG apply2: /'
kubectl -n kubestellar-console rollout status deploy/kubestellar-console --timeout=300s >/dev/null 2>&1
ks -D "${TMPDIR:-/tmp}/ks-oauth" -o /dev/null -u "admin:${login}" "https://kubestellar.home.arpa/auth/github"
echo "PROBE cp-console-oauth apply=$(systemctl show -P Result bluefin-homelab-apply.service) sign-in=$(ks_get deploy kubestellar-console -o jsonpath='{.spec.template.metadata.annotations.homelab\.bluefin\.dev/console-sign-in}') ready=$(ks_get deploy kubestellar-console -o jsonpath='{.status.readyReplicas}') noauth=$(ks -o /dev/null -w '%{http_code}' "https://kubestellar.home.arpa/auth/github") login=$(status "${TMPDIR:-/tmp}/ks-oauth") github=$(grep -ci '^location: https://github.com/login/oauth/authorize?.*client_id=dummy-client-id' "${TMPDIR:-/tmp}/ks-oauth") warned=$(journalctl -b -o cat -u bluefin-homelab-apply.service | grep -c 'GitHub sign-in without HOMELAB_KUBESTELLAR_CONSOLE_ALLOWED_LOGINS') secret-logged=$(journalctl -b -o cat | grep -c dummy-client-secret)"
echo "PROBE cp-unhealthy-pods=$(kubectl get pods -A --no-headers | grep -cvE ' (Running|Completed) ')"
# Release the node (until now pods may run on it), and give it time to see it.
kubectl label nodes --all --overwrite dogfood-done=true >/dev/null
sleep 60
EOF

cat > "${state}/node.probe" <<'EOF'
journalctl -f -n all -o cat -u bluefin-sysext-fetch.service -u 'bluefin-cluster-*' | sed -u 's/^/PROBE-LOG live: /' &
for _ in $(seq 600); do [ -e /var/lib/bluefin-cluster/joined ] && break; sleep 5; done
echo "PROBE node-fetch=$(systemctl show -P Result bluefin-sysext-fetch.service) merged=$(ls /usr/lib/extension-release.d | sed 's/^extension-release\.//' | tr '\n' ' ')"
echo "PROBE node-joined=$([ -e /var/lib/bluefin-cluster/joined ] && echo yes || echo no) kubelet=$(systemctl is-active kubelet.service) role=$(sed -n 's/^HOMELAB_ROLE=//p' /etc/bluefin/homelab.conf)"
k() { kubectl --kubeconfig /etc/kubernetes/kubelet.conf "$@"; }
for _ in $(seq 180); do
    [ "$(k get node "$(hostname)" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" = True ] && break
    sleep 5
done
echo "PROBE node-ready=$(k get node "$(hostname)" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')"
# Stay up, running its share of the pods, until the control plane is done.
for _ in $(seq 720); do
    [ "$(k get node "$(hostname)" -o jsonpath='{.metadata.labels.dogfood-done}' 2>/dev/null)" = true ] && break
    sleep 5
done
EOF

# One L2 segment for both guests (scripts/dogfood-lan.sh).
# shellcheck source=scripts/dogfood-lan.sh
. "${here}/dogfood-lan.sh"
lan_start "${state}" "${link_port}"
pids=()
trap 'kill "${pids[@]}" 2>/dev/null || true; lan_stop' EXIT

# boot <role> <port> <mem> <timeout> <mac suffix> <ignition>
boot() {
    local role=$1 creds="${state}/$1-creds"
    mkdir -p "${state}/${role}-set" "${creds}"
    for f in "${dir}"/*; do ln -sf "${f}" "${state}/${role}-set/"; done
    if [ -n "${DOGFOOD_DNS:-}" ]; then printf '%s\n' "${DOGFOOD_DNS}" > "${creds}/network.dns"; fi
    truncate -s 40G "${state}/${role}-var.raw"
    mkfs.xfs -q -L bluefin-var "${state}/${role}-var.raw"
    printf '[Mount]\nWhat=/dev/disk/by-label/bluefin-var\nWhere=/var\nType=xfs\n' > "${creds}/systemd.extra-unit.var.mount"
    printf '[Unit]\nWants=var.mount\n' > "${creds}/systemd.unit-dropin.local-fs.target~var"
    DOGFOOD_PORT="$2" DOGFOOD_MEM="$3" DOGFOOD_TIMEOUT="$4" DOGFOOD_NET="$(nic "$5")" \
    DOGFOOD_IGNITION="$6" DOGFOOD_EXTRA_PROBE="${state}/${role}.probe" DOGFOOD_CREDS="${creds}" \
    DOGFOOD_PROBE_LOG="${state}/${role}.probe.log" DOGFOOD_STATE_DISK="${state}/${role}-var.raw" \
        bash "${here}/dogfood-diskless.sh" "${state}/${role}-set" --check > "${state}/${role}.log" 2>&1
}

echo "==> control plane from homelab-control-plane.bu (log: ${state}/cp.log)"
boot cp "${base_port}" "${DOGFOOD_CP_MEM:-8192}" 5400 21 "${dir}/homelab-control-plane.bu" & cp_pid=$!
pids+=("${cp_pid}")
pass=""
for _ in $(seq 360); do
    pass="$(grep -aoE 'PROBE cp-passphrase=[a-z-]+' "${state}/cp.probe.log" 2>/dev/null | head -n1 | cut -d= -f2)" || true
    [ -n "${pass}" ] && break
    kill -0 "${cp_pid}" 2>/dev/null || break
    sleep 5
done
[ -n "${pass}" ] || { echo "FAIL: the control plane showed no join passphrase" >&2; wait "${cp_pid}" || true; tail -n 40 "${state}/cp.log" >&2; exit 1; }
mkdir -p "${state}/node-creds"
printf '%s' "${pass}" > "${state}/node-creds/bluefin-cluster.passphrase"

echo "==> node from homelab-node.ign with the control plane's passphrase (log: ${state}/node.log)"
boot node "$((base_port + 1))" "${DOGFOOD_NODE_MEM:-4096}" 3600 22 "${dir}/homelab-node.ign" & node_pid=$!
pids+=("${node_pid}")
rc=0
wait "${node_pid}" || rc=1
wait "${cp_pid}" || rc=1
for role in cp node; do grep -aoE 'PROBE[ -].*' "${state}/${role}.log" | grep -v 'PROBE-LOG live' | sed "s/^/${role}: /" || true; done

check() { grep -aqE "$2" "${state}/$1.log" || { echo "FAIL: $1: no match for: $2" >&2; rc=1; }; }
check cp 'PROBE cp-fetch=success argo-workflows-homelab-kubeadm-kubestellar-mcp-via-origin'
check cp 'PROBE cp-merged=argo-workflows_[0-9.]+ homelab_[0-9.]+ kubeadm_[0-9.]+ kubestellar_[0-9.]+ mcp_[0-9.]+ '
check cp 'PROBE cp-features=argo-workflows\.feature\.d homelab\.feature\.d kubeadm\.feature\.d kubestellar\.feature\.d mcp\.feature\.d '
check cp 'PROBE cp-conf role=control-plane mode=600 set=1$'
check cp 'PROBE cp-init=active apply=active/success'
check cp 'PROBE cp-namespaces=argocd,cert-manager,envoy-gateway-system,local-path-storage,metallb-system,reloader,$'
check cp 'PROBE cp-metallb-pools=0'
check cp 'PROBE cp-pvc=Bound class=local-path'
check cp 'PROBE cp-nodes-ready=2 nodes=2'
check cp 'PROBE cp-argo ready=1 1 auth=auth-mode=client notoken=401 token=200$'
check cp 'PROBE cp-mcp ready=1 notoken=401 read=ok write=refused$'
check cp 'PROBE cp-console ready=1 sign-in=password oauth-secret=no dev-mode=0$'
check cp 'PROBE cp-console-gate noauth=401 challenge=1 variant=401 wrong=401 manifest=401 login=307 location=https://kubestellar\.home\.arpa/auth/callback\?onboarded=true cookie=kc_auth me=200 me-nocookie=401 role=admin user=dev-user$'
check cp 'PROBE cp-gateway-tls ready=True verify=0 issuer=homelab-ca http=301 location=https://kubestellar\.home\.arpa/auth/github http-argo=301 secure=1$'
check cp 'PROBE cp-console-netpol direct=blocked gateway=ok$'
check cp 'PROBE cp-console-issue mode=600 url=1 login=1 journal=0$'
check cp 'PROBE cp-console-oauth apply=success sign-in=github ready=1 noauth=401 login=307 github=1 warned=1 secret-logged=0$'
check node 'PROBE node-fetch=success merged=homelab_[0-9.]+ kubeadm_[0-9.]+ '
check node 'PROBE node-joined=yes kubelet=active role=node'
check node 'PROBE node-ready=True'
for role in cp node; do check "${role}" 'PROBE failed=0'; done
[ "${rc}" = 0 ] || exit 1
echo "PASS: control plane from homelab-control-plane.bu applied the default homelab set (monitoring off, MetalLB without a pool); node from homelab-node.ign joined with the shown passphrase; both Ready"
echo "PASS: homelab Gateway: add-ons over HTTPS with a certificate from the homelab CA; port 80 redirects to https before the Console login; kc_auth cookie Secure"
echo "PASS: add-ons: Argo Workflows (auth-mode=client: 401 without a token, 200 with one), MCP server (401 without a token, read ok, write refused)"
echo "PASS: KubeStellar Console deployed without OAuth: /auth/github 401 without the login (any spelling), 307 + kc_auth with it, /api/me 200 as admin dev-user; Service unreachable from another namespace (NetworkPolicy), reachable through the Gateway; login on the console only; GitHub sign-in with OAuth files, still behind the login"
