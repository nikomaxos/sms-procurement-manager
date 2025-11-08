#!/usr/bin/env bash
set -euo pipefail

ROOT="$HOME/sms-procurement-manager"
WEB="$ROOT/web/public"
JS="$WEB/main.js"

test -f "$JS" || { echo "❌ Not found: $JS"; exit 1; }
cp -a "$JS" "$JS.bak.$(date +%s)"

JS_PATH="$JS" python3 - <<'PY'
import os, pathlib, re
p = pathlib.Path(os.environ["JS_PATH"])
src = p.read_text(encoding="utf-8")

# --- Step 1: remove broken injected characters at the top ---
src = re.sub(r"^[^a-zA-Z{]*(function|const|let|var)", r"\1", src, 1)

# --- Step 2: ensure global go() helper exists and is valid ---
if "function go(" not in src:
    go_func = """
function go(fn) {
  try { fn(); }
  catch(e) { console.error(e); alert('Unexpected error: ' + e.message); }
}
""".strip()+"\n\n"
    src = go_func + src

# --- Step 3: ensure Enter-key login works safely ---
if "passwordInput" in src and "loginBtn" in src:
    pat = r"(passwordInput\s*=\s*input\([^)]+\);)"
    if re.search(pat, src) and "keydown" not in src:
        src = re.sub(pat,
                     r"\\1\n  passwordInput.addEventListener('keydown', e => { if (e.key === 'Enter') loginBtn.click(); });",
                     src)

# --- Step 4: ensure CSS helper exists ---
if "function __ensureSettingsCSS()" not in src:
    css_func = """
function __ensureSettingsCSS() {
  if (document.getElementById('settings-group-css')) return;
  const style = document.createElement('style');
  style.id = 'settings-group-css';
  style.textContent = `
.card { border: 1px solid #ddd; border-radius: 10px; padding: 14px; margin: 10px 0; background: #fff; }
.fieldset { margin: 12px 0; }
.fieldset .lbl { display: block; font-weight: 600; margin-bottom: 6px; }
.pill-list { list-style: none; padding: 0; margin: 8px 0; }
.pill-row { display: flex; align-items: center; gap: 8px; margin: 4px 0; }
.pill { display: inline-block; padding: 4px 8px; border-radius: 999px; background: #eee; }
`;
  document.head.appendChild(style);
}
""".strip()+"\n\n"
    src = css_func + src

# --- Step 5: clean double semicolons or unmatched parentheses ---
src = re.sub(r";{2,}", ";", src)
src = re.sub(r"\)\)\);", "));", src)

p.write_text(src, encoding="utf-8")
print("✅ main.js repaired and sanitized.")
PY

echo "🔁 Rebuilding web container..."
cd "$ROOT/docker"
docker compose up -d --build web

echo "✅ Done — hard refresh your browser (Ctrl+F5 / Cmd+Shift+R)."
