#!/usr/bin/env bash
# getnode_parham_auto.sh
# نسخهٔ خودکار: هنگام اجرا کل جریان را اجرا می‌کند:
# 1) دانلود صفحه https://getafreenode.com
# 2) جستجوی vmess:// یا رشته‌های base64 حاوی JSON
# 3) پینگ هر کدام و انتخاب بهترین با کمترین latency
# 4) تغییر ps و host/add به "parham"
# 5) نمایش و ذخیرهٔ خروجی
# اجرا: chmod +x getnode_parham_auto.sh && ./getnode_parham_auto.sh

set -euo pipefail

REQ_CMDS=(curl jq base64 ping awk tr)
for cmd in "${REQ_CMDS[@]}"; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "نیاز به '$cmd' است. لطفاً آن را نصب کنید (مثلاً در ترموکس: pkg install $cmd)."
    exit 1
  fi
done

# helper: safe base64 decode (handles URL-safe variants)
b64_decode() {
  local s="$1"
  s=$(printf "%s" "$s" | tr -d '\r\n')
  local mod=$(( ${#s} % 4 ))
  if [ $mod -ne 0 ]; then
    local pad=$((4-mod))
    for ((i=0;i<pad;i++)); do s="${s}="; done
  fi
  if printf "%s" "$s" | base64 --decode 2>/dev/null; then
    printf "%s" "$s" | base64 --decode
  else
    s=$(printf "%s" "$s" | tr '_-' '/+')
    printf "%s" "$s" | base64 --decode 2>/dev/null || return 1
  fi
}

measure_latency() {
  local target="$1"
  local ip="$target"
  if ! printf "%s" "$target" | grep -Eq '^[0-9]+\.'; then
    if command -v dig >/dev/null 2>&1; then
      ip=$(dig +short "$target" | awk 'NF{print $1; exit}')
    else
      ip=$(getent hosts "$target" | awk '{print $1; exit}' || true)
    fi
    [ -z "$ip" ] && ip="$target"
  fi
  if ping -c 3 -W 1 "$ip" >/dev/null 2>&1; then
    local avg
    avg=$(ping -c 3 -W 1 "$ip" 2>/dev/null | awk -F'/' '/min\/avg\/max/{print $5; exit}')
    printf "%.0f" "$avg" 2>/dev/null || printf "%s" "$avg"
  else
    echo "N/A"
  fi
}

extract_vmess_from_html() {
  local html="$1"
  printf "%s\n" "$html" | grep -oE 'vmess://[A-Za-z0-9+/=._-]+' | sed 's/
//g' || true
}

echo "======================================="
echo "GetBestNode (auto) -> parham"
echo "شروع خودکار..."
echo "======================================="

echo "[*] دانلود صفحه از https://getafreenode.com ..."
page=$(curl -sL "https://getafreenode.com" || true)

echo "[*] جستجوی vmess:// در HTML ..."
vmess_links=$(extract_vmess_from_html "$page")

if [ -z "$vmess_links" ]; then
  echo "[!] لینک مستقیم vmess پیدا نشد. تلاش برای پیدا کردن رشته‌های base64 احتمالی..."
  candidates=$(printf "%s\n" "$page" | grep -oE '[A-Za-z0-9+/=]{100,}' | head -n 40 || true)
  while IFS= read -r c; do
    [ -z "$c" ] && continue
    if b64_decode "$c" >/dev/null 2>&1; then
      decoded=$(b64_decode "$c" 2>/dev/null)
      if printf "%s" "$decoded" | jq -e . >/dev/null 2>&1; then
        vmess_links="${vmess_links}
vmess://$(printf "%s" "$c")"
      fi
    fi
  done <<<"$candidates"
fi

if [ -z "$vmess_links" ]; then
  echo "[!!] نتوانستم vmess مستقیم از HTML بگیرم. احتمالاً سایت با JS کانفیگ می‌سازد."
  echo "برای اتوماسیون کامل نیاز به مرورگر headless (puppeteer/playwright) است."
  exit 1
fi

echo "[*] یافت شد: $(printf "%s\n" "$vmess_links" | sed '/^\s*$/d' | wc -l) کانفیگ. در حال پردازش..."
best_latency=9999999
best_raw=""
best_b64=""
best_index=0
index=0

while IFS= read -r link; do
  [ -z "$link" ] && continue
  index=$((index+1))
  b64part=${link#vmess://}
  decoded=$(b64_decode "$b64part" 2>/dev/null || true)
  if [ -z "$decoded" ]; then
    echo "[$index] خطا در decode - رد شد"
    continue
  fi
  if ! printf "%s" "$decoded" | jq -e . >/dev/null 2>&1; then
    echo "[$index] JSON معتبر نیست - رد شد"
    continue
  fi
  addr=$(printf "%s" "$decoded" | jq -r '.add // .host // empty' | head -n1)
  port=$(printf "%s" "$decoded" | jq -r '.port // empty' | head -n1)
  if [ -z "$addr" ]; then addr=""; fi
  printf "[%02d] address:%s port:%s ... " "$index" "$addr" "$port"
  latency=$(measure_latency "$addr")
  echo "latency=$latency"
  if [ "$latency" = "N/A" ]; then
    numeric_latency=9999999
  else
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
echo "[*] اعمال تغییرات: ps -> parham , host/add -> parham (در صورت وجود)"
modified=$(printf "%s" "$best_raw" | jq '(.ps) |= "parham"  | (.host) |= "parham"  | (.add) |= (if . == "" then . else . end) ')
modified=$(printf "%s" "$modified" | jq 'if has("net") and (.net=="ws") then (.host="parham") else . end')

echo ""
echo "=== JSON کانفیگ نهایی ==="
printf "%s\n" "$modified" | jq .

encoded=$(printf "%s" "$modified" | jq -c . | base64 | tr -d '\n')
echo ""
echo "=== vmess:// لینک جدید ==="
echo "vmess://$encoded"

printf "%s\n" "$modified" > current_best.json
echo "vmess://$encoded" > current_best_vmess.txt

echo "[*] ذخیره شد: current_best.json و current_best_vmess.txt"
echo "[*] پایان."
