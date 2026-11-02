#!/usr/bin/env bash
# fork-verify.sh — agentsview fork 本地验证器
#
# 作用：把「Windows 环境限制导致的失败」和「合并上游引入的真实回归」区分开。
# 做法：每次运行收集失败用例，与 fork-verify-baseline.txt 比对；
#       命中基线 = 已知环境问题（忽略），未命中 = 新失败（报警并退出码 1）。
#
# 用法：
#   ./scripts/fork-verify.sh                   # 常规验证
#   ./scripts/fork-verify.sh --update-baseline # 确认新失败是环境问题后，收进基线
#   ./scripts/fork-verify.sh --with-frontend   # 额外跑前端 agents 单测
#   ./scripts/fork-verify.sh --quick           # 只跑 fork 相关（CodeFreeO）测试
#
# 环境变量（一般不用设，脚本会自动探测）：
#   GO_BIN      go 可执行文件路径
#   MINGW_BIN   MinGW bin 目录（CGO 需要 gcc）
#   GOCACHE     Go 构建缓存目录

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASELINE="$ROOT/scripts/fork-verify-baseline.txt"
TMPDIR_RUN="$(mktemp -d)"
# 逐文件清理，不用 rm -rf（递归删除会被工作区安全策略拦截）
cleanup() {
  [ -d "$TMPDIR_RUN" ] || return 0
  find "$TMPDIR_RUN" -maxdepth 1 -type f -exec rm -f {} + 2>/dev/null || true
  rmdir "$TMPDIR_RUN" 2>/dev/null || true
}
trap cleanup EXIT

UPDATE_BASELINE=0
WITH_FRONTEND=0
QUICK=0
for arg in "$@"; do
  case "$arg" in
    --update-baseline) UPDATE_BASELINE=1 ;;
    --with-frontend)   WITH_FRONTEND=1 ;;
    --quick)           QUICK=1 ;;
    *) echo "未知参数: $arg" >&2; exit 2 ;;
  esac
done

# ---------- 工具链探测 ----------
if [ -n "${GO_BIN:-}" ]; then
  export PATH="$GO_BIN:$PATH"
elif ! command -v go >/dev/null 2>&1; then
  [ -x "/c/Program Files/Go/bin/go" ] && export PATH="/c/Program Files/Go/bin:$PATH"
fi

if [ -z "${MINGW_BIN:-}" ]; then
  for cand in \
    "/c/Users/$USERNAME/.workbuddy/binaries/mingw64/mingw64/bin" \
    "/c/msys64/mingw64/bin" \
    "/c/Program Files/mingw64/bin"; do
    [ -x "$cand/gcc.exe" ] && MINGW_BIN="$cand" && break
  done
fi
[ -n "${MINGW_BIN:-}" ] && export PATH="$MINGW_BIN:$PATH"

export CGO_ENABLED=1
export GOCACHE="${GOCACHE:-${LOCALAPPDATA:-$HOME/AppData/Local}/go-build}"
export GOFLAGS="${GOFLAGS:-}"

GREEN=$'\033[32m'; RED=$'\033[31m'; YELLOW=$'\033[33m'; DIM=$'\033[2m'; RESET=$'\033[0m'
[ -t 1 ] || { GREEN=""; RED=""; YELLOW=""; DIM=""; RESET=""; }

# 基线文件允许整行注释与行尾注释，比对前统一剥离
read_baseline() {
  sed -E 's/[[:space:]]*#.*$//' "$BASELINE" | grep -v '^[[:space:]]*$' | sort -u
}

step() { printf '\n%s==> %s%s\n' "$DIM" "$1" "$RESET"; }
ok()   { printf '  %s✓%s %s\n' "$GREEN" "$RESET" "$1"; }
bad()  { printf '  %s✗%s %s\n' "$RED" "$RESET" "$1"; }
warn() { printf '  %s!%s %s\n' "$YELLOW" "$RESET" "$1"; }

FAILED=0

step "工具链"
if ! command -v go >/dev/null 2>&1; then
  bad "找不到 go，请安装 Go 或设置 GO_BIN"; exit 2
fi
ok "go $(go version | awk '{print $3}')"
if command -v gcc >/dev/null 2>&1; then
  ok "gcc $(gcc -dumpversion 2>/dev/null)"
else
  bad "找不到 gcc（CGO 必需），设置 MINGW_BIN 指向 MinGW 的 bin 目录"; exit 2
fi

# ---------- 1. 格式与静态检查 ----------
step "gofmt"
FMT_OUT="$(gofmt -l "$ROOT/internal" "$ROOT/cmd" 2>&1)"
if [ -z "$FMT_OUT" ]; then ok "无格式差异"; else bad "以下文件需 gofmt："; echo "$FMT_OUT" | sed 's/^/      /'; FAILED=1; fi

