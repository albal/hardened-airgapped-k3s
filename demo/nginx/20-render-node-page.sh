#!/bin/sh
# Rendered at container start by the stock nginx entrypoint (/docker-entrypoint.d).
#
# Data sources:
#   * downward API   - NODE_NAME, NODE_IP, POD_NAME, POD_IP
#   * /etc/node-demo - ConfigMap written by the installer. One key per node name,
#                      holding key=value facts Ansible gathered from that machine,
#                      plus 'peers', 'cluster-name', 'registry' and 'image'.
#
# Node facts come from the ConfigMap rather than a hostPath mount so the pod can
# run under the 'restricted' Pod Security Standard.
set -eu

HTML_DIR=/usr/share/nginx/html
CONF_DIR=/etc/node-demo
NODE_NAME="${NODE_NAME:-$(hostname)}"
NODE_FILE="${CONF_DIR}/${NODE_NAME}"

# field <key> <fallback>
field() {
  _v=""
  [ -r "${NODE_FILE}" ] && _v="$(sed -n "s/^$1=//p" "${NODE_FILE}" | head -n1)"
  [ -n "${_v}" ] || _v="$2"
  printf '%s' "${_v}"
}
read_or() { if [ -r "$1" ]; then cat "$1"; else printf '%s' "$2"; fi; }

NODE_INDEX="$(field index '?')"
HOST_OS="$(field os "$(sed -n 's/^PRETTY_NAME="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' /etc/os-release)")"
KERNEL="$(field kernel "$(uname -r)")"
ARCH="$(field arch "$(uname -m)")"
CPUS="$(field cpus "$(grep -c '^processor' /proc/cpuinfo 2>/dev/null || echo '?')")"
MEMORY="$(field memory "$(awk '/^MemTotal:/ { printf "%.1f GiB", $2/1048576 }' /proc/meminfo 2>/dev/null)")"
NODE_ADDR="$(field ip "${NODE_IP:-unknown}")"

CLUSTER_NAME="$(read_or "${CONF_DIR}/cluster-name" 'k3s')"
REGISTRY="$(read_or "${CONF_DIR}/registry" 'unknown')"
IMAGE_REF="$(read_or "${CONF_DIR}/image" 'unknown')"
STARTED="$(date -u '+%Y-%m-%d %H:%M:%S UTC')"

# Peers: 'index<TAB>node-name<TAB>url' per line.
PEER_HTML=""
if [ -r "${CONF_DIR}/peers" ]; then
  PEER_HTML="$(awk -F'\t' -v self="${NODE_NAME}" '
    NF >= 3 {
      cls = ($2 == self) ? "peer self" : "peer"
      printf "<a class=\"%s\" href=\"%s\">Node %s<span>%s</span></a>\n", cls, $3, $1, $2
    }' "${CONF_DIR}/peers")"
fi

cat > "${HTML_DIR}/info.json" <<JSON
{
  "nodeIndex": "${NODE_INDEX}",
  "nodeName": "${NODE_NAME}",
  "nodeIP": "${NODE_ADDR}",
  "podName": "${POD_NAME:-unknown}",
  "podIP": "${POD_IP:-unknown}",
  "os": "${HOST_OS}",
  "kernel": "${KERNEL}",
  "arch": "${ARCH}",
  "cpus": "${CPUS}",
  "memory": "${MEMORY}",
  "cluster": "${CLUSTER_NAME}",
  "registry": "${REGISTRY}",
  "image": "${IMAGE_REF}",
  "startedAt": "${STARTED}"
}
JSON

