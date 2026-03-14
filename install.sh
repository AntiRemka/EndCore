#!/bin/bash
# ============================================
#   Telegram MTProto Proxy + Channel TAG
# ============================================

set -e

echo ""
echo "🛡 Установка MTProto Proxy"
echo "================================"
echo ""

# -------------------------------
# 1. Установка Docker
# -------------------------------
if ! command -v docker &>/dev/null; then
    echo "📦 Устанавливаю Docker..."
    apt-get update -qq
    apt-get install -y -qq docker.io >/dev/null 2>&1
    systemctl enable --now docker >/dev/null 2>&1
    echo "✅ Docker установлен"
else
    echo "✅ Docker уже установлен"
fi

# -------------------------------
# 2. Генерация секретов
# -------------------------------

# fakeTLS secret
RAND_PART=$(head -c 16 /dev/urandom | xxd -ps -c 256)
FAKE_SECRET="ee${RAND_PART}7777772e676f6f676c652e636f6d"

# classic secret (16 hex)
CLASSIC_SECRET=$(head -c 16 /dev/urandom | xxd -p -c 32)

echo "🔑 FakeTLS secret создан"
echo "🔑 Classic secret создан"

# -------------------------------
# 3. TAG канала (вставить позже)
# -------------------------------

TAG=""

# -------------------------------
# 4. Получаем IP сервера
# -------------------------------

IP=$(curl -4 -s ifconfig.me || curl -4 -s icanhazip.com || hostname -I | awk '{print $1}')

echo "🌐 IP сервера: $IP"

# -------------------------------
# 5. Создаем папку
# -------------------------------

mkdir -p /opt/mtg

# -------------------------------
# 6. FakeTLS конфиг
# -------------------------------

cat > /opt/mtg/faketls.toml <<EOF
secret = "${FAKE_SECRET}"
bind-to = "0.0.0.0:3128"
prefer-ip = "prefer-ipv4"
tag = "${TAG}"

concurrency = 8192
allow-fallback-on-unknown-dc = true
tolerate-time-skewness = "5s"

[network]
doh-ip = "1.1.1.1"
EOF

# -------------------------------
# 7. Classic конфиг
# -------------------------------

cat > /opt/mtg/classic.toml <<EOF
secret = "${CLASSIC_SECRET}"
bind-to = "0.0.0.0:3128"
prefer-ip = "prefer-ipv4"
EOF

# -------------------------------
# 8. Удаляем старые контейнеры
# -------------------------------

docker rm -f mtg-fake mtg-classic 2>/dev/null || true

# -------------------------------
# 9. Запуск FakeTLS прокси
# -------------------------------

echo "🚀 Запускаю FakeTLS прокси..."

docker run -d \
--name mtg-fake \
--restart always \
-p 443:3128 \
-v /opt/mtg/faketls.toml:/config.toml:ro \
nineseconds/mtg:2 run /config.toml >/dev/null

# -------------------------------
# 10. Запуск Classic прокси
# -------------------------------

echo "🚀 Запускаю Classic прокси..."

docker run -d \
--name mtg-classic \
--restart always \
-p 8443:3128 \
-v /opt/mtg/classic.toml:/config.toml:ro \
nineseconds/mtg:2 run /config.toml >/dev/null

sleep 2

# -------------------------------
# 11. Проверка
# -------------------------------

if docker ps | grep -q mtg-fake; then
    echo "✅ FakeTLS прокси запущен"
else
    echo "❌ Ошибка запуска FakeTLS"
    docker logs mtg-fake
fi

if docker ps | grep -q mtg-classic; then
    echo "✅ Classic прокси запущен"
else
    echo "❌ Ошибка запуска Classic"
    docker logs mtg-classic
fi

# -------------------------------
# 12. Ссылки
# -------------------------------

USER_LINK="https://t.me/proxy?server=${IP}&port=443&secret=${FAKE_SECRET}"

echo ""
echo "========================================"
echo "✅ Прокси установлен"
echo ""

echo "👤 Ссылка для пользователей:"
echo ""
echo "$USER_LINK"
echo ""

echo "🤖 Данные для MTProxyBot:"
echo ""
echo "IP: $IP"
echo "PORT: 8443"
echo "SECRET: $CLASSIC_SECRET"
echo ""

echo "После получения TAG в MTProxyBot"
echo "вставь его в переменную TAG и перезапусти контейнер."
echo "========================================"
