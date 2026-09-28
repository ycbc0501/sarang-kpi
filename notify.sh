#!/bin/zsh
# Sends a Telegram DM to the user through the existing bridge bot on 집컴
# (token + user id are read from ~/claude-telegram-bridge/.env; nothing is printed).
# Usage: notify.sh "<subtitle>" "<message>"  — exit 0 when Telegram accepted the message.
ENV="$HOME/claude-telegram-bridge/.env"
TOKEN=$(sed -n 's/^TELEGRAM_BOT_TOKEN=//p' "$ENV" | tr -d '"'"'"' \r')
CHAT=$(sed -n 's/^ALLOWED_USERS=//p' "$ENV" | tr -d '"'"'"' \r' | cut -d, -f1)
[[ -n "$TOKEN" && -n "$CHAT" ]] || exit 1
TEXT="💎 사랑 찾는 KPI — $1
$2"
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" \
  --data-urlencode "chat_id=$CHAT" --data-urlencode "text=$TEXT")
[[ "$code" == "200" ]]
