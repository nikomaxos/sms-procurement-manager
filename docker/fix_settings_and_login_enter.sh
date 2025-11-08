#!/usr/bin/env bash
set -euo pipefail

ROOT="$HOME/sms-procurement-manager"
WEB="$ROOT/web/public"
JS="$WEB/main.js"

test -f "$JS" || { echo "❌ Not found: $JS"; exit 1; }
cp -a "$JS" "$JS.bak.$(date +%s)"

# --- Patch in JS fixes ---
JS_PATH="$JS" python3 - <<'PY'
import os, re, pathlib

p = pathlib.Path(os.environ["JS_PATH"])
s = p.read_text(encoding="utf-8")
changed = False

# 1️⃣ Ensure go() helper exists
if "function go(" not in s:
    go_helper = r"""
function go(fn) {
  try { fn(); }
  catch(e) { console.error(e); alert('Unexpected error: ' + e.message); }
}
""".strip()+"\n"
    # Insert before first function if possible
    s = go_helper + "\n" + s
    changed = True

# 2️⃣ Fix viewSettings() if go() not found in call
s = re.sub(r"\bgo\s*\(", "__ensureSettingsCSS(); (async (", s)
# Or simply ensure it calls async directly without go()
if "function viewSettings()" in s and "go(async" in s:
    # fine, leave it
    pass
elif "function viewSettings()" in s:
    s = re.sub(r"function\s+viewSettings\s*\(\)\s*\{",
               "function viewSettings() {\n  __ensureSettingsCSS(); (async () => {",
               s)
    s = s.replace("app.append(page, saveBtn); updateSave();", 
                  "app.append(page, saveBtn); updateSave(); })();")
    changed = True

# 3️⃣ Add Enter-key login handler
# Find login rendering block and ensure event listener on password field
if "loginInput" not in s or "passwordInput" not in s:
    # skip if login page different structure
    pass
else:
    pattern = r"(passwordInput\s*=\s*input\([^)]+\);)"
    if re.search(pattern, s) and "passwordInput.addEventListener" not in s:
        s = re.sub(pattern,
                   r"\1\n  // Enter key triggers login\n  passwordInput.addEventListener('keydown', e => { if(e.key === 'Enter') loginBtn.click(); });",
                   s)
        changed = True

if changed:
    p.write_text(s, encoding="utf-8")
    print("✅ JS patched: go() helper + Enter-login + viewSettings fix")
else:
    print("ℹ️ No edits needed.")
PY

echo "🔁 Rebuilding web…"
cd "$ROOT/docker"
docker compose up -d --build web

echo "✅ Done — hard-refresh (Ctrl+F5 / Cmd+Shift+R) and test Settings + Enter key login."