{
cat <<HTML
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Node ${NODE_INDEX} &middot; ${CLUSTER_NAME}</title>
<style>
  :root { --bg:#f6f7f9; --card:#fff; --ink:#12161c; --muted:#5c6673; --line:#e3e7ec; --accent:#2f6feb; }
  @media (prefers-color-scheme: dark) {
    :root { --bg:#0e1116; --card:#161b22; --ink:#e6edf3; --muted:#8b949e; --line:#26303b; --accent:#4d8ffd; }
  }
  * { box-sizing:border-box; }
  body { margin:0; background:var(--bg); color:var(--ink);
         font:15px/1.55 ui-sans-serif,system-ui,-apple-system,"Segoe UI",Roboto,sans-serif; }
  .wrap { max-width:760px; margin:0 auto; padding:40px 20px 64px; }
  .badge { display:inline-block; font-size:12px; letter-spacing:.08em; text-transform:uppercase;
           color:var(--muted); border:1px solid var(--line); border-radius:999px; padding:4px 12px; }
  h1 { font-size:clamp(46px,12vw,84px); line-height:1; margin:18px 0 6px; letter-spacing:-.03em; }
  .host { color:var(--muted); font-family:ui-monospace,SFMono-Regular,Menlo,monospace; font-size:14px; }
  .card { background:var(--card); border:1px solid var(--line); border-radius:14px; margin-top:28px; overflow:hidden; }
  .card h2 { font-size:12px; letter-spacing:.08em; text-transform:uppercase; color:var(--muted);
             margin:0; padding:14px 18px; border-bottom:1px solid var(--line); }
  dl { margin:0; display:grid; grid-template-columns:minmax(120px,180px) 1fr; }
  dt, dd { margin:0; padding:9px 18px; border-bottom:1px solid var(--line); }
  dt { color:var(--muted); }
  dd { font-family:ui-monospace,SFMono-Regular,Menlo,monospace; font-size:13px; word-break:break-all; }
  dl > :nth-last-child(1), dl > :nth-last-child(2) { border-bottom:0; }
  .peers { display:flex; gap:10px; flex-wrap:wrap; margin-top:28px; }
  .peer { flex:1 1 180px; text-decoration:none; color:var(--ink); background:var(--card);
          border:1px solid var(--line); border-radius:12px; padding:12px 14px; font-weight:600; }
  .peer span { display:block; font-weight:400; font-size:12px; color:var(--muted);
               font-family:ui-monospace,Menlo,monospace; margin-top:2px; }
  .peer.self { border-color:var(--accent); box-shadow:inset 0 0 0 1px var(--accent); }
  .peer:hover { border-color:var(--accent); }
  footer { margin-top:28px; color:var(--muted); font-size:12px; }
  code { font-size:12px; }
</style>
</head>
<body>
  <div class="wrap">
    <span class="badge">${CLUSTER_NAME} &middot; airgapped k3s</span>
    <h1>Node ${NODE_INDEX}</h1>
    <div class="host">${NODE_NAME} &middot; ${NODE_ADDR}</div>

    <div class="card">
      <h2>Node details</h2>
      <dl>
        <dt>Operating system</dt><dd>${HOST_OS}</dd>
        <dt>Kernel</dt><dd>${KERNEL}</dd>
        <dt>Architecture</dt><dd>${ARCH}</dd>
        <dt>CPUs</dt><dd>${CPUS}</dd>
        <dt>Memory</dt><dd>${MEMORY}</dd>
        <dt>Node IP</dt><dd>${NODE_ADDR}</dd>
      </dl>
    </div>

    <div class="card">
      <h2>Pod</h2>
      <dl>
        <dt>Pod name</dt><dd>${POD_NAME:-unknown}</dd>
        <dt>Pod IP</dt><dd>${POD_IP:-unknown}</dd>
        <dt>Image</dt><dd>${IMAGE_REF}</dd>
        <dt>Pulled from</dt><dd>${REGISTRY}</dd>
        <dt>Started</dt><dd>${STARTED}</dd>
      </dl>
    </div>

    <div class="peers">${PEER_HTML}</div>
    <footer>Served by the nginx pod on this node only &mdash; the Service uses
      <code>externalTrafficPolicy: Local</code>, so every node IP answers with its own page.
      Machine-readable copy at <a href="/info.json">/info.json</a>.</footer>
  </div>
</body>
</html>
HTML
} > "${HTML_DIR}/index.html"
