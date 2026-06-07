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

PROBLEMS_DIR="${PROBLEMS_DIR:-$APP_DIR/problems}"
JUDGE_IMAGE="${JUDGE_IMAGE:-vnoj/judge-tier1:latest}"

echo "========================================================"
echo "   HỆ THỐNG TỰ ĐỘNG CÀI ĐẶT & BUILD WEB LQDOJ (A - Z)   "
echo "========================================================"

# --- HỘP THOẠI CHỌN SỐ LƯỢNG MÁY CHẤM SONG SONG ---
echo -n "👉 Nhập số lượng máy chấm bạn muốn khởi chạy (mặc định là 1): "
read NUM_JUDGES

if [[ -z "$NUM_JUDGES" || ! "$NUM_JUDGES" =~ ^[0-9]+$ ]]; then
    NUM_JUDGES=1
fi
echo "🚀 Hệ thống sẽ thiết lập cài đặt và kích hoạt $NUM_JUDGES máy chấm (Mỗi máy 1 Key riêng biệt)!"
echo "--------------------------------------------------------"

fix_apt() {
    sudo dpkg --configure -a || true
    sudo apt --fix-broken install -y || true
    sudo apt autoremove -y || true
}

echo "=== 1) FIX APT & INSTALL PACKAGES ==="
fix_apt
sudo apt update

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
    echo "=== 2) INSTALL DOCKER COMPOSE ==="
    if apt-cache policy docker-compose-plugin 2>/dev/null | grep -q "Candidate: [^(]"; then
        sudo apt install -y docker-compose-plugin || true
    else
        echo "docker-compose-plugin không có trong repo apt hiện tại -> dùng bản standalone."
    fi

    if docker compose version >/dev/null 2>&1; then
        docker compose version || true
        return 0
    fi

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

    sudo mkdir -p /usr/local/lib/docker/cli-plugins
    sudo ln -sf /usr/local/bin/docker-compose /usr/local/lib/docker/cli-plugins/docker-compose

    docker-compose version || true
    docker compose version || true
}
install_docker_compose

sudo systemctl enable --now docker || sudo service docker start || true
sudo usermod -aG docker "$USER" || true

echo "=== 3) INSTALL NODE 18 & COMPILERS ==="
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

echo "=== 4) START SERVICES & CONFIG DATABASE ==="
sudo service mysql start || sudo service mariadb start || true
sudo service redis-server start || true
sudo service memcached start || true

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

echo "=== 5) CLONE ONLINE-JUDGE REPOSITORY ==="
if [ ! -d "$APP_DIR/.git" ]; then
    rm -rf "$APP_DIR"
    git clone https://github.com/LQDJudge/online-judge.git "$APP_DIR"
fi

cd "$APP_DIR"
git pull || true
git submodule update --init --recursive || true

echo "=== 6) SETUP PYTHON VIRTUAL ENVIRONMENT ==="
if [ ! -d "$VENV_DIR" ]; then
    python3 -m venv "$VENV_DIR"
fi

source "$VENV_DIR/bin/activate"
python3 -m pip install --upgrade pip setuptools wheel cython
pip install -r requirements.txt
pip install mysqlclient pymemcache django-redis PyMySQL gunicorn || true

echo "=== 7) CẤU HÌNH BIẾN MÔI TRƯỜNG TRÁNH CRASH JINJA ==="
SITE_PACKAGES="$("$VENV_DIR/bin/python3" - <<'PY'
import site
print(site.getsitepackages()[0])
PY
)"

cat > "$SITE_PACKAGES/sitecustomize.py" <<'PY'
import html

def _to_text(value):
    if value is None: return ""
    if isinstance(value, str): return value
    try:
        txt = object.__getattribute__(value, "text")
        if txt is not None: return str(txt)
    except Exception: pass
    try: return str(value)
    except Exception: return ""

def _safe_html(value):
    return html.escape(_to_text(value)).replace("\n", "<br>\n")

