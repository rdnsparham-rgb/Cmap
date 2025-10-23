#!/usr/bin/env bash
set -euo pipefail

# نیازمندی‌ها
for cmd in curl jq ping awk base64; do
  command -v $cmd >/dev/null 2>&1 || { echo "نیاز به '$cmd' است. نصب کنید."; exit 1; }
done

# safe base64 decode
b64_decode() {
  local s="$1"
  s=$(printf "%s" "$s" | tr -d '\r\n')
  local mod=$(( ${#s} % 4 ))
  if [ $mod -ne 0 ]; then
    for ((i=0;i<4-mod;i++)); do s="${s}="; done
  fi
  printf "%s" "$s" | base64 --decode 2>/dev/null || return 1
}

measure_latency() {
  local addr="$1"
  ping -c 3 -W 1 "$addr" >/dev/null 2>&1 || echo "9999"
  local avg
  avg=$(ping -c 3 -W 1 "$addr" 2>/dev/null | awk -F'/' '/min\/avg\/max/{print $5; exit}')
  printf "%.0f" "$avg" 2>/dev/null || echo "9999"
}

# دانلود صفحه
echo "[*] دانلود صفحه..."
html=$(curl -sL "https://getafreenode.com")

# پیدا کردن vmess://
echo "[*] جستجوی vmess:// ..."
vmess_links=$(echo "$html" | grep -oE 'vmess://[A-Za-z0-9+/=._-]+')

if [ -z "$vmess_links" ]; then
  echo "[!!] لینک vmess پیدا نشد."
  exit 1
fi

echo "[*] تعداد لینک‌های پیدا شده: $(echo "$vmess_links" | wc -l)"

best_latency=999999
best_json=""
best_b64=""
index=0
best_index=0

while IFS= read -r link; do
  index=$((index+1))
  b64part=${link#vmess://}
  decoded=$(b64_decode "$b64part" 2>/dev/null || continue)
  [ -z "$decoded" ] && continue
  if ! echo "$decoded" | jq -e . >/dev/null 2>&1; then continue; fi
  addr=$(echo "$decoded" | jq -r '.add // .host')
  [ -z "$addr" ] && continue
  latency=$(measure_latency "$addr")
  echo "[$index] $addr latency=$latency ms"
  if [ "$latency" -lt "$best_latency" ]; then
    best_latency=$latency
    best_json="$decoded"
    best_b64="$b64part"
    best_index=$index
  fi
done <<<"$vmess_links"

if [ -z "$best_json" ]; then
  echo "[!!] هیچ کانفیگی معتبر پیدا نشد."
  exit 1
fi

# اصلاح ps و host/add
final=$(echo "$best_json" | jq '.ps="parham" | .host="parham" | .add="parham"')

# نمایش
echo "========================"
echo "[*] بهترین لینک: شماره $best_index با latency $best_latency ms"
echo "[*] کانفیگ JSON:"
echo "$final" | jq .
encoded=$(echo "$final" | jq -c . | base64 | tr -d '\n')
echo "[*] vmess:// لینک نهایی:"
echo "vmess://$encoded"

# ذخیره
echo "$final" > best.json
echo "vmess://$encoded" > best_vmess.txt
echo "[*] ذخیره شد: best.json و best_vmess.txt"
