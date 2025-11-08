#!/usr/bin/env bash
set -euo pipefail
Y='\033[1;33m'; G='\033[0;32m'; R='\033[0;31m'; N='\033[0m'

ROOT="$HOME/sms-procurement-manager"
WEB="$ROOT/web/public"
INDEX="$WEB/index.html"
THEME="$WEB/theme.css"
COMPOSE="$ROOT/docker-compose.yml"

echo -e "${Y}🎨 Applying warm, high-contrast theme + checking API endpoints...${N}"

mkdir -p "$WEB"

# 1) Warm theme (accessible contrast)
cat > "$THEME" <<'CSS'
:root{
  --bg-0:#f7efe6;         /* warm paper */
  --bg-1:#fff7ef;         /* cards */
  --bg-2:#fde9d8;         /* subtle accents */
  --text-0:#2b1e12;       /* primary text */
  --text-1:#4b2e16;       /* secondary text */
  --muted:#7c5a3c;

  --primary:#b45309;      /* warm amber/brown */
  --primary-600:#9a4007;
  --primary-700:#7a3306;

  --accent:#d97706;       /* amber */
  --accent-700:#b45309;

  --ok:#16a34a;           /* green: create */
  --ok-700:#15803d;
  --info:#2563eb;         /* blue: search */
  --info-700:#1d4ed8;
  --warn:#f59e0b;         /* yellow: edit */
  --warn-800:#b45309;
  --danger:#dc2626;       /* red: delete */
  --danger-800:#991b1b;

  --border:#e4c9ad;
  --shadow: 0 6px 14px rgba(124, 90, 60, .12);
  --radius: 12px;
}

*{box-sizing:border-box}
html,body{
  margin:0; padding:0; height:100%;
  background:var(--bg-0);
  color:var(--text-0);
  font-family: ui-sans-serif, system-ui, -apple-system, Segoe UI, Roboto, "Helvetica Neue", Arial, "Noto Sans", "Liberation Sans", "Apple Color Emoji","Segoe UI Emoji","Segoe UI Symbol";
  -webkit-font-smoothing: antialiased; -moz-osx-font-smoothing: grayscale;
}
a{ color:var(--accent); }
a:hover{ color:var(--accent-700); }

#app{ padding:16px; }

.header{
  position:sticky; top:0; z-index:30;
  background:linear-gradient(180deg, rgba(253,233,216,.92), rgba(247,239,230,.92));
  backdrop-filter: blur(4px);
  border-bottom:1px solid var(--border);
  color:var(--text-0);
}

.nav{
  display:flex; gap:10px; flex-wrap:wrap; align-items:center;
  padding:10px 16px;
}
.nav .brand{
  font-weight:800; letter-spacing:.2px; margin-right:auto;
}

.page h1{ margin:16px 0 10px; color:var(--text-1); }
h2,h3{ color:var(--text-1); }

.card{
  background:var(--bg-1);
  border:1px solid var(--border);
  border-radius:var(--radius);
  box-shadow:var(--shadow);
  padding:14px;
  margin:12px 0;
}

input,select,textarea{
  background:#fff; color:var(--text-0);
  border:1px solid var(--border);
  border-radius:10px;
  padding:8px 10px;
  outline:none;
}
input:focus,select:focus,textarea:focus{
  border-color:var(--accent);
  box-shadow:0 0 0 3px rgba(217,119,6,.15);
}

