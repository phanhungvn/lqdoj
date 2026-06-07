#!/usr/bin/env bash
set -e

APP_DIR="${APP_DIR:-$HOME/online-judge}"
VENV_DIR="${VENV_DIR:-$HOME/dmojsite}"
PORT="${PORT:-8000}"

JUDGE_ID="${JUDGE_ID:-Maycham01}"
JUDGE_KEY="${JUDGE_KEY:-a}"
PROBLEMS_DIR="${PROBLEMS_DIR:-$APP_DIR/problems}"
JUDGE_IMAGE="${JUDGE_IMAGE:-vnoj/judge-tier1:latest}"

echo "========================================================"
echo "      HỆ THỐNG TỰ ĐỘNG BUILD WEB LQDOJ (by pvhung)      "
echo "========================================================"

cd "$APP_DIR"
source "$VENV_DIR/bin/activate"

echo "=== 1) KHÔI PHỤC MÃ NGUỒN GỐC SẠCH ==="
git checkout -- templates/quiz/ 2>/dev/null || true
git checkout -- judge/utils/quiz_grading.py 2>/dev/null || true
git checkout -- judge/views/quiz.py 2>/dev/null || true
git checkout -- judge/views/internal.py 2>/dev/null || true

BACKUP_DIR="$APP_DIR/_backup_lqdoj_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$BACKUP_DIR"
cp -a "$APP_DIR/dmoj/local_settings.py" "$BACKUP_DIR/local_settings.py.bak" 2>/dev/null || true

echo "=== 2) CẤU HÌNH BIẾN MÔI TRƯỜNG TRÁNH CRASH JINJA ==="
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

echo "=== 3) VÁ LỖI KIỂU MẢNG BẰNG METAPROGRAMMING TỐI CAO ==="
python3 - <<'PY'
from pathlib import Path

# --- A. Bảo vệ tầng chấm điểm (quiz_grading.py) ---
qg_file = Path.home() / "online-judge/judge/utils/quiz_grading.py"
if qg_file.exists():
    content = qg_file.read_text(errors="ignore")
    patch = """
# PVHUNG METAPROGRAMMING PATCH
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
        return func(*new_args, **kwargs)
    return wrapper

for name, obj in list(globals().items()):
    if callable(obj) and name.startswith('grade_') and name != '_pvhung_wrap_grader':
        globals()[name] = _pvhung_wrap_grader(obj)
"""
    if "_PvhungSafeList" not in content:
        qg_file.write_text(content + "\n" + patch, encoding="utf-8")
        print("-> [Thành công] Đã tiêm giáp bảo vệ vào module chấm điểm!")

# --- B. Bảo vệ tầng giao tiếp Request/View (views/quiz.py) ---
qv_file = Path.home() / "online-judge/judge/views/quiz.py"
if qv_file.exists():
    content = qv_file.read_text(errors="ignore")
    patch = """
# PVHUNG REQUEST PATCH
class _PvhungSafeList(list):
    def get(self, key, default=None):
        if key in ('choices', 'answer', 'text', 'points'): return self
        return default

# Monkeypatch cho QueryDict của Django (bắt gọn dữ liệu mảng từ form)
import django.http.request
_old_getlist = django.http.request.QueryDict.getlist
def _safe_getlist(self, key, default=None):
    res = _old_getlist(self, key, default)
    return _PvhungSafeList(res) if isinstance(res, list) else res
django.http.request.QueryDict.getlist = _safe_getlist

# Monkeypatch cho json.loads (bắt gọn mảng giải mã từ DB/JSON payload)
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
        print("-> [Thành công] Đã tiêm giáp bảo vệ vào bộ xử lý Request HTTP!")
PY

echo "=== 4) CHUẨN HOÁ FILE INTERNAL.PY ==="
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

echo "=== 5) TIÊM CẤU HÌNH HỆ THỐNG VÀO LOCAL_SETTINGS ==="
LOCAL_SETTINGS="$APP_DIR/dmoj/local_settings.py"
if ! grep -q "LQDOJ FULL HOTFIX" "$LOCAL_SETTINGS"; then
cat >> "$LOCAL_SETTINGS" <<'PY'

# ===== LQDOJ FULL HOTFIX =====
EMAIL_BACKEND = 'django.core.mail.backends.console.EmailBackend'
DEFAULT_FROM_EMAIL = 'no-reply@localhost'
SERVER_EMAIL = 'no-reply@localhost'

CELERY_TASK_ALWAYS_EAGER = True
CELERY_TASK_EAGER_PROPAGATES = True
CELERY_BROKER_URL = 'memory://'
BROKER_URL = 'memory://'
CELERY_RESULT_BACKEND = 'cache+memory://'

BRIDGED_JUDGE_ADDRESS = [('0.0.0.0', 9999)]
BRIDGED_DJANGO_ADDRESS = [('localhost', 9998)]
PY
fi

echo "=== 6) KHỞI CHẠY ĐỒNG BỘ MÔI TRƯỜNG DJANGO 5.X ==="
python3 manage.py check || true
python3 manage.py migrate --noinput || true
python3 manage.py collectstatic --noinput || true
python3 manage.py compilemessages || true
python3 manage.py compilejsi18n || true

echo "=== 7) RESTART CÁC DỊCH VỤ HỆ THỐNG ==="
sudo service mysql start 2>/dev/null || sudo service mariadb start 2>/dev/null || true
sudo service redis-server start 2>/dev/null || true
sudo service memcached start 2>/dev/null || true

echo "=== 8) DỌN DẸP VÀ XÓA HOÀN TOÀN CACHED PYC TREO ==="
pkill -f "manage.py runserver" 2>/dev/null || true
pkill -f "manage.py runbridged" 2>/dev/null || true
docker rm -f "$JUDGE_ID" 2>/dev/null || true
find . -name "*.pyc" -delete 2>/dev/null || true
find . -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
sleep 1

echo "=== 9) KHỞI CHẠY LẠI MÁY CHỦ WEB + TRÌNH CHẤM ==="
nohup "$VENV_DIR/bin/python3" manage.py runserver 0.0.0.0:${PORT} > "$APP_DIR/site.log" 2>&1 &
nohup "$VENV_DIR/bin/python3" manage.py runbridged > "$APP_DIR/bridge.log" 2>&1 &
sleep 2

mkdir -p "$PROBLEMS_DIR"
cat > "$PROBLEMS_DIR/Maycham01.yml" <<YAML
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

python3 manage.py addjudge "$JUDGE_ID" "$JUDGE_KEY" || true

docker run \
  --name "$JUDGE_ID" \
  --network host \
  -v "$PROBLEMS_DIR:/problems" \
  --cap-add SYS_PTRACE \
  -d \
  --restart always \
  "$JUDGE_IMAGE" \
  run \
  -p 9999 \
  -c /problems/Maycham01.yml \
  localhost \
  "$JUDGE_ID" \
  "$JUDGE_KEY"

sleep 2
echo "========================================================"
echo "    HỆ THỐNG TỰ ĐỘNG BUILD WEB LQDOJ (by pvhung) - DONE "
echo "========================================================"
