#!/usr/bin/env bash
set -e

APP_DIR="$HOME/online-judge"
VENV_DIR="$HOME/dmojsite"
JUDGE_SERVER_DIR="$HOME/judge-server"

PORT="8000"

DB_NAME="dmoj"
DB_USER="dmoj"
DB_PASS="123456"

ADMIN_USER="admin"
ADMIN_PASS="admin123456"

JUDGE_ID="${JUDGE_ID:-Maycham01}"
JUDGE_KEY="${JUDGE_KEY:-a}"
PROBLEMS_DIR="${PROBLEMS_DIR:-$APP_DIR/problems}"
JUDGE_IMAGE="${JUDGE_IMAGE:-vnoj/judge-tier1:latest}"

fix_apt() {
    sudo dpkg --configure -a || true
    sudo apt --fix-broken install -y || true
    sudo apt autoremove -y || true
}

echo "=== FIX APT ==="
fix_apt

echo "=== INSTALL PACKAGES ==="
sudo apt update

# Cài các gói nền trước. KHÔNG cài docker-compose-plugin ở đây
# vì nhiều bản Ubuntu/Debian không có package này trong repo mặc định.
sudo apt install -y \
    curl git wget ca-certificates gnupg lsb-release software-properties-common \
    build-essential gcc g++ make pkg-config \
    python3 python3-dev python3-pip python3-venv python-is-python3 \
    libxml2-dev libxslt1-dev zlib1g-dev gettext \
    libjpeg-dev libffi-dev libssl-dev libseccomp-dev \
    redis-server memcached mariadb-server \
    libmysqlclient-dev default-libmysqlclient-dev \
    docker.io

install_docker_compose() {
    echo "=== INSTALL DOCKER COMPOSE ==="

    # Cách 1: thử cài plugin nếu repo có. Nếu không có thì bỏ qua, không dừng script.
    if apt-cache policy docker-compose-plugin 2>/dev/null | grep -q "Candidate: [^(]"; then
        sudo apt install -y docker-compose-plugin || true
    else
        echo "docker-compose-plugin không có trong repo apt hiện tại -> dùng bản standalone."
    fi

    # Nếu đã có docker compose v2 thì xong.
    if docker compose version >/dev/null 2>&1; then
        docker compose version || true
        return 0
    fi

    # Cách 2: fallback cài docker-compose standalone.
    COMPOSE_VERSION="${COMPOSE_VERSION:-v2.27.1}"
    ARCH="$(uname -m)"
    case "$ARCH" in
        x86_64|amd64) COMPOSE_ARCH="x86_64" ;;
        aarch64|arm64) COMPOSE_ARCH="aarch64" ;;
        armv7l) COMPOSE_ARCH="armv7" ;;
        *) COMPOSE_ARCH="$ARCH" ;;
    esac

    sudo curl -L "https://github.com/docker/compose/releases/download/${COMPOSE_VERSION}/docker-compose-linux-${COMPOSE_ARCH}" \
        -o /usr/local/bin/docker-compose
    sudo chmod +x /usr/local/bin/docker-compose

    # Tạo wrapper để lệnh `docker compose` cũng chạy được nếu máy thiếu plugin.
    sudo mkdir -p /usr/local/lib/docker/cli-plugins
    sudo ln -sf /usr/local/bin/docker-compose /usr/local/lib/docker/cli-plugins/docker-compose

    docker-compose version || true
    docker compose version || true
}

install_docker_compose

sudo systemctl enable --now docker || sudo service docker start || true
sudo usermod -aG docker "$USER" || true

echo "=== NODE 18 ==="
sudo npm remove -g sass postcss-cli postcss autoprefixer less clean-css-cli >/dev/null 2>&1 || true
sudo apt remove -y nodejs npm >/dev/null 2>&1 || true
sudo apt autoremove -y >/dev/null 2>&1 || true

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

echo "=== CLONE ONLINE-JUDGE ==="
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
python3 -m pip install --upgrade pip setuptools wheel cython
pip install -r requirements.txt
pip install mysqlclient pymemcache django-redis PyMySQL gunicorn || true

echo "=== LOCAL SETTINGS ==="
cat > "$APP_DIR/dmoj/local_settings.py" <<PY
import os

BASE_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

SECRET_KEY = 'lqdoj-full-docker-secret'
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

EMAIL_BACKEND = 'django.core.mail.backends.console.EmailBackend'
DEFAULT_FROM_EMAIL = 'no-reply@localhost'
SERVER_EMAIL = 'no-reply@localhost'
REGISTRATION_OPEN = True

