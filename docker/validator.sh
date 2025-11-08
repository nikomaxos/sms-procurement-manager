#!/usr/bin/env bash
set -euo pipefail
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
ROOT="$HOME/sms-procurement-manager"
DOCKER_COMPOSE="$ROOT/docker-compose.yml"

echo -e "${YELLOW}🔍 Starting full syntax validation for SMS Procurement Manager...${NC}"
fail=0

# --------------------------------------------------------
# 1️⃣ Bash syntax validation
# --------------------------------------------------------
echo -e "\n${YELLOW}🧩 Checking Bash scripts...${NC}"
find "$ROOT" -type f -name "*.sh" ! -name "validator.sh" | while read -r f; do
  if bash -n "$f" 2>/dev/null; then
    echo -e "  ${GREEN}✔ Bash OK:${NC} $f"
  else
    echo -e "  ${RED}✖ Bash syntax error:${NC} $f"
    bash -n "$f" || true
    fail=1
  fi
done

# --------------------------------------------------------
# 2️⃣ Python syntax validation
# --------------------------------------------------------
echo -e "\n${YELLOW}🐍 Checking Python modules...${NC}"
find "$ROOT/api/app" -type f -name "*.py" | while read -r f; do
  if python3 -m py_compile "$f" 2>/dev/null; then
    echo -e "  ${GREEN}✔ Python OK:${NC} $f"
  else
    echo -e "  ${RED}✖ Python syntax error:${NC} $f"
    python3 -m py_compile "$f" || true
    fail=1
  fi
done

# --------------------------------------------------------
# 3️⃣ JavaScript syntax validation
# --------------------------------------------------------
echo -e "\n${YELLOW}🪄 Checking JavaScript frontend...${NC}"
find "$ROOT/web/public" -type f -name "*.js" | while read -r f; do
  if command -v node >/dev/null 2>&1; then
    if node --check "$f" >/dev/null 2>&1; then
      echo -e "  ${GREEN}✔ JS OK:${NC} $f"
    else
      echo -e "  ${RED}✖ JS syntax error:${NC} $f"
      node --check "$f" || true
      fail=1
    fi
  else
    echo -e "  ${YELLOW}⚠ Node.js not installed, skipping JS check${NC}"
    break
  fi
done

# --------------------------------------------------------
# 4️⃣ Docker Compose validation
# --------------------------------------------------------
echo -e "\n${YELLOW}🐳 Checking Docker Compose YAMLs...${NC}"
if command -v docker compose >/dev/null 2>&1; then
  if docker compose -f "$DOCKER_COMPOSE" config -q >/dev/null 2>&1; then
    echo -e "  ${GREEN}✔ Docker Compose YAML OK${NC}"
  else
    echo -e "  ${RED}✖ Docker Compose YAML invalid${NC}"
    docker compose -f "$DOCKER_COMPOSE" config || true
    fail=1
  fi
else
  echo -e "  ${YELLOW}⚠ docker compose not installed, skipping${NC}"
fi

# --------------------------------------------------------
# 5️⃣ SQL sanity (BEGIN/END)
# --------------------------------------------------------
echo -e "\n${YELLOW}🧾 Checking inline SQL BEGIN/END balance...${NC}"
if grep -R "BEGIN" "$ROOT/api/app" | grep -q -v "END"; then
  echo -e "  ${RED}✖ Unmatched BEGIN found in SQL${NC}"
  grep -R "BEGIN" "$ROOT/api/app" | grep -v "END" || true
  fail=1
else
  echo -e "  ${GREEN}✔ SQL syntax appears consistent${NC}"
fi

# --------------------------------------------------------
# 6️⃣ Summary before rebuild
# --------------------------------------------------------
if [[ $fail -ne 0 ]]; then
  echo -e "\n${RED}❌ Syntax validation failed. Rebuild aborted.${NC}"
  exit 1
fi

echo -e "\n${GREEN}✅ All syntax checks passed successfully!${NC}"
echo -e "${YELLOW}🔄 Proceeding with safe Docker rebuild and restart...${NC}\n"

# --------------------------------------------------------
# 7️⃣ Docker rebuild & restart
# --------------------------------------------------------
docker compose -f "$DOCKER_COMPOSE" down --remove-orphans || true
docker compose -f "$DOCKER_COMPOSE" build --no-cache
docker compose -f "$DOCKER_COMPOSE" up -d

# --------------------------------------------------------
# 8️⃣ Post-rebuild health checks
# --------------------------------------------------------
echo -e "\n${YELLOW}🩺 Performing post-rebuild health checks...${NC}"
API_HOST=$(hostname -I | awk '{print $1}')
API_URL="http://${API_HOST}:8010/openapi.json"
UI_URL="http://${API_HOST}:5183"

sleep 5  # give containers time to boot

check_api() {
  if curl -s --max-time 5 "$API_URL" | grep -q "openapi"; then
    echo -e "  ${GREEN}✔ API reachable at${NC} $API_URL"
  else
    echo -e "  ${RED}✖ API not responding properly${NC}"
    docker logs docker-api-1 | tail -n 20 || true
    fail=1
  fi
}

check_ui() {
  if curl -s --max-time 5 "$UI_URL" | grep -q "<!DOCTYPE html>"; then
    echo -e "  ${GREEN}✔ UI reachable at${NC} $UI_URL"
  else
    echo -e "  ${RED}✖ UI not responding properly${NC}"
    docker logs docker-web-1 | tail -n 20 || true
    fail=1
  fi
}

check_api
check_ui

# --------------------------------------------------------
# 9️⃣ Final summary
# --------------------------------------------------------
if [[ $fail -eq 0 ]]; then
  echo -e "\n${GREEN}🚀 System validation, rebuild, and health checks PASSED!${NC}"
  echo -e "${GREEN}🌐 Access the web interface at:${NC} $UI_URL"
else
  echo -e "\n${RED}⚠ Some health checks failed.${NC} Use logs above to investigate."
  exit 1
fi