try:
    import markdown
    import markdown.core
    OldMarkdown = markdown.core.Markdown
    old_convert = OldMarkdown.convert
    def safe_convert(self, source):
        s2 = _to_text(source)
        try: return old_convert(self, s2)
        except Exception as e: return _safe_html(s2)
    OldMarkdown.convert = safe_convert
except Exception: pass
PY
find "$SITE_PACKAGES" -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true

echo "=== 8) VÁ LỖI MẢNG & NÂNG CẤP CHẤM ĐIỂM NHIỀU ĐÁP ÁN ĐÚNG ==="
python3 - <<'PY'
from pathlib import Path

# --- A. Bảo vệ tầng chấm điểm (quiz_grading.py) ---
qg_file = Path.home() / "online-judge/judge/utils/quiz_grading.py"
if qg_file.exists():
    content = qg_file.read_text(errors="ignore")
    patch = """
# PVHUNG METAPROGRAMMING PATCH - MULTIPLE ANSWERS SUPPORT
class _PvhungSafeList(list):
    def get(self, key, default=None):
        if key in ('choices', 'answer', 'text', 'points'): return self
        return default

def _pvhung_wrap_grader(func):
    def wrapper(*args, **kwargs):
        new_args = list(args)
        for i in range(len(new_args)):
            if isinstance(new_args[i], list):
                new_args[i] = _PvhungSafeList(new_args[i])
        for k, v in kwargs.items():
            if isinstance(v, list):
                kwargs[k] = _PvhungSafeList(v)
        
        if 'answer' in kwargs and 'user_answer' in kwargs:
            ans = kwargs['answer']
            u_ans = kwargs['user_answer']
            if isinstance(ans, list) and isinstance(u_ans, list):
                if sorted([str(x) for x in ans]) == sorted([str(x) for x in u_ans]):
                    try: return func(*new_args, **kwargs)
                    except Exception: pass
        return func(*new_args, **kwargs)
    return wrapper

for name, obj in list(globals().items()):
    if callable(obj) and name.startswith('grade_') and name != '_pvhung_wrap_grader':
        globals()[name] = _pvhung_wrap_grader(obj)
"""
    if "_PvhungSafeList" not in content:
        qg_file.write_text(content + "\n" + patch, encoding="utf-8")

# --- B. Bảo vệ tầng giao tiếp Request/View (views/quiz.py) ---
qv_file = Path.home() / "online-judge/judge/views/quiz.py"
if qv_file.exists():
    content = qv_file.read_text(errors="ignore")
    patch = """
# PVHUNG REQUEST PATCH - MULTIPLE ANSWERS FORM HANDLING
class _PvhungSafeList(list):
    def get(self, key, default=None):
        if key in ('choices', 'answer', 'text', 'points'): return self
        return default

import django.http.request
_old_getlist = django.http.request.QueryDict.getlist
def _safe_getlist(self, key, default=None):
    res = _old_getlist(self, key, default)
    return _PvhungSafeList(res) if isinstance(res, list) else res
django.http.request.QueryDict.getlist = _safe_getlist

import json
_old_loads = json.loads
def _safe_loads(*args, **kwargs):
    try:
        res = _old_loads(*args, **kwargs)
        return _PvhungSafeList(res) if isinstance(res, list) else res
    except Exception:
        return _old_loads(*args, **kwargs)
json.loads = _safe_loads
"""
    if "_PvhungSafeList" not in content:
        qv_file.write_text(content + "\n" + patch, encoding="utf-8")
PY

echo "=== 9) CHUẨN HOÁ FILE INTERNAL.PY ==="
python3 - <<'PY'
from pathlib import Path
p = Path.home() / "online-judge/judge/views/internal.py"
if p.exists():
    s = p.read_text(errors="ignore")
    start = s.find("class RequestTimeMixin")
    if start != -1:
        end = s.find("\nclass ", start + 1)
        if end == -1: end = len(s)
        block = '''class RequestTimeMixin(object):
    def get_requests_data(self):
        logger = logging.getLogger(self.log_name)
        if not logger.handlers: return []
        handler = logger.handlers[0]
        if not hasattr(handler, "baseFilename"): return []
        log_filename = handler.baseFilename
        requests = []
        try:
            with open(log_filename, "r") as f:
                for line in f:
                    try:
                        info = json.loads(line)
                        requests.append(info)
                    except Exception: continue
        except Exception: return []
        return requests
'''
        s = s[:start] + block + s[end:]
        p.write_text(s)
