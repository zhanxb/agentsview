#!/usr/bin/env bash
# fork-package.sh — 触发 GitHub Actions 打包并等待结果
#
# 用法：
#   ./scripts/fork-package.sh              # 触发 + 等待 + 报告结论（不下载）
#   ./scripts/fork-package.sh --download   # 结束后把 Windows 安装包下到 ~/Downloads
#   ./scripts/fork-package.sh --status     # 只看最近一次运行的状态，不触发新的
#
# 环境变量：
#   PROXY     curl 代理，默认 socks5h://127.0.0.1:10808（设为 none 可关闭）
#   REPO      默认 zhanxb/agentsview
#   BRANCH    默认 main

set -uo pipefail

REPO="${REPO:-zhanxb/agentsview}"
BRANCH="${BRANCH:-main}"
WORKFLOW="desktop-artifacts.yml"
PROXY="${PROXY:-socks5h://127.0.0.1:10808}"

DO_DOWNLOAD=0
STATUS_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --download) DO_DOWNLOAD=1 ;;
    --status)   STATUS_ONLY=1 ;;
    -h|--help)  sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "未知参数: $arg" >&2; exit 2 ;;
  esac
done

[ "$PROXY" = "none" ] && PROXY=""
CURL=(curl -s --max-time 60)
[ -n "$PROXY" ] && CURL+=(--proxy "$PROXY")

# Python 只用来解析 API 返回的 JSON；Windows 上 py -3 也认
PY_BIN=""; PY_ARGS=()
if command -v python3 >/dev/null 2>&1; then
  PY_BIN=python3
elif command -v python >/dev/null 2>&1; then
  PY_BIN=python
elif command -v py >/dev/null 2>&1; then
  PY_BIN=py; PY_ARGS=(-3)
fi
if [ -z "$PY_BIN" ]; then
  echo "找不到 Python（用于解析 GitHub API 返回的 JSON）。" >&2
  echo "装一个即可：winget install Python.Python.3.13" >&2
  exit 2
fi

TOKEN="$(printf 'protocol=https\nhost=github.com\n\n' | git credential fill 2>/dev/null | sed -n 's/^password=//p')"
if [ -z "$TOKEN" ]; then
  echo "取不到 GitHub 凭据（git credential fill 为空）。请先 git push 一次让凭据写入。" >&2
  exit 2
fi

api() { # 方法 路径 [数据]
  local method="$1" path="$2" data="${3:-}"
  if [ -n "$data" ]; then
    "${CURL[@]}" -X "$method" \
      -H "Authorization: Bearer $TOKEN" \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      -d "$data" "https://api.github.com$path"
  else
    "${CURL[@]}" -X "$method" \
      -H "Authorization: Bearer $TOKEN" \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      "https://api.github.com$path"
  fi
}

if [ "$STATUS_ONLY" = "0" ]; then
  echo "==> 触发 $REPO / $WORKFLOW (ref=$BRANCH)"
  CODE="$("${CURL[@]}" -o /dev/null -w '%{http_code}' -X POST \
    -H "Authorization: Bearer $TOKEN" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    -d "{\"ref\":\"$BRANCH\"}" \
    "https://api.github.com/repos/$REPO/actions/workflows/$WORKFLOW/dispatches")"
  case "$CODE" in
    204) echo "    已受理（HTTP 204）" ;;
    401|403) echo "    权限不足（HTTP $CODE）：token 可能缺少 actions:write" >&2; exit 1 ;;
    404) echo "    workflow 不存在或 Actions 未启用（HTTP 404）" >&2; exit 1 ;;
    *)   echo "    触发失败（HTTP $CODE）" >&2; exit 1 ;;
  esac
  echo "    等 15 秒让运行实例出现..."
  sleep 15
fi

# 找最近一次 workflow_dispatch 运行
RUN_ID="$(api GET "/repos/$REPO/actions/workflows/$WORKFLOW/runs?event=workflow_dispatch&per_page=1" \
  | "$PY_BIN" ${PY_ARGS[@]+"${PY_ARGS[@]}"} -c 'import sys,json; d=json.load(sys.stdin); r=(d.get("workflow_runs") or [None])[0]; print(r["id"] if r else "")')"

if [ -z "$RUN_ID" ]; then
  echo "没找到运行实例。用 push 触发也可以：直接 git push 后重跑本脚本 --status" >&2
  exit 1
fi

echo "==> 运行 $RUN_ID"
echo "    https://github.com/$REPO/actions/runs/$RUN_ID"

# 轮询
INTERVAL=30
MAX_WAIT=3600
elapsed=0
last_state=""
while :; do
  JSON="$(api GET "/repos/$REPO/actions/runs/$RUN_ID")"
  read -r STATUS CONCLUSION <<<"$(echo "$JSON" | "$PY_BIN" ${PY_ARGS[@]+"${PY_ARGS[@]}"} -c 'import sys,json; r=json.load(sys.stdin); print(r.get("status") or "-", r.get("conclusion") or "-")')"

  if [ "$STATUS" != "$last_state" ]; then
    echo "    [$((elapsed/60))m] $STATUS"
    last_state="$STATUS"
  fi

  if [ "$STATUS" = "completed" ]; then break; fi
  if [ "$elapsed" -ge "$MAX_WAIT" ]; then echo "    等待超时（1 小时）" >&2; exit 1; fi
  sleep "$INTERVAL"
  elapsed=$((elapsed + INTERVAL))
done

echo
echo "==> 各任务结果"
api GET "/repos/$REPO/actions/runs/$RUN_ID/jobs?per_page=20" | "$PY_BIN" ${PY_ARGS[@]+"${PY_ARGS[@]}"} -c '
import sys, json
d = json.load(sys.stdin)
for j in d.get("jobs", []):
    print("    %-28s %-10s %s" % (j["name"], j["status"], j.get("conclusion") or "-"))
'

echo
echo "==> 产物"
ART_JSON="$(api GET "/repos/$REPO/actions/runs/$RUN_ID/artifacts")"
echo "$ART_JSON" | "$PY_BIN" ${PY_ARGS[@]+"${PY_ARGS[@]}"} -c '
import sys, json
d = json.load(sys.stdin)
for a in d.get("artifacts", []):
    print("    %-32s %6.1f MB" % (a["name"], a["size_in_bytes"]/1048576))
'

if [ "$DO_DOWNLOAD" = "1" ] && [ "$CONCLUSION" = "success" ]; then
  WIN_ID="$(echo "$ART_JSON" | "$PY_BIN" ${PY_ARGS[@]+"${PY_ARGS[@]}"} -c '
import sys, json
d = json.load(sys.stdin)
for a in d.get("artifacts", []):
    if "windows" in a["name"]:
        print(a["id"]); break
')"
  if [ -n "$WIN_ID" ]; then
    DEST="${HOME}/Downloads"
    mkdir -p "$DEST"
    echo
    echo "==> 下载 Windows 产物到 $DEST"
    "${CURL[@]}" -L -o "$DEST/agentsview-desktop-windows.zip" \
      -H "Authorization: Bearer $TOKEN" \
      "https://api.github.com/repos/$REPO/actions/artifacts/$WIN_ID/zip"
    (cd "$DEST" && unzip -o agentsview-desktop-windows.zip >/dev/null && ls -1 *.exe 2>/dev/null | sed 's/^/    /')
  fi
fi

echo
if [ "$CONCLUSION" = "success" ]; then
  echo "✅ 打包成功"
  exit 0
else
  echo "❌ 打包失败（$CONCLUSION），查看日志：https://github.com/$REPO/actions/runs/$RUN_ID"
  exit 1
fi
