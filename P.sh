#!/usr/bin/env bash
# getnode_parham.sh
# تلاش می‌کند از https://getafreenode.com کانفیگ vmess پیدا کند،
# هر کدام را پینگ کند، بهترین را انتخاب کند، نام و host/ws را به "parham" تغییر دهد و نمایش دهد.
# اجرا: ./getnode_parham.sh

set -euo pipefail

REQ_CMDS=(curl jq base64 ping awk tr)
for cmd in "${REQ_CMDS[@]}"; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "نیاز به '$cmd' است. لطفاً نصب کنید (مثلاً در ترموکس: pkg install $cmd یا apt install $cmd)."
    exit 1
  fi
done

# helper: safe base64 decode (handles URL-safe variants)
b64_decode() {
  local s="$1"
  # remove newlines/spaces
  s=$(printf "%s" "$s" | tr -d '\r\n')
  # pad
  local mod=$(( ${#s} % 4 ))
  if [ $mod -ne 0 ]; then
    local pad=$((4-mod))
    for ((i=0;i<pad;i++)); do s="${s}="; done
  fi
  # try normal decode, then urlsafe replace and decode
  if printf "%s" "$s" | base64 --decode 2>/dev/null; then
    printf "%s" "$s" | base64 --decode
  else
    s=$(printf "%s" "$s" | tr '_-' '/+')
    printf "%s" "$s" | base64 --decode 2>/dev/null || return 1
  fi
}

# measure latency (ms) to host or IP
measure_latency() {
  local target="$1"
  # resolve if hostname
  local ip="$target"
  if ! printf "%s" "$target" | grep -Eq '^[0-9]+\.'; then
    # try dig then getent
    if command -v dig >/dev/null 2>&1; then
      ip=$(dig +short "$target" | awk 'NF{print $1; exit}')
    else
      ip=$(getent hosts "$target" | awk '{print $1; exit}' || true)
    fi
    [ -z "$ip" ] && ip="$target"
  fi
  # ping 3 times (or 1 if ping doesn't support -c)
  if ping -c 3 -W 1 "$ip" >/dev/null 2>&1; then
    local avg
    avg=$(ping -c 3 -W 1 "$ip" 2>/dev/null | awk -F'/' '/min\/avg\/max/{print $5; exit}')
    printf "%.0f" "$avg" 2>/dev/null || printf "%s" "$avg"
  else
    echo "N/A"
  fi
}

# extract vmess links from page content
extract_vmess_from_html() {
  local html="$1"
  # try to find vmess:// links
  printf "%s\n" "$html" | grep -oE 'vmess://[A-Za-z0-9+/=._-]+' | sed 's/
//g' || true
}

# display menu
cat <<'EOF'
========================
GetBestNode -> parham
1) شروع (اسکن از getafreenode.com و انتخاب بهترین vmess)
q) خروج
========================
EOF

read -rp "انتخاب: " choice
if [ "$choice" != "1" ]; then
  echo "خروج."
  exit 0
fi

echo "[*] دانلود صفحه از https://getafreenode.com ..."
page=$(curl -sL "https://getafreenode.com" || true)

# اگر محتوا با جاوااسکریپت تولید میشه، ممکنه چیزی پیدا نکنیم
echo "[*] جستجوی vmess:// در HTML ..."
vmess_links=$(extract_vmess_from_html "$page")

# اگر چیزی پیدا نشد، سعی می‌کنیم دنبال رشته‌های base64 که شبیه JSON vmess باشند بگردیم
if [ -z "$vmess_links" ]; then
  echo "[!] لینک مستقیم vmess پیدا نشد. تلاش برای پیدا کردن رشته‌های base64 احتمالی..."
  # جستجوی توکن‌های base64 طولانی
  candidates=$(printf "%s\n" "$page" | grep -oE '[A-Za-z0-9+/=]{100,}' | head -n 30 || true)
  while IFS= read -r c; do
    if b64_decode "$c" >/dev/null 2>&1; then
      decoded=$(b64_decode "$c" 2>/dev/null)
      if printf "%s" "$decoded" | jq -e . >/dev/null 2>&1; then
        # احتمالاً JSON vmess
        vmess_links="${vmess_links}
vmess://$(printf "%s" "$c")"
      fi
    fi
  done <<<"$candidates"
fi

if [ -z "$vmess_links" ]; then
  echo "[!!] نتوانستم vmess مستقیم از HTML بگیرم. احتمالاً سایت با JS کانفیگ می‌سازد. برای اتوماسیون کامل نیاز به مرورگر headless (puppeteer/playwright) است."
  exit 1
fi

echo "[*] یافت شد: $(printf "%s\n" "$vmess_links" | wc -l) کانفیگ. در حال پردازش..."
# process each vmess
best_latency=9999999
best_raw=""
index=0
printf "\n"

while IFS= read -r link; do
  [ -z "$link" ] && continue
  index=$((index+1))
  b64part=${link#vmess://}
  decoded=$(b64_decode "$b64part" 2>/dev/null || true)
  if [ -z "$decoded" ]; then
    echo "[$index] خطا در decode"
    continue
  fi
  # ensure valid json
  if ! printf "%s" "$decoded" | jq -e . >/dev/null 2>&1; then
    echo "[$index] decoded is not JSON"
    continue
  fi
  # extract add (address) field for ping
  addr=$(printf "%s" "$decoded" | jq -r '.add // .host // empty' | head -n1)
  port=$(printf "%s" "$decoded" | jq -r '.port // empty' | head -n1)
  if [ -z "$addr" ]; then addr=""; fi
  printf "[%02d] address:%s port:%s ... " "$index" "$addr" "$port"
  latency=$(measure_latency "$addr")
  echo "latency=$latency"
  # convert N/A to large number
  if [ "$latency" = "N/A" ]; then
    numeric_latency=9999999
  else
    # ensure numeric (may be decimal)
    numeric_latency=$(printf "%.0f" "$latency" 2>/dev/null || printf "%s" "$latency")
  fi
  if [ "$numeric_latency" -lt "$best_latency" ]; then
    best_latency=$numeric_latency
    best_raw="$decoded"
    best_b64="$b64part"
    best_index=$index
  fi
done <<<"$(printf "%s\n" "$vmess_links" | sed '/^\s*$/d')"

if [ -z "$best_raw" ]; then
  echo "[!!] هیچ کانفیگی قابل استفاده پیدا نشد."
  exit 1
fi

echo "---------------------------------"
echo "[*] بهترین کانفیگ: شماره $best_index با latency $best_latency ms"
echo "[*] اعمال تغییرات: ps -> parham , host -> parham (در صورت وجود)"
# modify JSON
modified=$(printf "%s" "$best_raw" | jq '(.ps) |= "parham"  | (.host) |= "parham"  | (.add) |= (if . == "" then . else . end) ')

# additionally, if network is ws and there is "wsHost" or "host", set it:
modified=$(printf "%s" "$modified" | jq 'if has("net") and (.net=="ws") then (.host="parham") else . end')

# output JSON prettified
echo ""
echo "=== JSON کانفیگ نهایی ==="
printf "%s\n" "$modified" | jq .

# re-encode to vmess://
encoded=$(printf "%s" "$modified" | jq -c . | base64 | tr -d '\n')
echo ""
echo "=== vmess:// لینک جدید ==="
echo "vmess://$encoded"

echo ""
echo "[*] ذخیره در current_best.json و current_best_vmess.txt"
printf "%s\n" "$modified" > current_best.json
echo "vmess://$encoded" > current_best_vmess.txt

echo "[*] تمام شد."
