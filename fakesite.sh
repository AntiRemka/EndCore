#!/usr/bin/env bash

# Порт по умолчанию для локального https-сервера (selfsni / reality dest)
SPORT=9000

# Разбор аргументов
WITHOUT_80=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --selfsni-port)
            if [[ -n "$2" && "$2" =~ ^[0-9]+$ ]]; then
                SPORT="$2"
                shift 2
            else
                echo "Ошибка: после --selfsni-port нужен корректный порт (число)"
                exit 1
            fi
            ;;
        --without-80)
            WITHOUT_80=1
            shift
            ;;
        *)
            echo "Неизвестный аргумент: $1"
            echo "Использование: $0 [--selfsni-port <порт>] [--without-80]"
            exit 1
            ;;
    esac
done

# Проверка, что это Ubuntu / Debian
if ! grep -qE "^(ID=debian|ID=ubuntu)" /etc/os-release; then
    echo "Скрипт предназначен только для Debian / Ubuntu"
    exit 1
fi

# Запрос домена
read -r -p "Введите доменное имя (пример: example.com): " DOMAIN
if [[ -z "$DOMAIN" ]]; then
    echo "Доменное имя не может быть пустым"
    exit 1
fi

# Получаем внешний IP
external_ip=$(curl -s --max-time 5 https://api.ipify.org || curl -s --max-time 5 https://ifconfig.me)
if [[ -z "$external_ip" ]]; then
    echo "Не удалось определить внешний IP сервера"
    exit 1
fi

echo "Внешний IP сервера: $external_ip"

# Проверяем A-запись
domain_ip=$(dig +short A "$DOMAIN" | tail -n 1)
if [[ -z "$domain_ip" ]]; then
    echo "Не удалось получить A-запись для $DOMAIN"
    echo "Подробнее: https://wiki.yukikras.net/ru/selfsni"
    exit 1
fi

echo "A-запись домена: $domain_ip"

if [[ "$domain_ip" != "$external_ip" ]]; then
    echo "A-запись домена НЕ совпадает с IP сервера!"
    echo "Подробнее: https://wiki.yukikras.net/ru/selfsni#a-запись-домена-не-соответствует-внешнему-ip-сервера"
    exit 1
fi

# Проверка занятых портов
if ss -tuln | grep -q ":443 "; then
    echo "Порт 443 занят. Освободите его."
    echo "Подробнее → https://wiki.yukikras.net/ru/selfsni"
    exit 1
fi

if [[ $WITHOUT_80 -eq 0 ]]; then
    if ss -tuln | grep -q ":80 "; then
        echo "Порт 80 занят. Освободите его или используйте --without-80"
        exit 1
    fi
else
    echo "Режим --without-80 → порт 80 не проверяется"
fi

echo "Установка необходимых пакетов..."

# Обновляем систему и ставим нужное
apt update -qq && apt upgrade -y -qq
apt install -y nginx curl git snapd

# Устанавливаем свежий certbot через snap (рекомендуемый способ на 22.04+)
snap install core
snap refresh core
snap install --classic certbot
ln -sf /snap/bin/certbot /usr/bin/certbot

# Скачиваем любой шаблон сайта (чтобы был хоть какой-то контент)
TEMP_DIR=$(mktemp -d)
git clone https://github.com/learning-zone/website-templates.git "$TEMP_DIR" --depth=1 || {
    echo "Не удалось скачать шаблоны сайтов"
    exit 1
}

SITE_DIR=$(find "$TEMP_DIR" -mindepth 1 -maxdepth 1 -type d | shuf -n 1)
mkdir -p /var/www/html
cp -r "$SITE_DIR"/* /var/www/html/
chown -R www-data:www-data /var/www/html

# Выпуск сертификата
echo "Запускаем certbot..."

if [[ $WITHOUT_80 -eq 1 ]]; then
    echo "Получаем сертификат через tls-alpn-01 (только 443 порт)"
    certbot certonly --nginx \
        -d "$DOMAIN" \
        --agree-tos \
        --email "admin@$DOMAIN" \
        --non-interactive \
        --preferred-challenges tls-alpn-01 || {
            echo "Ошибка получения сертификата через tls-alpn-01"
            exit 1
        }
else
    echo "Получаем сертификат через http-01 (80 + 443)"
    certbot --nginx \
        -d "$DOMAIN" \
        --agree-tos \
        --email "admin@$DOMAIN" \
        --non-interactive || {
            echo "Ошибка получения сертификата"
            exit 1
        }
fi

# Проверяем, что сертификаты появились
CERT_DIR="/etc/letsencrypt/live/$DOMAIN"
if [[ ! -f "$CERT_DIR/fullchain.pem" || ! -f "$CERT_DIR/privkey.pem" ]]; then
    echo "Сертификаты не найдены в $CERT_DIR"
    exit 1
fi

# Создаём конфиг nginx
cat > /etc/nginx/sites-enabled/selfsni.conf <<EOF
server {
    listen 80;
    server_name $DOMAIN;

    # Редирект на https (даже если --without-80, оставляем на случай будущего открытия 80)
    return 301 https://\$host\$request_uri;
}

server {
    listen 127.0.0.1:$SPORT ssl http2 proxy_protocol;
    server_name $DOMAIN;

    ssl_certificate     $CERT_DIR/fullchain.pem;
    ssl_certificate_key $CERT_DIR/privkey.pem;

    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305;
    ssl_prefer_server_ciphers on;

    ssl_stapling on;
    ssl_stapling_verify on;

    resolver 8.8.8.8 8.8.4.4 valid=300s;
    resolver_timeout 5s;

    # proxy_protocol (важно для 3x-ui / marzban / xray и т.д.)
    real_ip_header proxy_protocol;
    set_real_ip_from 127.0.0.1;

    location / {
        root /var/www/html;
        index index.html index.htm;
        try_files \$uri \$uri/ /index.html;
    }
}
EOF

# Отключаем дефолтный конфиг
[[ -f /etc/nginx/sites-enabled/default ]] && rm -f /etc/nginx/sites-enabled/default

# Проверяем и перезапускаем nginx
nginx -t && systemctl reload nginx || {
    echo "Ошибка в конфигурации nginx — проверьте 'nginx -t'"
    exit 1
}

# Итог
echo ""
echo "═══════════════════════════════════════════════════════"
echo " SelfSNI успешно настроен!"
echo ""
echo "Сертификат:     $CERT_DIR/fullchain.pem"
echo "Ключ:           $CERT_DIR/privkey.pem"
echo ""
echo "Для Reality / XRay / VLESS+REALITY:"
echo "  Dest →  127.0.0.1:$SPORT"
echo "  SNI  →  $DOMAIN"
echo "═══════════════════════════════════════════════════════"
echo ""

# Чистим временные файлы
rm -rf "$TEMP_DIR"

echo "Готово."
