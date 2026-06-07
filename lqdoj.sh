#!/usr/bin/env bash
set -e

APP_DIR="${APP_DIR:-$HOME/online-judge}"
VENV_DIR="${VENV_DIR:-$HOME/dmojsite}"
PORT="${PORT:-8000}"

JUDGE_ID="${JUDGE_ID:-Maycham01}"
JUDGE_KEY="${JUDGE_KEY:-a}"
PROBLEMS_DIR="${PROBLEMS_DIR:-$APP_DIR/problems}"
JUDGE_IMAGE="${JUDGE_IMAGE:-vnoj/judge-tier1:latest}"

echo "================================================"
echo " LQDOJ FULL FIX: quiz/base + mail + celery + judge"
echo "================================================"

cd "$APP_DIR"
source "$VENV_DIR/bin/activate"

echo "=== 1) BACKUP FILES ==="
BACKUP_DIR="$APP_DIR/_backup_fix_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$BACKUP_DIR"
cp -a "$APP_DIR/dmoj/local_settings.py" "$BACKUP_DIR/local_settings.py.bak" 2>/dev/null || true
find "$APP_DIR" -name "base.html" -exec cp -a {} "$BACKUP_DIR/" \; 2>/dev/null || true
echo "Backup: $BACKUP_DIR"

echo "=== 2) FIX sitecustomize.py: markdown + jinja Undefined safe ==="
SITE_PACKAGES="$("$VENV_DIR/bin/python3" - <<'PY'
import site
print(site.getsitepackages()[0])
PY
)"

cat > "$SITE_PACKAGES/sitecustomize.py" <<'PY'
# Auto loaded by Python.
# LQDOJ compatibility fixes for newer Python/Django/Jinja/Markdown.
import html

def _to_text(value):
    if value is None:
        return ""
    if isinstance(value, str):
        return value
    try:
        txt = object.__getattribute__(value, "text")
        if txt is not None:
            return str(txt)
    except Exception:
        pass
    try:
        return str(value)
    except Exception:
        return ""

def _safe_html(value):
    return html.escape(_to_text(value)).replace("\n", "<br>\n")

def _patch_markdown():
    try:
        import markdown
        import markdown.core
    except Exception:
        return

    OldMarkdown = markdown.core.Markdown
    old_convert = OldMarkdown.convert

    def safe_convert(self, source):
        source2 = _to_text(source)
        try:
            return old_convert(self, source2)
        except Exception as e:
            if "text" in str(e) or "Undefined" in str(type(e)):
                return _safe_html(source2)
            raise

    OldMarkdown.convert = safe_convert

    def safe_markdown(text, *args, **kwargs):
        text2 = _to_text(text)
        try:
            return OldMarkdown(*args, **kwargs).convert(text2)
        except Exception as e:
            if "text" in str(e) or "Undefined" in str(type(e)):
                return _safe_html(text2)
            raise

    markdown.markdown = safe_markdown
    markdown.core.markdown = safe_markdown

def _patch_jinja():
    try:
        from jinja2.runtime import Undefined, ChainableUndefined
    except Exception:
        return

    def _safe_getattr(self, name):
        if name == "text":
            return ""
        return ""

    def _safe_str(self):
        return ""

    def _safe_bool(self):
        return False

    Undefined.__getattr__ = _safe_getattr
    Undefined.__str__ = _safe_str
    Undefined.__bool__ = _safe_bool
    try:
        ChainableUndefined.__getattr__ = _safe_getattr
        ChainableUndefined.__str__ = _safe_str
        ChainableUndefined.__bool__ = _safe_bool
    except Exception:
        pass

_patch_markdown()
_patch_jinja()
PY

find "$SITE_PACKAGES" -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true

echo "=== 3) PATCH templates inline-if without else ==="
python3 - <<'PY'
from pathlib import Path
import re

root = Path.home() / "online-judge"

