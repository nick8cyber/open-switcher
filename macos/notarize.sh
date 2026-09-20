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

AUTH_ARGS=()
if [ -n "$APPLE_ID" ] && [ -n "$APPLE_APP_SPECIFIC_PASSWORD" ] && [ -n "$TEAM_ID" ]; then
    AUTH_ARGS=(--apple-id "$APPLE_ID" --password "$APPLE_APP_SPECIFIC_PASSWORD" --team-id "$TEAM_ID")
else
    AUTH_ARGS=(--keychain-profile "OpenSwitcherNotary")
fi

echo ">> Отправка в Apple: $APP"
xcrun notarytool submit "$(dirname "$APP")/$(basename "$APP").zip" \
    "${AUTH_ARGS[@]}" --wait

echo ">> Штапелирование"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
echo ">> Нотаризовано: $APP"