BRIDGED_JUDGE_ADDRESS = [('0.0.0.0', 9999)]
BRIDGED_DJANGO_ADDRESS = [('localhost', 9998)]

DMOJ_PROBLEM_DATA_ROOT = os.path.join(BASE_DIR, 'problems')
PY

mkdir -p "$APP_DIR/static" "$APP_DIR/media" "$PROBLEMS_DIR" "$APP_DIR/logs"

echo "=== FIX CSS SCRIPT ==="
cd "$APP_DIR"
chmod +x make_style.sh || true
sed -i 's/--silence-deprecation=[^ ]*//g' make_style.sh || true
sed -i 's/--silence-deprecation//g' make_style.sh || true
sed -i 's/python manage.py/python3 manage.py/g' make_style.sh || true

echo "=== PATCH INTERNAL LOGGER CRASH ==="
python3 - <<'PY'
from pathlib import Path
p = Path("judge/views/internal.py")
if p.exists():
    s = p.read_text()
    old = """class RequestTimeMixin(object):
    def get_requests_data(self):
        logger = logging.getLogger(self.log_name)
        log_filename = logger.handlers[0].baseFilename
        requests = []

        with open(log_filename, "r") as f:
            for line in f:
                try:
                    info = json.loads(line)
                    requests.append(info)
                except:
                    continue
        return requests
"""
    new = """class RequestTimeMixin(object):
    def get_requests_data(self):
        logger = logging.getLogger(self.log_name)
        if not logger.handlers:
            return []
        handler = logger.handlers[0]
        if not hasattr(handler, "baseFilename"):
            return []
        log_filename = handler.baseFilename
        requests = []
        try:
            with open(log_filename, "r") as f:
                for line in f:
                    try:
                        info = json.loads(line)
                        requests.append(info)
                    except Exception:
                        continue
        except FileNotFoundError:
            return []
        return requests
"""
    if old in s:
        p.write_text(s.replace(old, new))
        print("patched")
    else:
        print("already patched")
PY

echo "=== BUILD CSS ==="
./make_style.sh > "$APP_DIR/build.log" 2>&1 || tail -80 "$APP_DIR/build.log"

echo "=== MIGRATE ==="
python3 manage.py migrate --noinput

echo "=== STATIC + I18N JS ==="
python3 manage.py collectstatic --noinput || true
python3 manage.py compilemessages || true
python3 manage.py compilejsi18n || true

mkdir -p "$APP_DIR/static/jsi18n/vi" "$APP_DIR/static/jsi18n/en"

FOUND_JS="$(find "$APP_DIR" -path "*jsi18n*" -name "djangojs.js" | head -1 || true)"

if [ -n "$FOUND_JS" ]; then
    cp "$FOUND_JS" "$APP_DIR/static/jsi18n/vi/djangojs.js" || true
fi

if [ ! -f "$APP_DIR/static/jsi18n/vi/djangojs.js" ]; then
cat > "$APP_DIR/static/jsi18n/vi/djangojs.js" <<JS
window.django = window.django || {};
django.catalog = django.catalog || {};
django.gettext = django.gettext || function(msgid){ return msgid; };
django.ngettext = django.ngettext || function(singular, plural, count){ return count == 1 ? singular : plural; };
django.gettext_noop = django.gettext_noop || function(msgid){ return msgid; };
django.pgettext = django.pgettext || function(context, msgid){ return msgid; };
django.npgettext = django.npgettext || function(context, singular, plural, count){ return count == 1 ? singular : plural; };
django.interpolate = django.interpolate || function(fmt, obj, named){ return fmt; };
JS
fi

cp "$APP_DIR/static/jsi18n/vi/djangojs.js" "$APP_DIR/static/jsi18n/en/djangojs.js" || true
python3 manage.py collectstatic --noinput || true

echo "=== LOAD DATA ==="
python3 manage.py loaddata navbar || true
python3 manage.py loaddata language_small || true
python3 manage.py loaddata demo || true

echo "=== CREATE ADMIN ==="
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
print("Admin ready")
PY

echo "=== CLONE JUDGE-SERVER ==="
if [ ! -d "$JUDGE_SERVER_DIR/.git" ]; then
    rm -rf "$JUDGE_SERVER_DIR"
    git clone https://github.com/LQDJudge/judge-server.git "$JUDGE_SERVER_DIR"
fi

cd "$JUDGE_SERVER_DIR"
git pull || true
git submodule update --init --recursive || true

