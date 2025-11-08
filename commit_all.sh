#!/usr/bin/env bash
set -euo pipefail

cd ~/sms-procurement-manager

# Show current status for visibility
echo "==> Current branch:"
git rev-parse --abbrev-ref HEAD || true

echo "==> Staging all changes..."
git add -A

echo "==> Creating commit..."
git commit -m "Full working baseline snapshot — IMAP & UI stable [$(date +%F_%H-%M-%S)]" || echo "(no changes to commit)"

echo "==> Pushing to origin..."
git push origin HEAD

echo "==> Done. All files safely pushed to your repo."
