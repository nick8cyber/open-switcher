#!/bin/bash
# Нотаризация (отправка в Apple на одобрение) и штапелирование .app.
# Требуется ОДИН из способов авторизации:
#   1) профиль в связке ключей:  xcrun notarytool store-credentials OpenSwitcherNotary
#      (запросит Apple ID + app-specific password один раз)
#   2) переменные окружения: APPLE_ID, APPLE_APP_SPECIFIC_PASSWORD, TEAM_ID
# Использование: ./notarize.sh build/OpenSwitcher.app
set -e
cd "$(dirname "$0")"
APP="${1:-build/OpenSwitcher.app}"

# ВАЖНО: звать бинарник notarytool НАПРЯМУЮ. Через `xcrun notarytool` связка
# ключей считает его другим приложением (ACL по пути бинарника) и молча
# отвечает «No Keychain password item found» — грабля раунда 5 (2026-09-20).
NOTARY="$(xcrun -f notarytool)"

AUTH_ARGS=()
if [ -n "$APPLE_ID" ] && [ -n "$APPLE_APP_SPECIFIC_PASSWORD" ] && [ -n "$TEAM_ID" ]; then
    AUTH_ARGS=(--apple-id "$APPLE_ID" --password "$APPLE_APP_SPECIFIC_PASSWORD" --team-id "$TEAM_ID")
else
    AUTH_ARGS=(--keychain-profile "OpenSwitcherNotary")
fi

echo ">> Отправка в Apple: $APP"
"$NOTARY" submit "$(dirname "$APP")/$(basename "$APP").zip" \
    "${AUTH_ARGS[@]}" --wait

echo ">> Штапелирование"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
echo ">> Нотаризовано: $APP"
