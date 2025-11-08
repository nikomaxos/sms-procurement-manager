#!/usr/bin/env bash
set -euo pipefail
Y='\033[1;33m'; G='\033[0;32m'; R='\033[0;31m'; N='\033[0m'
ROOT="$HOME/sms-procurement-manager"
API_DIR="$ROOT/api/app"
CORE_DIR="$API_DIR/core"
DB_PY="$CORE_DIR/database.py"
COMPOSE="$ROOT/docker-compose.yml"

echo -e "${Y}• Backing up & patching get_db in app.core.database …${N}"
mkdir -p "$ROOT/.backups"
cp -a "$DB_PY" "$ROOT/.backups/database.py.$(date +%F_%H-%M-%S).bak" 2>/dev/null || true

python3 - <<'PY'
import sys, re, os, pathlib
p = pathlib.Path(os.environ.get("DB_PY",""))
if not p.exists():
    print("FATAL: database.py not found:", p, file=sys.stderr); sys.exit(1)
s = p.read_text(encoding="utf-8")
changed = False

# Normalize driver scheme for SQLAlchemy 2.x psycopg
s2 = re.sub(r"postgresql://", "postgresql+psycopg://", s)
if s2 != s:
    s = s2; changed = True

# Add get_db() generator if missing
if not re.search(r"\ndef\s+get_db\s*\(", s):
    func = (
        "\n\ndef get_db():\n"
        "    db = SessionLocal()\n"
        "    try:\n"
        "        yield db\n"
        "    finally:\n"
        "        db.close()\n"
    )
    m = re.search(r"SessionLocal\s*=\s*sessionmaker[^\n]*\n", s)
    if m:  # insert right after SessionLocal
        s = s[:m.end()] + func + s[m.end():]
    else:  # append at end as a fallback
        s += func
    changed = True

if changed:
    p.write_text(s, encoding="utf-8")
    print("OK: database.py patched (driver/get_db)")
else:
    print("OK: database.py already correct")
PY
