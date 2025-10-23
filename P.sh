#!/usr/bin/env bash
# P_auto_fallback.sh
# Auto install, patch and run mtprotoproxy — try multiple ports and choose first reachable one.
# Usage: chmod +x P_auto_fallback.sh && ./P_auto_fallback.sh
set -euo pipefail

# Config
IP_PUBLIC="188.210.170.57"
SPONSOR="@configfars"
LOGFILE_BASE="mtproxy"
OUTFILE_BASE="mtproxy"
# candidate ports (order matters — first successful will be used)
PORTS=(8443 443 80 4433 8444 2083 8080)

# Ensure user-local bin in PATH
export PATH="$HOME/.local/bin:$PATH"

# Prechecks
for cmd in python3 pip3 curl; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: نیاز به $cmd است. در ترموکس: pkg install python curl -y"
    exit 1
  fi
done

# Install mtprotoproxy if missing
if ! python3 -c "import mtprotoproxy" >/dev/null 2>&1; then
  echo "[*] Installing mtprotoproxy and pycryptodome (pip --user)..."
  pip3 install --user mtprotoproxy pycryptodome
fi

MT_BIN="$HOME/.local/bin/mtprotoproxy"
# If binary exists patch (safe) — same patch routine as before
if [ -f "$MT_BIN" ]; then
  cp -a "$MT_BIN" "${MT_BIN}.bak" || true
  python3 - "$MT_BIN" <<'PY' 2>/dev/null || true
import sys,re
fn=sys.argv[1]
s=open(fn,"r",encoding="utf-8").read()
orig=s
s=re.sub(r'loop\s*=\s*asyncio\.get_event_loop\(\)','loop = asyncio.new_event_loop(); asyncio.set_event_loop(loop)',s)
s=re.sub(r',\s*loop\s*=\s*loop','',s)
s=re.sub(r'loop\s*=\s*loop\s*,','',s)
s=re.sub(r'loop\s*=\s*loop','',s)
if s!=orig:
  open(fn,"w",encoding="utf-8").write(s)
  print("patched")
else:
  print("no-change")
PY
fi

# helper: generate secret
generate_secret(){ python3 - <<'PY'
import secrets,sys
print(secrets.token_hex(16))
PY
}

# helper: check if port free locally (ss)
is_port_free_locally(){
  local p=$1
  if ss -tuln 2>/dev/null | awk '{print $5}' | grep -Eq "[:.]${p}\$"; then
    return 1
  fi
  return 0
}

# helper: try connect to IP:PORT (nc preferred)
try_connect_ip_port(){
  local ip=$1; local port=$2
  if command -v nc >/dev/null 2>&1; then
    nc -vz -w 3 "$ip" "$port" >/dev/null 2>&1 && return 0 || return 1
  else
    (echo > /dev/tcp/"$ip"/"$port") >/dev/null 2>&1 && return 0 || return 1
  fi
}

# Run loop through ports
SELECTED_PORT=""
SELECTED_SECRET=""
SELECTED_PID=""
for P in "${PORTS[@]}"; do
  echo "--------------------------------"
  echo "[*] Trying port: $P"

  # if P < 1024 and not root, skip with warning
  if [ "$P" -lt 1024 ] && [ "$(id -u)" -ne 0 ]; then
    echo "[!]
    Port $P < 1024 requires root privileges to bind. Skipping (not root)."
    continue
  fi

  # check local free
  if ! is_port_free_locally "$P"; then
    echo "[!] Local port $P is already in use — skipping."
    continue
  fi

  # generate secret for trial
  SECRET=$(generate_secret)
  LOGFILE="${LOGFILE_BASE}_${P}.log"

  # launch proxy: if mtprotoproxy binary exists use it (args: <PORT> <SECRET>), else python -m
  if [ -x "$MT_BIN" ]; then
    nohup "$MT_BIN" "${P}" "${SECRET}" > "$LOGFILE" 2>&1 &
  else
    USER_SITE=$(python3 -c "import site; print(site.getusersitepackages())")
    export PYTHONPATH="${USER_SITE}:${PYTHONPATH:-}"
    nohup python3 -m mtprotoproxy.mtprotoproxy "${P}" "${SECRET}" > "$LOGFILE" 2>&1 &
  fi

  sleep 2

  # find PID of the just started mtprotoproxy for this port (best-effort)
  PID=$(pgrep -af mtprotoproxy | grep -E "${P}" | awk '{print $1}' | head -n1 || true)
  if [ -z "$PID" ]; then
    echo "[!] Process didn't start on port $P. See $LOGFILE"
    tail -n 10 "$LOGFILE" || true
    # ensure killed any leftover
    sleep 1
    pkill -f "mtprotoproxy .*${P}" || true
    continue
  fi

  echo "[*] Started mtprotoproxy (PID: $PID) on local port $P; testing external reachability..."

  # try connecting to the public IP: if NAT/firewall allows, this should succeed (best-effort)
  if try_connect_ip_port "$IP_PUBLIC" "$P"; then
    echo "[OK] Port $P reachable from this host via $IP_PUBLIC:$P"
    SELECTED_PORT="$P"
    SELECTED_SECRET="$SECRET"
    SELECTED_PID="$PID"
    break
  else
    echo "[WARN] Port $P not reachable via $IP_PUBLIC:$P — stopping this instance and trying next port."
    # kill this trial instance
    kill "$PID" >/dev/null 2>&1 || true
    sleep 1
    pkill -f "mtprotoproxy .*${P}" || true
    continue
  fi
done

if [ -z "$SELECTED_PORT" ]; then
  echo "ERROR: نتوانستم پورتی پیدا کنم که هم اجرا شود و هم از طریق IP عمومی قابل دسترسی باشد."
  echo "لطفاً در پنل VPS پورت‌ها را باز کن یا اجرای اسکریپت را به‌صورت روت انجام بده تا پورت‌های <1024 تست شوند."
  exit 1
fi

# Build links and save config
LINK_PLAIN="tg://proxy?server=${IP_PUBLIC}&port=${SELECTED_PORT}&secret=${SELECTED_SECRET}"
LINK_DD="tg://proxy?server=${IP_PUBLIC}&port=${SELECTED_PORT}&secret=dd${SELECTED_SECRET}"
OUTFILE="${OUTFILE_BASE}_${IP_PUBLIC}_${SELECTED_PORT}_configfars.txt"

cat > "$OUTFILE" <<EOF
===== MTProto Proxy (sponsored by ${SPONSOR}) =====
IP: ${IP_PUBLIC}
Port: ${SELECTED_PORT}
Secret(hex): ${SELECTED_SECRET}

Link (plain):
${LINK_PLAIN}

Link (dd-prefixed):
${LINK_DD}

Log file: $(pwd)/${LOGFILE_BASE}_${SELECTED_PORT}.log
NOTE: Sponsor: ${SPONSOR}
EOF

echo "-----------------------------------------"
echo "✅ Selected port: $SELECTED_PORT (PID: $SELECTED_PID)"
echo "Link (plain): $LINK_PLAIN"
echo "Link (dd):    $LINK_DD"
echo ""
echo "Config saved to: $OUTFILE"
echo "Log file: ${LOGFILE_BASE}_${SELECTED_PORT}.log"
echo "If the port selected isn't reachable from your client, check VPS firewall / provider panel."
echo "-----------------------------------------"

exit 0