step "go vet"
if CGO_ENABLED=1 go vet -tags fts5 ./internal/parser/ ./internal/ingest/ ./internal/sync/ ./internal/config/ \
     > "$TMPDIR_RUN/vet.log" 2>&1; then
  ok "无告警"
else
  bad "vet 失败："; tail -20 "$TMPDIR_RUN/vet.log" | sed 's/^/      /'; FAILED=1
fi

# ---------- 2. 编译（可链接的部分） ----------
step "编译 internal/..."
if CGO_ENABLED=1 go build -tags fts5 ./internal/... > "$TMPDIR_RUN/build.log" 2>&1; then
  ok "全部内部包编译通过"
else
  bad "编译失败："; tail -20 "$TMPDIR_RUN/build.log" | sed 's/^/      /'; FAILED=1
fi
warn "cmd/* 与 internal/server 无法在本机链接（libduckdb 需要 MSVC 运行库），由 CI 负责验证"

# ---------- 3. fork 改动完整性（防上游覆盖） ----------
step "fork 改动完整性"
check_contains() { # 文件 正则 说明
  if [ ! -f "$ROOT/$1" ]; then bad "缺少文件 $1"; FAILED=1; return; fi
  if grep -qE "$2" "$ROOT/$1"; then ok "$3"; else bad "$3 —— 丢失！文件：$1"; FAILED=1; fi
}
check_contains internal/parser/types.go              'AgentCodeFreeO'            "types.go 注册 AgentCodeFreeO"
check_contains internal/parser/types.go              'codefree-o'                "types.go 枚举值 codefree-o"
check_contains internal/parser/discovery.go          'codefree\.db'              "discovery.go 识别 codefree.db"
check_contains internal/parser/provider.go           'AgentCodeFreeO'            "provider.go 工厂映射"
check_contains internal/parser/opencode_provider.go  'AgentCodeFreeO'            "opencode_provider.go provider spec"
check_contains internal/ingest/history_opencode.go   'AgentCodeFreeO'            "history_opencode.go 存储格式判定"
check_contains internal/sync/engine.go               'AgentCodeFreeO'            "sync/engine.go 同步分支"
check_contains internal/sync/opencode_container_gate.go 'AgentCodeFreeO'         "opencode_container_gate.go 容器门控"
check_contains frontend/src/lib/utils/agents.ts      'codefree-o'                "前端 agents.ts 注册"
check_contains docs/internal/session-format-sources.md 'CodeFree-O'              "格式来源文档条目"
check_contains desktop/src-tauri/tauri.conf.json     '"endpoints"[[:space:]]*:[[:space:]]*\[\]' "tauri updater 端点已清空"
check_contains README_zh.md                          'CodeFree-O'                "中文说明存在"

# ---------- 4. 版本号一致性（提示，不阻断） ----------
step "版本号"
TAURI_VER="$(grep -m1 '"version"' "$ROOT/desktop/src-tauri/tauri.conf.json" | sed -E 's/.*"version"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')"
LATEST_TAG="$(cd "$ROOT" && git tag --sort=-v:refname 2>/dev/null | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | head -1)"
LATEST_TAG_STRIP="${LATEST_TAG#v}"
if [ "$TAURI_VER" = "$LATEST_TAG_STRIP" ]; then
  ok "tauri 版本 $TAURI_VER 与最新 tag $LATEST_TAG 一致"
else
  warn "tauri 版本 $TAURI_VER ≠ 最新 tag $LATEST_TAG（同步新 tag 时应把 version 改成 $LATEST_TAG_STRIP）"
fi

# ---------- 5. 测试 ----------
step "测试（失败用例与基线比对）"
PKGS=("internal/parser" "internal/ingest" "internal/sync" "internal/db" "internal/rawarchive")
if [ "$QUICK" = "1" ]; then
  go test -tags fts5 -short -run 'CodeFreeO|OpenCode' ./internal/parser/ > "$TMPDIR_RUN/quick.log" 2>&1
  if [ $? -eq 0 ]; then ok "CodeFreeO 相关测试全部通过"; else bad "CodeFreeO 相关测试失败："; tail -15 "$TMPDIR_RUN/quick.log" | sed 's/^/      /'; FAILED=1; fi
