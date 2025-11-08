#!/usr/bin/env bash
set -euo pipefail
ROOT="$HOME/sms-procurement-manager"
PUB="$ROOT/web/public"
INDEX="$PUB/index.html"

if [ ! -f "$INDEX" ]; then
  echo "❌ $INDEX not found"; exit 1
fi

# Replace any hardcoded window.__API_BASE__ with a dynamic block:
#   http(s)://<current-host>:8010
tmp="$(mktemp)"
awk '
  BEGIN { replaced=0 }
  /window.__API_BASE__/ && !replaced {
    print "<script>";
    print "  (function(){";
    print "    var proto = location.protocol;";
    print "    var host  = location.hostname;";        # e.g. 192.168.50.102
    print "    var api   = proto + \"//\" + host + \":8010\";";
    print "    window.__API_BASE__ = api;";
    print "  })();";
    print "</script>";
    replaced=1; next
  }
  { print }
' "$INDEX" > "$tmp" && mv "$tmp" "$INDEX"

echo "✅ Patched $INDEX to use dynamic API base (http(s)://<host>:8010)"

cd "$HOME/sms-procurement-manager/docker"
docker compose build web
docker compose up -d web
echo "🔁 Web rebuilt. Hard refresh the browser (Ctrl+Shift+R) and try login again."
