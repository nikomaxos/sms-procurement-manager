#!/usr/bin/env bash
set -euo pipefail

ROOT="$HOME/sms-procurement-manager"
WEB="$ROOT/web/public"
JS="$WEB/main.js"

test -f "$JS" || { echo "❌ Not found: $JS"; exit 1; }

# Backup once per run
cp -a "$JS" "$JS.bak.$(date +%s)"

# Pass JS path via env var to Python (no quoting issues)
JS="$JS" python3 - <<'PY'
import os, re, pathlib

path = pathlib.Path(os.environ["JS"])
src  = path.read_text(encoding="utf-8")

# --- robustly replace function viewSettings() {...} using brace matching ---
start = src.find("function viewSettings(")
if start == -1:
    print("⚠️ viewSettings() not found; no changes applied.")
    raise SystemExit(0)

brace_start = src.find("{", start)
if brace_start == -1:
    print("⚠️ Could not locate opening brace for viewSettings().")
    raise SystemExit(1)

# Walk to matching closing brace
depth = 0
i = brace_start
while i < len(src):
    c = src[i]
    if c == "{":
        depth += 1
    elif c == "}":
        depth -= 1
        if depth == 0:
            func_end = i + 1
            break
    i += 1
else:
    print("⚠️ Could not find end of viewSettings() block.")
    raise SystemExit(1)

new_func = r"""
function viewSettings() {
  go(async () => {
    // Fetch enums
    const enums = await authFetch(API_BASE + '/conf/enums', { method: 'GET' });

    // Local state for edit
    const state = JSON.parse(JSON.stringify(enums || {
      route_type: ["Direct","SS7","SIM","Local Bypass"],
      known_hops: ["0-Hop","1-Hop","2-Hops","N-Hops"],
      registration_required: ["Yes","No"]
    }));

    let dirty = false;

    const app  = $('#app');
    app.innerHTML = '';
    const page = el('div', { class: 'page' });
    page.append(el('h1', null, 'Settings'));

    // ---- Drop Down Menus (category frame) ----
    const card = el('div', { class: 'card' });
    card.append(el('h2', null, 'Drop Down Menus'));

    function renderList(key, label) {
      const block = el('div', { class: 'fieldset' });
      block.append(el('label', { class: 'lbl' }, label));

      const ul = el('ul', { class: 'pill-list' });
      (state[key] || []).forEach((v, idx) => {
        const li = el('li', { class: 'pill-row' },
          el('span', { class: 'pill' }, v),
          btn('Edit', 'yellow', () => {
            const nv = prompt('Edit value', v);
            if (nv && nv.trim() && nv !== v) {
              state[key][idx] = nv.trim();
              dirty = true; updateSave(); rerender();
            }
          }),
          btn('Delete', 'red', () => {
            state[key].splice(idx, 1);
            dirty = true; updateSave(); rerender();
          })
        );
        ul.append(li);
      });

      const addRow = el('div', { class: 'row' });
      const inp = input({ placeholder: 'Add new…', id: `add-${key}` });
      const addBtn = btn('Add', 'green', () => {
        const nv = (inp.value || '').trim();
        if (!nv) return;
        state[key] = state[key] || [];
        if (!state[key].includes(nv)) state[key].push(nv);
        inp.value = '';
        dirty = true; updateSave(); rerender();
      });
      addRow.append(inp, addBtn);

      block.append(ul, addRow);
      return block;
    }

    // Build grouped frame
    let listsWrap = el('div', { class: 'lists-wrap' },
      renderList('route_type', 'Route Type'),
      renderList('known_hops', 'Known Hops'),
      renderList('registration_required', 'Registration Required')
    );
    card.append(listsWrap);
    page.append(card);

    const saveBtn = btn('Save All', 'green', async () => {
      await authFetch(API_BASE + '/conf/enums', {
        method: 'PUT',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(state)
      });
      dirty = false; updateSave();
      toast('Saved.');
    });
    saveBtn.id = 'save-all';
    saveBtn.style.marginTop = '12px';

    function updateSave() {
      saveBtn.style.display = dirty ? '' : 'none';
      window.onbeforeunload = dirty ? (() => 'Unsaved changes') : null;
    }

    function rerender() {
      const newWrap = el('div', { class: 'lists-wrap' },
        renderList('route_type', 'Route Type'),
        renderList('known_hops', 'Known Hops'),
        renderList('registration_required', 'Registration Required')
      );
      listsWrap.replaceWith(newWrap);
      listsWrap = newWrap; // update local ref
    }

    app.append(page, saveBtn);
    updateSave();
  });
}
""".lstrip("\n")

# Replace function
new_src = src[:start] + new_func + src[func_end:]

# Append CSS once
if "/* SETTINGS-GROUP CSS */" not in new_src:
    new_src += """

/* SETTINGS-GROUP CSS */
.pill-list { list-style: none; padding: 0; margin: 8px 0; }
.pill-row { display: flex; align-items: center; gap: 8px; margin: 4px 0; }
.pill { display: inline-block; padding: 4px 8px; border-radius: 999px; background: #eee; }
.fieldset { margin: 12px 0; }
.fieldset .lbl { display: block; font-weight: 600; margin-bottom: 6px; }
.card { border: 1px solid #ddd; border-radius: 10px; padding: 14px; margin-top: 8px; background: #fff; }
.lists-wrap { display: grid; grid-template-columns: repeat(auto-fit, minmax(260px, 1fr)); gap: 16px; }
"""

path.write_text(new_src, encoding="utf-8")
print("✅ Settings UI updated: grouped 'Drop Down Menus'")
PY

echo "🔁 Rebuilding web (static)..."
cd "$ROOT/docker"
docker compose up -d --build web

echo "✅ Done. Hard refresh the browser (Ctrl+F5 / Cmd+Shift+R)."
