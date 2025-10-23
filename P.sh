#!/bin/bash

# بررسی اینکه کاربر متن وارد کرده یا نه
if [ -z "$1" ]; then
  echo "Usage: ./translate.sh 'your text here'"
  exit 1
fi

TEXT="$1"

# ترجمه با استفاده از Google Translate (وب)
TRANSLATED=$(curl -s -G \
  --data-urlencode "sl=en" \
  --data-urlencode "tl=fa" \
  --data-urlencode "q=$TEXT" \
  "https://translate.googleapis.com/translate_a/single?client=gtx&dt=t" | \
  sed -E 's/\[\[\["(.*?)".*/\1/')

echo "Original: $TEXT"
echo "Translated: $TRANSLATED"
