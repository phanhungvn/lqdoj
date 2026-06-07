#!/usr/bin/env bash
set -e

APP_DIR="$HOME/online-judge"
VENV_DIR="$HOME/dmojsite"

PORT="8000"

DB_NAME="dmoj"
DB_USER="dmoj"
DB_PASS="123456"

ADMIN_USER="admin"
ADMIN_PASS="admin123456"

echo "=== FIX APT ==="
sudo dpkg --configure -a || true
sudo apt --fix-broken install -y || true
sudo apt autoremove -y || true

echo "=== BASIC TOOLS ==="
sudo apt update
sudo apt install -y curl git wget ca-certificates gnupg lsb-release software-properties-common

echo "=== SYSTEM PACKAGES ==="
sudo apt install -y \
build-essential gcc g++ make pkg-config \
python3 python3-dev python3-pip python3-venv python-is-python3 \
libxml2-dev libxslt1-dev zlib1g-dev gettext \
libjpeg-dev libffi-dev libssl-dev \
redis-server memcached mariadb-server \
libmysqlclient-dev default-libmysqlclient-dev

echo "=== DOCKER ==="
if ! command -v docker >/dev/null 2>&1; then
    sudo apt install -y docker.io docker-compose-plugin
fi

sudo systemctl enable --now docker || sudo service docker start || true
sudo usermod -aG docker "$USER" || true

echo "=== NODE 18 ==="
sudo npm remove -g sass postcss-cli postcss autoprefixer less clean-css-cli >/dev/null 2>&1 || true
sudo apt remove -y nodejs npm >/dev/null 2>&1 || true
sudo apt autoremove -y >/dev/null 2>&1 || true

if ! command -v curl >/dev/null 2>&1; then
    sudo apt update
    sudo apt install -y curl
fi

curl -fsSL https://deb.nodesource.com/setup_18.x | sudo -E bash -
sudo apt install -y nodejs

sudo npm install -g \
sass@1.69.5 \
postcss-cli@10.1.0 \
postcss@8.4.31 \
autoprefixer@10.4.16 \
less@4.2.0 \
clean-css-cli@5.6.3

echo "=== START SERVICES ==="
sudo service mysql start || sudo service mariadb start || true
sudo service redis-server start || true
sudo service memcached start || true

echo "=== DATABASE ==="
sudo mysql <<SQL
CREATE DATABASE IF NOT EXISTS ${DB_NAME}
DEFAULT CHARACTER SET utf8mb4
DEFAULT COLLATE utf8mb4_general_ci;

CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost'
IDENTIFIED BY '${DB_PASS}';

GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL

mariadb-tzinfo-to-sql /usr/share/zoneinfo | sudo mariadb -u root mysql >/dev/null 2>&1 || true

echo "=== CLONE PROJECT ==="
if [ ! -d "$APP_DIR/.git" ]; then
    rm -rf "$APP_DIR"
    git clone https://github.com/LQDJudge/online-judge.git "$APP_DIR"
fi

cd "$APP_DIR"
git pull || true
git submodule update --init --recursive || true

echo "=== PYTHON VENV ==="
if [ ! -d "$VENV_DIR" ]; then
    python3 -m venv "$VENV_DIR"
fi

source "$VENV_DIR/bin/activate"

python3 -m pip install --upgrade pip setuptools wheel
pip install -r requirements.txt
pip install mysqlclient pymemcache django-redis PyMySQL gunicorn || true

echo "=== LOCAL SETTINGS ==="
cat > "$APP_DIR/dmoj/local_settings.py" <<PY
import os

BASE_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

SECRET_KEY = 'lqdoj-auto-secret-key'

DEBUG = True
TEMPLATE_DEBUG = True

ALLOWED_HOSTS = ['*']
CSRF_TRUSTED_ORIGINS = ['http://*', 'https://*']

SITE_ID = 1

DATABASES = {
    'default': {
        'ENGINE': 'django.db.backends.mysql',
        'NAME': '${DB_NAME}',
        'USER': '${DB_USER}',
        'PASSWORD': '${DB_PASS}',
        'HOST': 'localhost',
        'OPTIONS': {
            'charset': 'utf8mb4',
            'sql_mode': 'STRICT_TRANS_TABLES,NO_ENGINE_SUBSTITUTION',
        },
    }
}

CACHES = {
    'default': {
        'BACKEND': 'django.core.cache.backends.memcached.PyMemcacheCache',
        'LOCATION': '127.0.0.1:11211',
    }
}

SESSION_ENGINE = 'django.contrib.sessions.backends.cached_db'

STATIC_URL = '/static/'
STATIC_ROOT = os.path.join(BASE_DIR, 'static')

MEDIA_URL = '/media/'
MEDIA_ROOT = os.path.join(BASE_DIR, 'media')

LANGUAGE_CODE = 'vi'
TIME_ZONE = 'Asia/Ho_Chi_Minh'

USE_I18N = True
USE_L10N = True
USE_TZ = True

BRIDGED_JUDGE_ADDRESS = [('0.0.0.0', 9999)]
BRIDGED_DJANGO_ADDRESS = [('localhost', 9998)]

DMOJ_PROBLEM_DATA_ROOT = os.path.join(BASE_DIR, 'problems')
PY

mkdir -p "$APP_DIR/static" "$APP_DIR/media" "$APP_DIR/problems"

echo "=== FIX CSS ==="
cd "$APP_DIR"

chmod +x make_style.sh || true

sed -i 's/--silence-deprecation=[^ ]*//g' make_style.sh || true
sed -i 's/--silence-deprecation//g' make_style.sh || true
sed -i 's/python manage.py/python3 manage.py/g' make_style.sh || true

./make_style.sh > "$APP_DIR/build.log" 2>&1 || {
    echo "CSS build warning:"
    tail -80 "$APP_DIR/build.log"
}

echo "=== MIGRATE ==="
python3 manage.py migrate --noinput

echo "=== STATIC ==="
python3 manage.py collectstatic --noinput

echo "=== LOAD DATA ==="
python3 manage.py loaddata navbar || true
python3 manage.py loaddata language_small || true
python3 manage.py loaddata demo || true

echo "=== ADMIN ==="
python3 manage.py shell <<PY
from django.contrib.auth import get_user_model

User = get_user_model()

u = User.objects.filter(username='${ADMIN_USER}').first()

if not u:
    User.objects.create_superuser('${ADMIN_USER}', 'admin@example.com', '${ADMIN_PASS}')
else:
    u.set_password('${ADMIN_PASS}')
    u.is_staff = True
    u.is_superuser = True
    u.save()

print('Admin ready')
PY

echo "=== STOP OLD WEB ==="
pkill -f "manage.py runserver" 2>/dev/null || true

echo "=== START WEB BACKGROUND ==="
cd "$APP_DIR"

nohup "$VENV_DIR/bin/python3" manage.py runserver 0.0.0.0:${PORT} > "$APP_DIR/site.log" 2>&1 &

IP=$(hostname -I | awk '{print $1}')

echo ""
echo "======================================"
echo "LQDOJ WEB ĐÃ CHẠY NGẦM"
echo ""
echo "Local : http://localhost:${PORT}"
echo "LAN   : http://${IP}:${PORT}"
echo ""
echo "Admin : ${ADMIN_USER}"
echo "Pass  : ${ADMIN_PASS}"
echo ""
echo "Log:"
echo "tail -f ${APP_DIR}/site.log"
echo ""
echo "Docker đã cài."
echo "Nếu dùng docker lỗi quyền, chạy:"
echo "newgrp docker"
echo "======================================"
SH

chmod +x ~/lqdoj.sh
~/lqdoj.sh
