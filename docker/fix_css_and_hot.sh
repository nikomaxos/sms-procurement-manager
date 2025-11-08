#!/usr/bin/env bash
set -euo pipefail

ROOT="$HOME/sms-procurement-manager"
WEB_PUB="$ROOT/web/public"
API_MAIN="$ROOT/api/app/main.py"
DOCKER_DIR="$ROOT/docker"

mkdir -p "$WEB_PUB"

echo "🎨 Writing minimal web/public/main.css..."
cat > "$WEB_PUB/main.css" <<'CSS'
:root { --bg:#0b0f14; --card:#121821; --border:#253041; --text:#e7edf3; --muted:#9bb0c3; }
* { box-sizing: border-box; }
html,body { height:100%; }
body { margin:40px; background:var(--bg); color:var(--text); font: 16px/1.5 system-ui,-apple-system,Segoe UI,Roboto,Inter,Arial,sans-serif; }
a { color:#7ab3ff; text-decoration:none; }
.card { background:var(--card); border:1px solid var(--border); border-radius:16px; padding:16px; box-shadow:0 1px 10px rgba(0,0,0,.25); }
.toolbar { display:flex; gap:8px; align-items:center; margin:12px 0 16px; }
input,button,select { padding:10px 12px; border-radius:10px; border:1px solid var(--border); background:#0f141c; color:var(--text); }
button { cursor:pointer; }
.badge { background:#1a2332; border:1px solid var(--border); border-radius:999px; padding:4px 10px; font-size:12px; opacity:.9; }
.table { width:100%; border-collapse: collapse; margin-top:8px; }
.table th, .table td { border-bottom:1px solid var(--border); padding:8px 10px; text-align:left; }
.muted { color:var(--muted); }
CSS

# Ensure index.html links the CSS (idempotent)
if ! grep -q 'href="/main.css"' "$WEB_PUB/index.html"; then
  echo "🔗 Injecting <link> to main.css into index.html..."
  awk '
    /<\/head>/ && !done { print "    <link rel=\"stylesheet\" href=\"/main.css\">"; done=1 }
    { print }
  ' "$WEB_PUB/index.html" > "$WEB_PUB/index.html.tmp" && mv "$WEB_PUB/index.html.tmp" "$WEB_PUB/index.html"
else
  echo "ℹ️ index.html already references /main.css"
fi

echo "🧩 Adding minimal /hot/ endpoint to API if missing..."
python3 - <<'PY'
from pathlib import Path
p = Path.home()/ "sms-procurement-manager/api/app/main.py"
s = p.read_text()
if "/hot/" not in s:
    add = r"""

@app.get("/hot/")
def hot(_: bool = Depends(auth_required)):
    # Minimal stub so UI can render the 'What’s Hot' panel without 404s.
    # Return an empty array: the UI should handle and show 'no data' state.
    return []
"""
    # place after existing /offers/ if possible
    if "def list_offers" in s:
        s = s + add
    else:
        s = s + add
    p.write_text(s)
    print("✅ /hot/ endpoint added")
else:
    print("ℹ️ /hot/ already exists")
PY

echo "🔁 Rebuild & restart web+api..."
cd "$DOCKER_DIR"
docker compose build web api
docker compose up -d web api

echo "🩺 Quick checks"
echo "- CSS should be 200:"
curl -s -o /dev/null -w "  GET /main.css -> HTTP %{http_code}\n" http://localhost:5183/main.css
echo "- /hot/ should be 200 []:"
curl -s -i http://localhost:8010/hot/ | sed -n '1,3p'
