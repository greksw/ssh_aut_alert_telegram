#!/bin/bash

# Telegram Bot Token
TOKEN="your_telegram_bot_token"
# ID чата (ваш User ID)
CHAT_ID="your_chat_id"

# Имя хоста (название сервера)
HOSTNAME=$(hostname)

# Сообщение
MESSAGE="SSH login detected on server: ${HOSTNAME}. User: $(whoami) from IP: $(hostname -I | awk '{print $1}')"

# Отправка сообщения
curl -s -X POST "https://api.telegram.org/bot${TOKEN}/sendMessage" \
     -d chat_id="${CHAT_ID}" \
     -d text="${MESSAGE}"
