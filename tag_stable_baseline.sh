#!/usr/bin/env bash
set -euo pipefail

cd ~/sms-procurement-manager

echo "==> Verifying repository connection..."
git remote -v

echo "==> Checking current branch..."
git branch --show-current || true

echo "==> Staging all pending changes..."
git add -A
git commit -m "Pre-tag sync before baseline-ui-imap-stable [$(date +%F_%H-%M-%S)]" || echo "(no changes to commit)"

TAG="baseline-ui-imap-stable"
echo "==> Creating tag: $TAG"
git tag -f "$TAG"

echo "==> Pushing current branch and tag to origin..."
git push origin HEAD --force
git push origin "$TAG" --force

echo "==> ✅ Tag created and pushed successfully."
echo "You can restore it anytime with:"
echo "   git checkout baseline-ui-imap-stable"
