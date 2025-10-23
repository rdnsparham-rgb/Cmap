#!/usr/bin/env bash
# create_mtproxy_configfars.sh
# خودکار: نصب mtprotoproxy (در صورت نیاز)، تولید secret، اجرا در پس‌زمینه،
# تست پورت و تولید لینک کانفیگ همراه با برچسب اسپانسر @configfars
#
# اجرا:
# chmod +x create_mtproxy_configfars.sh
# ./create_mtproxy_configfars.sh
#
# پیش‌فرض پورت: 8443 (اگر خواستی پورت را به عنوان آرگومان اول بده: ./script 443)

set -euo pipefail

SPONSOR="@configfars"
DEFAULT_PORT=8443
PORT="${1:-$DEFAULT_PORT}"

# چک نیازمندی‌ها
REQUIRED=(python3 pip3 openssl curl)
MISSING=()
for c in "${REQUIRED[@]}"; do
  if ! command -v "$c" >/dev/null 2>&1; then
    MISSING+=("$c")
  fi
done

if [ ${#MISSING[@]} -ne 0 ]; then
  echo "خطا: این بسته‌ها نصب نیستند: ${MISSING[*]}"
  echo "در ترموکس سعی کن: pkg install python openssl curl -y"
  echo "در دبیان/اوبونتو: sudo apt update && sudo apt install python3 python3-pip openssl curl -y"
  exit 1
fi

# نصب mtprotoproxy در صورت نیاز (در --user نصب می‌کنیم)
if ! python3 -c "import mtprotoproxy" >/dev/null 2>&1; then
  echo "[*] نصب پکیج mtprotoproxy با pip..."
  # سعی کن pip3 نصب باشه
  if ! pip3 install --user mtprotoproxy; then
    echo "نصب mtprotoproxy با خطا روبه‌رو شد. مطمئن شو شبکه و pip درست کار می‌کنند."
    exit 1
  fi
fi

# تولید secret (16 بایت -> 32 hex)
SECRET_HEX=$(openssl rand -hex 16)
echo "[*] secret تولید شد: $SECRET_HEX"

# پیدا کردن آی‌پی عمومی
IP_PUBLIC=$(curl -s https://api.ipify.org || true)
if [ -z "$IP_PUBLIC" ]; then
  echo "هشدار: نتوانستم آی‌پی عمومی را از api.ipify.org بگیرم."
  echo "لطفاً آی‌پی سرور را دستی وارد کن یا بررسی اتصال اینترنت کن."
  read -rp "اگر می‌خواهی آی‌پی را دستی وارد کنی بنویس، در غیر اینصورت Enter بزن: " manual_ip
  if [ -n "$manual_ip" ]; then
    IP_PUBLIC="$manual_ip"
  else
    echo "آی‌پی مشخص نیست؛ خروج."
    exit 1
  fi
fi

# بررسی اینکه آیا پورت موردنظر در دسترس است (قبل اجرا)
echo "[*] بررسی در دسترس بودن پورت $PORT (bind test)..."
# اگر قبلاً سرویسی به پورت متصل است خطا می‌دهیم
if ss -tuln 2>/dev/null | grep -qE "[:.]${PORT}\s"; then
  echo "خطا: پورت $PORT قبلا توسط سرویس دیگری استفاده می‌شود. لطفاً پورت دیگری انتخاب کن."
  exit 1
fi

# اجرای mtprotoproxy در پس‌زمینه
# تلاش برای استفاده از screen یا nohup
RUN_CMD="python3 -m mtprotoproxy.mtprotoproxy --port ${PORT} --secret ${SECRET_HEX}"
echo "[*] اجرای پروکسی: $RUN_CMD"

# اگر screen نصب است از آن استفاده کن تا قابلیت مانیتور داشته باشی
if command -v screen >/dev/null 2>&1; then
  screen -dmS mtproxy_parham bash -c "$RUN_CMD > mtproxy_${PORT}.log 2>&1"
else
  nohup bash -c "$RUN_CMD" > mtproxy_${PORT}.log 2>&1 &
fi

sleep 1
# بررسی اجرا شدن
PID=$(pgrep -f "mtprotoproxy.*--port ${PORT}" || true)
if [ -z "$PID" ]; then
  echo "خطا: سرویس mtprotoproxy اجرا نشد. لاگ را ببین: mtproxy_${PORT}.log"
  tail -n 50 mtproxy_${PORT}.log || true
  exit 1
fi

echo "[*] سرویس اجرا شد (PID: $PID). لاگ: mtproxy_${PORT}.log"

# تست دسترسی از بیرون (nc یا curl تست ساده TCP)
# اگر nc موجود باشد از آن استفاده می‌کنیم
if command -v nc >/dev/null 2>&1; then
  echo "[*] بررسی دسترسی TCP به ${IP_PUBLIC}:${PORT} با nc ..."
  if nc -vz -w 3 "$IP_PUBLIC" "$PORT" >/dev/null 2>&1; then
    PORT_OK=1
  else
    PORT_OK=0
  fi
else
  # fallback به تست اتصال با timeout
  (echo > /dev/tcp/"$IP_PUBLIC"/"$PORT") >/dev/null 2>&1 && PORT_OK=1 || PORT_OK=0
fi

# تولید لینک‌های پیشنهادی (دو نسخه: plain secret و dd-prefixed)
LINK1="tg://proxy?server=${IP_PUBLIC}&port=${PORT}&secret=${SECRET_HEX}"
LINK2="tg://proxy?server=${IP_PUBLIC}&port=${PORT}&secret=dd${SECRET_HEX}"

# ذخیره خروجی با برچسب اسپانسر
OUTFILE="mtproxy_${IP_PUBLIC}_${PORT}_configfars.txt"
{
  echo "===== MTProto Proxy (sponsored by ${SPONSOR}) ====="
  echo "IP: ${IP_PUBLIC}"
  echo "Port: ${PORT}"
  echo "Secret(hex): ${SECRET_HEX}"
  echo ""
  echo "Link (plain):"
  echo "${LINK1}"
  echo ""
  echo "Link (dd-prefixed):"
  echo "${LINK2}"
  echo ""
  echo "Log file: $(pwd)/mtproxy_${PORT}.log"
  echo ""
  echo "NOTE: Sponsor: ${SPONSOR}  — this text is added by the setup script."
  echo "If you want the sponsor to appear to users, include this file or message when sharing the proxy."
} > "$OUTFILE"

# نمایش نتایج
echo "-----------------------------------------"
echo "MTProto proxy راه‌اندازی شد."
echo "آدرس و لینک‌ها در فایل: $OUTFILE"
echo ""
echo "---- Summary ----"
echo "IP: $IP_PUBLIC"
echo "Port: $PORT"
echo "Secret: $SECRET_HEX"
echo ""
echo "Link (plain): $LINK1"
echo "Link (dd-prefixed): $LINK2"
echo ""
if [ "$PORT_OK" -eq 1 ]; then
  echo "[OK] پورت ${PORT} از بیرون قابل دسترسی است."
else
  echo "[WARN] پورت ${PORT} از بیرون قابل دسترسی نیست. ممکن است فایروال/پنل VPS/ISP مانع شده باشد."
  echo "در صورت نیاز در پنل VPS پورت را باز کن یا از پورت دیگری استفاده کن."
fi
echo "-----------------------------------------"

echo ""
echo "نکات نهایی:"
echo "- برای افزودن در تلگرام: Settings → Data and Storage → Proxy → Add Proxy → MTProto و اطلاعات بالا را وارد کن، یا روی لینک کلیک کن."
echo "- فایل کانفیگ با اسپانسر ذخیره شده: $OUTFILE"
echo "- لاگ سرویس: mtproxy_${PORT}.log"
echo ""
echo "تمام شد — Sponsored by ${SPONSOR}"
