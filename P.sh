#!/usr/bin/env bash
# P_auto.sh - Auto install, patch and run mtprotoproxy (Termux-ready)
# Usage: chmod +x P_auto.sh && ./P_auto.sh
set -euo pipefail

# Config
IP_PUBLIC="188.210.170.57"
PORT="${1:-8443}"
SPONSOR="@configfars"
LOGFILE="mtproxy_${PORT}.log"
OUTFILE="mtproxy_${IP_PUBLIC}_${PORT}_configfars.txt"

# Ensure user-local bin in PATH (pip --user installs here)
export PATH="$HOME/.local/bin:$PATH"

# Install system packages (Termux-friendly). If already installed, pkg will skip.
if command -v pkg >/dev/null 2>&1; then
  echo "[*] Installing required packages (termux): python curl openssl - if not present"
  pkg update -y >/dev/null 2>&1 || true
  pkg install -y python curl openssl >/dev/null 2>&1 || true
else
  echo "[*] Non-Termux environment detected. Make sure python3, pip3 and curl are installed."
fi

# Ensure pip3 available
if ! command -v pip3 >/dev/null 2>&1; then
  echo "ERROR: pip3 not found. Install pip3 and re-run."
  exit 1
fi

# Install mtprotoproxy + pycryptodome to user site if missing
if ! python3 -c "import mtprotoproxy" >/dev/null 2>&1; then
  echo "[*] Installing mtprotoproxy and pycryptodome (pip --user)..."
  pip3 install --user mtprotoproxy pycryptodome
else
  echo "[*] mtprotoproxy already installed in user site-packages"
fi

MT_BIN="$HOME/.local/bin/mtprotoproxy"

# If binary exists, backup and patch to be compatible with Python 3.12's asyncio (remove loop=loop usage)
if [ -f "$MT_BIN" ]; then
  echo "[*] Found $MT_BIN — creating backup and applying compatibility patch..."
  cp -a "$MT_BIN" "${MT_BIN}.bak" || { echo "ERROR: could not create backup ${MT_BIN}.bak"; exit 1; }

  # Run a small python patcher that edits the file in-place
  python3 - "$MT_BIN" <<'PY'
import sys, re
fn = sys.argv[1]
text = open(fn, "r", encoding="utf-8").read()
orig = text
# Replace get_event_loop() with new_event_loop + set_event_loop
text = re.sub(r'loop\s*=\s*asyncio\.get_event_loop\(\)', 'loop = asyncio.new_event_loop(); asyncio.set_event_loop(loop)', text)
# Remove occurrences of ", loop=loop" or "loop=loop," or "loop=loop"
text = re.sub(r',\s*loop\s*=\s*loop', '', text)
text = re.sub(r'loop\s*=\s*loop\s*,', '', text)
text = re.sub(r'loop\s*=\s*loop', '', text)
if text != orig:
    open(fn, "w", encoding="utf-8").write(text)
    print("patched")
else:
    print("no-change")
PY

else
  echo "[*] $MT_BIN not found — will run via python -m if needed."
fi

# Generate secret (hex 32 chars)
SECRET_HEX=$(python3 - <<'PY'
import secrets
print(secrets.token_hex(16))
PY
)
echo "[*] secret: $SECRET_HEX"

# Start proxy:
# Preferred: use binary in ~/.local/bin if present (it expects args: <PORT> <SECRET>)
# Fallback: python3 -m mtprotoproxy.mtprotoproxy <PORT> <SECRET> after setting PYTHONPATH
if [ -x "$MT_BIN" ]; then
  echo "[*] Launching mtprotoproxy binary..."
  nohup "$MT_BIN" "${PORT}" "${SECRET_HEX}" > "$LOGFILE" 2>&1 &
else
  # ensure user site is in PYTHONPATH
  USER_SITE=$(python3 -c "import site; print(site.getusersitepackages())")
  export PYTHONPATH="${USER_SITE}:${PYTHONPATH:-}"
  echo "[*] Launching mtprotoproxy using python -m ..."
  nohup python3 -m mtprotoproxy.mtprotoproxy "${PORT}" "${SECRET_HEX}" > "$LOGFILE" 2>&1 &
fi

# Wait and check
sleep 2
PID=$(pgrep -af mtprotoproxy | awk '{print $1}' | head -n1 || true)
if [ -z "$PID" ]; then
  echo "ERROR: Service did not start. See last lines of $LOGFILE"
  echo "---- tail $LOGFILE ----"
  tail -n 40 "$LOGFILE" || true
  exit 1
fi

# Test if port reachable from this host (best-effort)
PORT_OK=0
if command -v nc >/dev/null 2>&1; then
  if nc -vz -w 3 "$IP_PUBLIC" "$PORT" >/dev/null 2>&1; then
    PORT_OK=1
  fi
else
  (echo > /dev/tcp/"$IP_PUBLIC"/"$PORT") >/dev/null 2>&1 && PORT_OK=1 || PORT_OK=0
fi

# Build tg:// links (plain and dd-prefixed)
LINK_PLAIN="tg://proxy?server=${IP_PUBLIC}&port=${PORT}&secret=${SECRET_HEX}"
LINK_DD="tg://proxy?server=${IP_PUBLIC}&port=${PORT}&secret=dd${SECRET_HEX}"

# Save output file with sponsor note
cat > "$OUTFILE" <<EOF
===== MTProto Proxy (sponsored by ${SPONSOR}) =====
IP: ${IP_PUBLIC}
Port: ${PORT}
Secret(hex): ${SECRET_HEX}

Link (plain):
${LINK_PLAIN}

Link (dd-prefixed):
${LINK_DD}

Log file: $(pwd)/${LOGFILE}
NOTE: This configuration was created by P_auto.sh — Sponsor: ${SPONSOR}
EOF

# Print summary
echo "-----------------------------------------"
echo "✅ MTProto proxy started (PID: $PID)"
echo "IP: $IP_PUBLIC"
echo "Port: $PORT"
echo "Secret: $SECRET_HEX"
echo ""
echo "Link (plain): $LINK_PLAIN"
echo "Link (dd):    $LINK_DD"
echo ""
if [ "$PORT_OK" -eq 1 ]; then
  echo "[OK] Port ${PORT} is reachable from this host."
else
  echo "[WARN] Port ${PORT} might not be reachable from outside. Check VPS firewall / provider panel."
fi
echo ""
echo "Config saved to: $OUTFILE"
echo "Log: $LOGFILE"
echo "Sponsor tag: $SPONSOR"
echo "-----------------------------------------"