PY

echo "=== 10) TẠO FILE LOCAL SETTINGS THẦN THÁNH ==="
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

# ===== LQDOJ FULL HOTFIX =====
CELERY_TASK_ALWAYS_EAGER = True
CELERY_TASK_EAGER_PROPAGATES = True
CELERY_BROKER_URL = 'memory://'
BROKER_URL = 'memory://'
CELERY_RESULT_BACKEND = 'cache+memory://'
PY

mkdir -p "$APP_DIR/static" "$APP_DIR/media" "$PROBLEMS_DIR" "$APP_DIR/logs"

echo "=== 11) BUILD CSS & STATIC CONTENT ==="
cd "$APP_DIR"
chmod +x make_style.sh || true
sed -i 's/--silence-deprecation=[^ ]*//g' make_style.sh || true
sed -i 's/--silence-deprecation//g' make_style.sh || true
sed -i 's/python manage.py/python3 manage.py/g' make_style.sh || true

./make_style.sh > "$APP_DIR/build.log" 2>&1 || tail -80 "$APP_DIR/build.log"

python3 manage.py migrate --noinput
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

echo "=== 12) LOAD SYSTEM DATA & SUPERUSER ==="
python3 manage.py loaddata navbar || true
python3 manage.py loaddata language_small || true
python3 manage.py loaddata demo || true

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

echo "=== 13) CLONE & BUILD JUDGE-SERVER IMAGE ==="
if [ ! -d "$JUDGE_SERVER_DIR/.git" ]; then
    rm -rf "$JUDGE_SERVER_DIR"
    git clone https://github.com/LQDJudge/judge-server.git "$JUDGE_SERVER_DIR"
fi

cd "$JUDGE_SERVER_DIR"
git pull || true
git submodule update --init --recursive || true
cd "$JUDGE_SERVER_DIR/.docker"
make judge-tier1 || true

echo "=== 14) DỌN DẸP TIẾN TRÌNH CŨ VÀ DOCKER TREO ==="
pkill -f "manage.py runserver" 2>/dev/null || true
pkill -f "manage.py runbridged" 2>/dev/null || true
docker ps -a --format '{{.Names}}' | grep -E "^Maycham|^judge" | xargs -r docker rm -f 2>/dev/null || true
docker rm -f bridge 2>/dev/null || true
find "$APP_DIR" -name "*.pyc" -delete 2>/dev/null || true
find "$APP_DIR" -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
sleep 1

echo "=== 15) KHỞI CHẠY TIẾN TRÌNH WEB & BRIDGE ==="
cd "$APP_DIR"
nohup "$VENV_DIR/bin/python3" manage.py runserver 0.0.0.0:${PORT} > "$APP_DIR/site.log" 2>&1 &
SITE_PID=$!

nohup "$VENV_DIR/bin/python3" manage.py runbridged > "$APP_DIR/bridge.log" 2>&1 &
BRIDGE_PID=$!

echo "Đang chờ bridge mở cổng 9999..."
for i in $(seq 1 30); do
    if ss -tlnp 2>/dev/null | grep -q ':9999'; then
        echo "Bridge OK: Cổng 9999 đang mở và lắng nghe!"
        break
    fi
    if ! kill -0 "$BRIDGE_PID" 2>/dev/null; then
        echo "Bridge bị lỗi tắt đột ngột. Vui lòng xem log:"
        cat "$APP_DIR/bridge.log" || true
        exit 1
    fi
    sleep 1
done

if ! ss -tlnp 2>/dev/null | grep -q ':9999'; then
    echo "LỖI: Quá thời gian chờ nhưng Bridge chưa mở cổng 9999."
    cat "$APP_DIR/bridge.log" || true
    exit 1
fi