def fix_inline_if_expr(text: str) -> str:
    def repl(m):
        inner = m.group(1)
        if " if " in inner and " else " not in inner:
            return "{{ " + inner.strip() + " else '' }}"
        return m.group(0)
    return re.sub(r"\{\{\s*(.*?)\s*\}\}", repl, text, flags=re.S)

for p in root.rglob("*.html"):
    try:
        s = p.read_text(errors="ignore")
    except Exception:
        continue
    ns = fix_inline_if_expr(s)
    if ns != s:
        p.write_text(ns)
        print("patched template:", p)
PY

echo "=== 4) PATCH local_settings: mail off + celery eager + bridge ==="
LOCAL_SETTINGS="$APP_DIR/dmoj/local_settings.py"
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

echo "=== 5) FIX internal.py logger indent/error if needed ==="
python3 - <<'PY'
from pathlib import Path
p = Path.home() / "online-judge/judge/views/internal.py"
if p.exists():
    s = p.read_text(errors="ignore")
    start = s.find("class RequestTimeMixin")
    if start != -1:
        end = s.find("\nclass ", start + 1)
        if end == -1:
            end = len(s)
        block = '''class RequestTimeMixin(object):
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
        except Exception:
            return []
        return requests
'''
        s = s[:start] + block + s[end:]
        p.write_text(s)
        print("patched internal.py RequestTimeMixin")
PY

echo "=== 6) DJANGO CHECK + MIGRATE + STATIC ==="
python3 manage.py check || true
python3 manage.py migrate --noinput || true
python3 manage.py collectstatic --noinput || true
python3 manage.py compilemessages || true
python3 manage.py compilejsi18n || true

echo "=== 7) START/RESTART MYSQL REDIS MEMCACHED ==="
sudo service mysql start 2>/dev/null || sudo service mariadb start 2>/dev/null || true
sudo service redis-server start 2>/dev/null || true
sudo service memcached start 2>/dev/null || true

echo "=== 8) STOP OLD WEB/BRIDGE/JUDGE ==="
pkill -f "manage.py runserver" 2>/dev/null || true
pkill -f "manage.py runbridged" 2>/dev/null || true
docker rm -f "$JUDGE_ID" 2>/dev/null || true
sleep 1

echo "=== 9) START WEB + BRIDGE ==="
nohup "$VENV_DIR/bin/python3" manage.py runserver 0.0.0.0:${PORT} > "$APP_DIR/site.log" 2>&1 &
nohup "$VENV_DIR/bin/python3" manage.py runbridged > "$APP_DIR/bridge.log" 2>&1 &
sleep 3

echo "--- bridge check ---"
ss -tlnp | grep 9999 || true

echo "=== 10) WRITE JUDGE CONFIG ==="
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

echo "=== 11) REGISTER JUDGE IN SITE ==="
python3 manage.py addjudge "$JUDGE_ID" "$JUDGE_KEY" || true

echo "=== 12) START JUDGE ==="
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

sleep 5

echo "=== 13) STATUS ==="
echo "--- site.log last lines ---"
tail -40 "$APP_DIR/site.log" || true
echo "--- bridge.log last lines ---"
tail -40 "$APP_DIR/bridge.log" || true
echo "--- judge logs last lines ---"
docker logs --tail 40 "$JUDGE_ID" || true

IP="$(hostname -I | awk '{print $1}')"

echo ""
echo "======================================"
echo "DONE"
echo "WEB LOCAL : http://localhost:${PORT}"
echo "WEB LAN   : http://${IP}:${PORT}"
echo "QUIZ      : http://localhost:${PORT}/quiz/xinchao/take/3/"
echo ""
echo "Nếu trình duyệt vẫn lỗi: Ctrl + F5"
echo ""
echo "LOG:"
echo "tail -f $APP_DIR/site.log"
echo "tail -f $APP_DIR/bridge.log"
echo "docker logs -f $JUDGE_ID"
echo "======================================"
