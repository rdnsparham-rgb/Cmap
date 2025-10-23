#!/bin/bash

# بررسی اینکه متن وارد شده یا نه
if [ -z "$1" ]; then
  echo "Usage: ./translate.sh 'متن فارسی اینجا'"
  exit 1
fi

TEXT="$1"

# ترجمه با استفاده از Google Translate API رایگان
TRANSLATED=$(curl -s -G \
  --data-urlencode "sl=auto" \
  --data-urlencode "tl=en" \
  --data-urlencode "q=$TEXT" \
  "https://translate.googleapis.com/translate_a/single?client=gtx&dt=t" | \
  sed -E 's/\[\[\["(.*?)".*/\1/')

echo "Original (فارسی): $TEXT"
echo "Translated (انگلیسی): $TRANSLATED"