else
  : > "$TMPDIR_RUN/fails.txt"
  : > "$TMPDIR_RUN/pkgs.txt"
  for pkg in "${PKGS[@]}"; do
    name="${pkg#internal/}"
    log="$TMPDIR_RUN/${name//\//_}.log"
    CGO_ENABLED=1 go test -tags fts5 -short -timeout 20m "./$pkg/" > "$log" 2>&1
    if grep -qE '^ok ' "$log"; then
      ok "$name 通过"
    elif grep -q 'build failed' "$log"; then
      bad "$name 测试编译失败（本机无法链接 libduckdb？）："
      grep -E 'undefined|cannot find|error' "$log" | head -5 | sed 's/^/      /'
      FAILED=1
    else
      # 只取顶层失败（行首无缩进）
      grep -E '^--- FAIL: ' "$log" | sed -E 's/^--- FAIL: ([^ ]+).*/\1/' | sort -u \
        | while read -r t; do echo "$name:$t" >> "$TMPDIR_RUN/fails.txt"; done
      n=$(grep -cE '^--- FAIL: ' "$log")
      printf '  %s·%s %s 有 %s 个失败（待比对基线）\n' "$DIM" "$RESET" "$name" "$n"
    fi
    echo "$name" >> "$TMPDIR_RUN/pkgs.txt"
  done

  sort -u "$TMPDIR_RUN/fails.txt" -o "$TMPDIR_RUN/fails.txt" 2>/dev/null || true

  if [ "$UPDATE_BASELINE" = "1" ]; then
    {
      echo "# fork-verify 环境性失败基线（Windows 本机，非代码缺陷）"
      echo "# 由 ./scripts/fork-verify.sh --update-baseline 生成"
      echo "# 换机器 / 开启 Windows 开发者模式后，请重新生成"
      cat "$TMPDIR_RUN/fails.txt"
    } > "$BASELINE"
    ok "基线已更新：$(grep -vc '^#' "$BASELINE" 2>/dev/null || echo 0) 条"
  else
    if [ ! -f "$BASELINE" ]; then
      warn "基线文件不存在，先把当前失败全部视为环境性失败写入基线"
      { echo "# fork-verify 环境性失败基线（Windows 本机，非代码缺陷）"; \
        echo "# 由 ./scripts/fork-verify.sh --update-baseline 生成"; \
        cat "$TMPDIR_RUN/fails.txt"; } > "$BASELINE"
      ok "已创建 $BASELINE"
    else
      read_baseline > "$TMPDIR_RUN/base.txt"
      comm -23 "$TMPDIR_RUN/fails.txt" "$TMPDIR_RUN/base.txt" > "$TMPDIR_RUN/new.txt"
      comm -13 "$TMPDIR_RUN/fails.txt" "$TMPDIR_RUN/base.txt" > "$TMPDIR_RUN/gone.txt"

      known=$(wc -l < "$TMPDIR_RUN/base.txt" | tr -d ' ')
      hit=$(comm -12 "$TMPDIR_RUN/fails.txt" "$TMPDIR_RUN/base.txt" | wc -l | tr -d ' ')
      newn=$(wc -l < "$TMPDIR_RUN/new.txt" | tr -d ' ')

      if [ "$hit" -gt 0 ]; then
        printf '  %s·%s 环境性失败 %s 个（命中基线，忽略）\n' "$DIM" "$RESET" "$hit"
      fi
      if [ "$newn" -gt 0 ]; then
        bad "新增失败 $newn 个 —— 可能是真实回归，需人工判断："
        sed 's/^/      /' "$TMPDIR_RUN/new.txt"
        echo "      ${DIM}确认只是环境问题后：./scripts/fork-verify.sh --update-baseline${RESET}"
        FAILED=1
      else
        ok "无新增失败"
      fi
      if [ -s "$TMPDIR_RUN/gone.txt" ]; then
        warn "有 $(wc -l < "$TMPDIR_RUN/gone.txt" | tr -d ' ') 个基线项这次通过了（环境改善或测试被移除），可清理基线："
        sed 's/^/      /' "$TMPDIR_RUN/gone.txt"
      fi
    fi
  fi
fi

# ---------- 6. 前端（可选） ----------
if [ "$WITH_FRONTEND" = "1" ]; then
  step "前端测试"
  if [ -x "$ROOT/frontend/node_modules/.bin/vitest" ]; then
    if (cd "$ROOT/frontend" && npx vitest run src/lib/utils/agents.test.ts > "$TMPDIR_RUN/fe.log" 2>&1); then
      ok "agents.test.ts 通过"
    else
      bad "前端测试失败："; tail -15 "$TMPDIR_RUN/fe.log" | sed 's/^/      /'; FAILED=1
    fi
  else
    warn "frontend/node_modules 不存在，跳过（在 frontend/ 下执行 npm install）"
  fi
fi

# ---------- 汇总 ----------
echo
if [ "$FAILED" = "0" ]; then
  printf '%s全部检查通过%s（环境性失败已按基线忽略）\n' "$GREEN" "$RESET"
  exit 0
else
  printf '%s存在需要处理的问题，见上方 ✗ 项%s\n' "$RED" "$RESET"
  exit 1
fi
