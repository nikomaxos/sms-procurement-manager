#!/usr/bin/env bash
set -euo pipefail
Y='\033[1;33m'; G='\033[0;32m'; R='\033[0;31m'; N='\033[0m'

ROOT="$HOME/sms-procurement-manager"
API_DIR="$ROOT/api/app"
CORE_DIR="$API_DIR/core"
DB_FILE="$CORE_DIR/database.py"
COMPOSE="$ROOT/docker-compose.yml"

echo -e "${Y}• Locating database.py…${N}"
if [[ ! -f "$DB_FILE" ]]; then
  # Try to discover it if layout shifted
  CAND=$(find "$ROOT" -type f -path '*/api/app/*' -name database.py | head -n1 || true)
  if [[ -n "${CAND:-}" && -f "$CAND" ]]; then
    DB_FILE="$CAND"
  else
    echo -e "${R}✖ Could not find database.py under $ROOT/api/app${N}"
    exit 1
  fi
fi
echo -e "${G}✔ Using: $DB_FILE${N}"

# Backup
TS="$(date +%F_%H-%M-%S)"
BAK="$ROOT/.backups"
mkdir -p "$BAK"
cp -a "$DB_FILE" "$BAK/database.py.$TS.bak" || true
echo -e "${G}✔ Backup: $BAK/database.py.$TS.bak${N}"

echo -e "${Y}• Patching driver scheme and adding get_db() (idempotent)…${N}"
DB_PATH="$DB_FILE" python3 - <<'PY'
import os, re, sys, pathlib
p = pathlib.Path(os.environ["DB_PATH"])
s = p.read_text(encoding="utf-8")
changed = False

# 1) Ensure psycopg driver scheme (postgresql+psycopg://)
s2 = re.sub(r"postgresql://", "postgresql+psycopg://", s)
if s2 != s:
    s = s2; changed = True

# 2) Ensure imports exist (best-effort, idempotent)
need = []
if "from sqlalchemy.orm import sessionmaker" not in s:
    need.append("from sqlalchemy.orm import sessionmaker")
if "from sqlalchemy.orm import declarative_base" not in s and "declarative_base" in s:
    need.append("from sqlalchemy.orm import declarative_base")
if need:
    # prepend after first import block
    m = re.search(r"^(?:from|import).*$", s, flags=re.M)
    if m:
        insert_at = m.end()
        s = s[:insert_at] + "\n" + "\n".join(need) + s[insert_at:]
        changed = True

# 3) Ensure SessionLocal exists (do not clobber if already there)
if "SessionLocal =" not in s:
    # Try to place after engine definition
    m = re.search(r"engine\s*=\s*create_engine\([^\n]*\)\s*", s)
    sess = "\nSessionLocal = sessionmaker(bind=engine, autocommit=False, autoflush=False)\n"
    if m:
        s = s[:m.end()] + sess + s[m.end():]
    else:
        s += sess
    changed = True

# 4) Ensure get_db() generator exists
if not re.search(r"\ndef\s+get_db\s*\(", s):
    func = (
        "\n\ndef get_db():\n"
        "    db = SessionLocal()\n"
        "    try:\n"
        "        yield db\n"
        "    finally:\n"
        "        db.close()\n"
    )
    # Place right after SessionLocal if possible
    m = re.search(r"SessionLocal\s*=\s*sessionmaker[^\n]*\n", s)
    if m:
        s = s[:m.end()] + func + s[m.end():]
    else:
        s += func
    changed = True

if changed:
    p.write_text(s, encoding="utf-8")
    print("OK: database.py patched")
else:
    print("OK: database.py already correct")
PY

echo -e "${Y}• Rebuilding API…${N}"
docker compose -f "$COMPOSE" build api

echo -e "${Y}• Starting API…${N}"
docker compose -f "$COMPOSE" up -d api

# brief wait for uvicorn to import modules
sleep 3

echo -e "${Y}• In-container import self-test…${N}"
set +e
docker compose -f "$COMPOSE" exec -T api python - <<'PY'
try:
    from app.core.database import get_db, SessionLocal, engine
    print("import_ok", callable(get_db), "SessionLocal_ok", SessionLocal is not None, "engine_ok", engine is not None)
except Exception as e:
    import traceback; traceback.print_exc()
PY
RC=$?
set -e

echo -e "${Y}• Tail API logs (last 80 lines)…${N}"
docker compose -f "$COMPOSE" logs api --tail=80

if [[ "$RC" -ne 0 ]]; then
  echo -e "${R}✖ Self-test had errors (see traceback above).${N}"
  exit "$RC"
fi
echo -e "${G}✔ Done. If any other router complains, paste its error and we’ll patch next.${N}"