table{
  width:100%; border-collapse:separate; border-spacing:0;
  background:#fff; border:1px solid var(--border); border-radius:12px; overflow:hidden;
}
th,td{ padding:10px 12px; text-align:left; border-bottom:1px solid var(--border); }
th{ background:var(--bg-2); color:var(--text-1); }
tbody tr:nth-child(odd){ background:#fff; }
tbody tr:nth-child(even){ background:#fffaf5; }

.btn{
  appearance:none; border:none; cursor:pointer;
  padding:8px 12px; border-radius:999px; font-weight:600;
  transition:filter .15s ease, transform .02s ease;
  color:#fff; background:var(--primary);
  box-shadow:var(--shadow);
}
.btn:hover{ filter:brightness(.98); transform:translateY(-1px); }
.btn:active{ transform:translateY(0); }

.btn.green{ background:var(--ok); }
.btn.green:hover{ background:var(--ok-700); }
.btn.blue{ background:var(--info); }
.btn.blue:hover{ background:var(--info-700); }
.btn.yellow{ background:var(--warn); color:#3b270e; }
.btn.yellow:hover{ background:var(--warn-800); color:#fff; }
.btn.red{ background:var(--danger); }
.btn.red:hover{ background:var(--danger-800); }

.badge{
  display:inline-block; padding:2px 8px; border-radius:999px;
  background:var(--bg-2); color:var(--text-1); border:1px solid var(--border);
}

/* pills used in settings lists */
.pill-list{ list-style:none; padding:0; margin:8px 0; }
.pill-row{ display:flex; align-items:center; gap:8px; margin:6px 0; }
.pill{
  display:inline-block; padding:6px 10px; border-radius:999px;
  background:#fff; border:1px solid var(--border); color:var(--text-0);
}

/* subtle scrollbar */
*::-webkit-scrollbar{ width:10px; height:10px; }
*::-webkit-scrollbar-thumb{ background:var(--border); border-radius:999px; }
*::-webkit-scrollbar-thumb:hover{ background:#d7b693; }
CSS

# 2) Ensure the new theme is linked in index.html (idempotent)
if [[ -f "$INDEX" ]]; then
  if ! grep -q 'href="theme.css"' "$INDEX"; then
    echo -e "${Y}Linking theme.css in index.html...${N}"
    # insert before closing </head> if present, else prepend file
    if grep -q '</head>' "$INDEX"; then
      sed -i 's@</head>@  <link rel="stylesheet" href="theme.css" />\n</head>@' "$INDEX"
    else
      tmp="$(mktemp)"; echo '<link rel="stylesheet" href="theme.css" />' > "$tmp"; cat "$INDEX" >> "$tmp"; mv "$tmp" "$INDEX"
    fi
  fi
else
  echo -e "${R}index.html not found at $INDEX — creating a minimal one.${N}"
  cat > "$INDEX" <<'HTML'
<!doctype html><html><head>
<meta charset="utf-8"/>
<meta name="viewport" content="width=device-width,initial-scale=1"/>
<title>SMS Procurement Manager</title>
<link rel="stylesheet" href="theme.css"/>
</head><body>
  <div class="header"><div class="nav"><div class="brand">SMS Procurement Manager</div></div></div>
  <div id="app" class="page"></div>
  <script src="env.js"></script>
  <script src="main.js"></script>
</body></html>
HTML
fi

# 3) Rebuild just the web image (your stack uses baked files for web)
if [[ -f "$COMPOSE" ]]; then
  echo -e "${Y}🐳 Rebuilding web and restarting...${N}"
  docker compose -f "$COMPOSE" build web
  docker compose -f "$COMPOSE" up -d web
else
  echo -e "${R}docker-compose.yml not found, skipping rebuild. Start it manually if needed.${N}"
fi

# 4) Show current API endpoints to help pinpoint any 404
IP=$(hostname -I | awk '{print $1}')
API_URL="http://${IP}:8010/openapi.json"
echo -e "${Y}🔎 API endpoints (for 404 triage): ${API_URL}${N}"
if curl -sf "$API_URL" >/tmp/spm_openapi.json; then
  echo -e "${G}✔ OpenAPI fetched. Listing paths...${N}"
  # list first 50 paths in a readable way without jq dependency
  grep -oE '"/[^"]+"' /tmp/spm_openapi.json | sed 's/"//g' | sed 's/\\//g' | sort -u | head -n 200
else
  echo -e "${R}✖ Could not fetch openapi.json — check API container logs.${N}"
fi

echo -e "${G}✅ Warm theme applied. If you still see the old colors, hard-refresh the browser (Ctrl/Cmd+Shift+R).${N}"