echo "=== 16) TỰ ĐỘNG ĐĂNG KÝ VÀ KHỞI CHẠY CHUỖI MÁY CHẤM PHÂN KEY BIỆT LẬP ==="
export PROBLEMS_DIR="$PROBLEMS_DIR"
export JUDGE_IMAGE="$JUDGE_IMAGE"

mkdir -p "$PROBLEMS_DIR/__conf__"

for ((i=1; i<=NUM_JUDGES; i++))
do
    IDX=$(printf "%02d" $i)
    CURRENT_JUDGE_ID="Maycham${IDX}"
    
    # Tự động tính toán cấp Key tăng dần: a, b, c, d... dựa vào bảng mã ASCII
    if [ $i -le 26 ]; then
        CURRENT_KEY=$(printf "\\$(printf '%03o' $((96 + i)))")
    else
        CURRENT_KEY="key${IDX}"
    fi
    
    echo "⚙️  Đang xử lý: $CURRENT_JUDGE_ID với mã bảo mật Key: '$CURRENT_KEY'..."
    
    # --- VÁ LỖI CHÍ MẠNG 1: Dùng Django Shell cập nhật/tạo mới tránh lỗi trùng lắp DB ---
    "$VENV_DIR/bin/python3" manage.py shell <<PY
from judge.models import Judge
j = Judge.objects.filter(name="${CURRENT_JUDGE_ID}").first()
if j:
    j.auth_key = "${CURRENT_KEY}"
    j.is_active = True
    j.save()
    print("-> [DB] Da cap nhat Key hop le!")
else:
    Judge.objects.create(name="${CURRENT_JUDGE_ID}", auth_key="${CURRENT_KEY}", is_active=True)
    print("-> [DB] Da tao moi may cham!")
PY

    # Tạo cấu hình .yml biệt lập cho từng máy
    cat > "$PROBLEMS_DIR/__conf__/${CURRENT_JUDGE_ID}.yml" <<YAML
key: "${CURRENT_KEY}"
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

    # Dọn dẹp container trùng tên trước khi chạy
    docker rm -f "$CURRENT_JUDGE_ID" 2>/dev/null || true

    # --- VÁ LỖI CHÍ MẠNG 2: Song Giáp Mount (Vừa truyền biến cấu hình vào lệnh run, vừa mount đè general.yml của Container) ---
    docker run \
      --name "$CURRENT_JUDGE_ID" \
      --network host \
      -v "$PROBLEMS_DIR:/problems" \
      -v "$PROBLEMS_DIR/__conf__/${CURRENT_JUDGE_ID}.yml:/problems/__conf__/general.yml" \
      --cap-add SYS_PTRACE \
      -d \
      --restart always \
      "$JUDGE_IMAGE" \
      run \
      -p 9999 \
      -c "/problems/__conf__/${CURRENT_JUDGE_ID}.yml" \
      localhost \
      "$CURRENT_JUDGE_ID" \
      "$CURRENT_KEY"
      
    echo "✅ Máy chấm $CURRENT_JUDGE_ID khởi chạy thành công!"
done

IP="$(hostname -I | awk '{print $1}')"

echo ""
echo "========================================================"
echo "      HỆ THỐNG LQDOJ ĐÃ SETUP TOÀN DIỆN VÀ CHẠY NGẦM    "
echo "========================================================"
echo "WEB LOCAL : http://localhost:${PORT}"
echo "WEB LAN   : http://${IP}:${PORT}"
echo ""
echo "ADMIN     : ${ADMIN_USER}"
echo "PASS      : ${ADMIN_PASS}"
echo ""
echo "SỐ LƯỢNG MÁY CHẤM HOẠT ĐỘNG: $NUM_JUDGES máy (Tách Key biệt lập tăng dần a, b, c, d...)"
echo "PROBLEMS  : ${PROBLEMS_DIR}"
echo "THƯ MỤC CONFIG ĐỘNG : ${PROBLEMS_DIR}/__conf__/"
echo ""
echo "XEM TRẠNG THÁI MÁY CHẤM ONLINE: http://localhost:${PORT}/status/"
echo "========================================================"
