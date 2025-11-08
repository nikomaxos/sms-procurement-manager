#!/usr/bin/env bash
set -euo pipefail

ROOT="$HOME/sms-procurement-manager"
WEB="$ROOT/web/public"
JS="$WEB/main.js"

test -f "$JS" || { echo "❌ Not found: $JS"; exit 1; }

# Backup once
cp -a "$JS" "$JS.bak.$(date +%s)"

# Run python with path passed through environment variable
JS_PATH="$JS" python3 - <<'PY'
import os, re, pathlib

p = pathlib.Path(os.environ["JS_PATH"])
src = p.read_text(encoding="utf-8")
changed = False

# --- Remove broken CSS tail ---
marker = "/* SETTINGS-GROUP CSS */"
if marker in src:
    src = src[:src.index(marker)]
    changed = True

# --- CSS injector helper ---
helper = r"""
function __ensureSettingsCSS() {
  if (document.getElementById('settings-group-css')) return;
  const style = document.createElement('style');
  style.id = 'settings-group-css';
  style.textContent = `
.pill-list { list-style: none; padding: 0; margin: 8px 0; }
.pill-row { display: flex; align-items: center; gap: 8px; margin: 4px 0; }
.pill { display: inline-block; padding: 4px 8px; border-radius: 999px; background: #eee; }
.fieldset { margin: 12px 0; }
.fieldset .lbl { display: block; font-weight: 600; margin-bottom: 6px; }
.card { border: 1px solid #ddd; border-radius: 10px; padding: 14px; margin-top: 8px; background: #fff; }
.lists-wrap { display: grid; grid-template-columns: repeat(auto-fit, minmax(260px, 1fr)); gap: 16px; }
`;
  document.head.appendChild(style);
}
""".strip()+"\n"

if "function __ensureSettingsCSS()" not in src:
    src = src.rstrip() + "\n\n" + helper
    changed = True

# --- Ensure helper call early in all go(async () => { ... }) blocks ---
if "__ensureSettingsCSS();" not in src:
    src = src.replace("go(async () => {", "go(async () => { __ensureSettingsCSS();")
    changed = True

if changed:
    p.write_text(src, encoding="utf-8")
    print("✅ main.js fixed and CSS injected correctly.")
else:
    print("ℹ️ No changes were required.")
PY

echo "🔁 Rebuilding web (static)…"
cd "$ROOT/docker"
docker compose up -d --build web

echo "✅ Done — now hard-refresh your browser (Ctrl+F5 or Cmd+Shift+R)."