echo "=== BUILD JUDGE IMAGE TIER1 ==="
cd "$JUDGE_SERVER_DIR/.docker"
make judge-tier1 || true

echo "=== REGISTER JUDGE IN SITE ==="
cd "$APP_DIR"
source "$VENV_DIR/bin/activate"
python3 manage.py addjudge "$JUDGE_ID" "$JUDGE_KEY" || true

echo "=== JUDGE CONFIG ==="
mkdir -p "$PROBLEMS_DIR/__conf__"

cat > "$PROBLEMS_DIR/__conf__/general.yml" <<YAML
key: "${JUDGE_KEY}"
problem_storage_globs:
  - /problems/**/
runtime:
  gcc: /usr/bin/gcc
  g++: /usr/bin/g++
  g++11: /usr/bin/g++
  g++14: /usr/bin/g++
  g++17: /usr/bin/g++
  g++20: /usr/bin/g++
  clang: /usr/bin/clang
  clang++: /usr/bin/clang++
  fpc: /usr/bin/fpc
  python3: /usr/bin/python3
  python: /usr/bin/python3
  java: /usr/bin/java
  javac: /usr/bin/javac
  node: /usr/bin/node
  sed: /bin/sed
  awk: /usr/bin/awk
YAML

echo "=== STOP OLD PROCESSES ==="
pkill -f "manage.py runserver" 2>/dev/null || true
pkill -f "manage.py runbridged" 2>/dev/null || true
docker ps -q --filter "name=judge" | xargs -r docker rm -f || true
docker rm -f bridge 2>/dev/null || true

echo "=== START WEB BACKGROUND ==="
cd "$APP_DIR"
nohup "$VENV_DIR/bin/python3" manage.py runserver 0.0.0.0:${PORT} > "$APP_DIR/site.log" 2>&1 &
SITE_PID=$!

echo "=== START BRIDGE ==="
if [ -x "$APP_DIR/.docker/bridge/build.sh" ]; then
    "$APP_DIR/.docker/bridge/build.sh" > "$APP_DIR/bridge-build.log" 2>&1 || tail -80 "$APP_DIR/bridge-build.log"
fi

if [ -x "$APP_DIR/.docker/bridge/run.sh" ]; then
    nohup "$APP_DIR/.docker/bridge/run.sh" > "$APP_DIR/bridge.log" 2>&1 &
else
    nohup "$VENV_DIR/bin/python3" manage.py runbridged > "$APP_DIR/bridge.log" 2>&1 &
fi

sleep 5

echo "=== START DOCKER JUDGE ==="
export PROBLEMS_DIR="$PROBLEMS_DIR"
export JUDGE_SERVER_DIR="$JUDGE_SERVER_DIR"
export JUDGE_IMAGE="$JUDGE_IMAGE"

if [ -x "$APP_DIR/.docker/judge/start_judge.sh" ]; then
    nohup "$APP_DIR/.docker/judge/start_judge.sh" "$JUDGE_ID" > "$APP_DIR/judge-${JUDGE_ID}.log" 2>&1 &
else
    echo "Missing .docker/judge/start_judge.sh" > "$APP_DIR/judge-${JUDGE_ID}.log"
fi

IP="$(hostname -I | awk '{print $1}')"

echo ""
echo "======================================"
echo "LQDOJ FULL ĐÃ CHẠY NGẦM"
echo ""
echo "WEB LOCAL : http://localhost:${PORT}"
echo "WEB LAN   : http://${IP}:${PORT}"
echo ""
echo "ADMIN     : ${ADMIN_USER}"
echo "PASS      : ${ADMIN_PASS}"
echo ""
echo "JUDGE ID  : ${JUDGE_ID}"
echo "JUDGE KEY : ${JUDGE_KEY}"
echo "PROBLEMS  : ${PROBLEMS_DIR}"
echo "CONFIG    : ${PROBLEMS_DIR}/__conf__/general.yml"
echo "IMAGE     : ${JUDGE_IMAGE}"
echo ""
echo "STATUS    : http://localhost:${PORT}/status/"
echo ""
echo "LOGS:"
echo "tail -f ${APP_DIR}/site.log"
echo "tail -f ${APP_DIR}/bridge.log"
echo "tail -f ${APP_DIR}/judge-${JUDGE_ID}.log"
echo ""
echo "Nếu Docker permission denied:"
echo "newgrp docker"
echo "rồi chạy lại script"
echo "======================================"
SH

chmod +x ~/lqdoj.sh
~/lqdoj.sh
