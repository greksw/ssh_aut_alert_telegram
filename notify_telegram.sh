#!/bin/bash

# Telegram Bot Token
TOKEN="your_telegram_bot_token"
# ID чата (ваш User ID)
CHAT_ID="your_chat_id"

# Сообщение
MESSAGE="SSH login detected: $(whoami) from $(hostname -I | awk '{print $1}')"

# Отправка сообщения
curl -s -X POST "https://api.telegram.org/bot${TOKEN}/sendMessage" \
     -d chat_id="${CHAT_ID}" \
     -d text="${MESSAGE}"
