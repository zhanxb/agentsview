---
last_edited: 2026-11-02
---

# agentsview 中文说明（fork 版）

本仓库是 [kenn-io/agentsview](https://github.com/kenn-io/agentsview) 的 fork，
在原版基础上新增了对 **CodeFree-O**（中国电信研发云，基于 OpenCode 内核）会话记录
的支持。本文件面向 fork 的维护者，说明三件事：

1. 上游发布新版本时，如何把代码同步进来；
2. CodeFree-O 支持改动了哪些文件，方便合并时定位冲突；
3. 如何把代码构建成可用的程序和安装包。

原版功能、安装方式和文档见 [README.md](README.md)（英文，未改动）。

## CodeFree-O 支持说明

CodeFree-O 是 OpenCode 的分支，把会话存放在
`%USERPROFILE%\.codefree-o\.local\share\codefree.db`，表结构与 OpenCode 的
`opencode.db` 完全一致（session / message / part / project / project_directory）。
`storage\session_diff` 目录存放的是文件差异补丁，不是会话正文，所以会话只从
SQLite 读取。

实现方式是复用项目里现成的 OpenCode 格式解析器，把会话 ID 重新标记到
`codefree-o:` 前缀上。涉及改动的文件：

| 文件 | 改动内容 |
| --- | --- |
| `internal/parser/types.go` | 新增 `AgentCodeFreeO` 常量和 `Registry` 条目 |
| `internal/parser/discovery.go` | 新增 `codefreeOFmt` 格式定义和路径辅助函数 |
| `internal/parser/codefreeo.go` | 新文件：元数据读取、mtime、会话重标记 |
| `internal/parser/codefreeo_test.go` | 新文件：单元测试 |
| `internal/parser/opencode_provider.go` | provider spec 增加 codefree-o 分支 |
| `internal/parser/provider.go` | provider 工厂映射 |
| `internal/parser/provider_migration.go` | 迁移模式注册 |
| `internal/parser/capabilities_sync_test.go` | 同步语义声明测试 |
| `internal/parser/provider_capabilities_test.go` | 能力枚举测试 |
| `internal/parser/types_test.go` | 类型枚举测试 |
| `internal/ingest/history_opencode.go` | 存储格式判定与 DB 名映射 |
| `internal/sync/engine.go` | 同步引擎 4 处 agent 分支 |
| `internal/sync/opencode_container_gate.go` | OpenCode 家族共享容器门控 |
| `frontend/src/lib/utils/agents.ts` | 前端 agent 名称与配色 |
| `frontend/src/lib/utils/agents.test.ts` | 前端测试 |
| `docs/internal/session-format-sources.md` | 格式来源条目 |
| `docs/usage.md` | 会话标题来源清单 |

以上游合并时，冲突大概率出现在这些文件里。解冲突的原则很简单：上游对
OpenCode 家族的改动要保留，CodeFree-O 的分支要保留——两者是并列关系。

## 从上游同步新版本

### 一次性配置

只需做一次。给 fork 添加上游仓库地址：

```bash
git remote add upstream https://github.com/kenn-io/agentsview.git
git fetch upstream
```

查看远程配置是否正确：

```bash
git remote -v
# origin    https://github.com/zhanxb/agentsview.git (fetch)
# upstream  https://github.com/kenn-io/agentsview.git (fetch)
```

### 日常同步（跟 tag，不跟 main）

完整流程、版本号规则、冲突处理、已知环境性失败清单都在 **[FORK_SYNC.md](FORK_SYNC.md)**。
这里只列命令主干：

```bash
# 1. 确认工作区干净，并留一个回退点
git status --short
git branch -f backup-before-sync-$(date +%Y%m%d) HEAD

# 2. 拉取上游 tag，确认最新正式版本
git fetch upstream --tags
git tag --sort=-v:refname | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | head -3

# 3. 合并该 tag（示例为 v0.47.0，换成实际最新 tag）
git merge v0.47.0 --no-edit

# 4. 把 desktop/src-tauri/tauri.conf.json 的 version 改成 0.47.0
#    同时确认 updater 的 "endpoints": [] 还在

# 5. 验证：只关心"新增失败"，基线内的环境性失败自动忽略
./scripts/fork-verify.sh --with-frontend

# 6. 推送并触发云端打包（不下载产物）
git push origin main
./scripts/fork-package.sh
```

### 合并后必须验证

一条命令即可：

```bash
./scripts/fork-verify.sh --with-frontend
```

它会做 gofmt / vet / 编译、**逐个检查 12 处 CodeFree-O 注册点是否被上游覆盖**、
校验版本号与 tag 一致，再跑测试并把失败与基线比对。

只想快速确认 CodeFree-O 还能用：

```bash
./scripts/fork-verify.sh --quick
```

Windows 上有一批依赖符号链接权限的既有失败，以及 `libduckdb` 无法用 MinGW 链接的问题，
都不影响结论——脚本已按基线处理，详见 FORK_SYNC.md 第 4 节。

> 脚本是 bash 脚本，Windows 上要在 **Git Bash** 里运行（不能双击，也不能在 PowerShell 里直接
> `./xxx.sh`）。具体两种运行方式和依赖见 FORK_SYNC.md 的「0.5 两个脚本在哪运行」。

### 上游改了 OpenCode 家族怎么办

上游对 OpenCode 解析器（`internal/parser/opencode.go` 等）的修复会自动惠及
CodeFree-O，因为两者共用同一套解析逻辑，一般不需要额外动作。需要留意的是：

- 上游如果在 `internal/parser/discovery.go` 新增了 OpenCode 家族成员，合并时
  把 `codefreeOFmt` 保留在同一组格式定义里即可；
- 上游如果修改了 `IsOpenCodeFormatStorageAgent`、`openCodeFamilySQLiteAgents`
  这类家族清单，合并后确认 `AgentCodeFreeO` 还在清单里。

## 本地构建

### 构建环境要求

| 组件 | 用途 | Windows 上的获取方式 |
| --- | --- | --- |
| Go 1.2x+ | 后端编译 | https://go.dev/dl/ |
| GCC（CGO） | SQLite / FTS5 编译 | MSYS2 MinGW-w64，或便携版放入 PATH |
| Node.js + npm | 前端构建 | https://nodejs.org/ |
| Rust（rustc + cargo） | 桌面端打包 | https://rustup.rs/ |

命令行构建二进制：

```bash
# 前端构建 + Go 编译，产出 ./agentsview（可执行文件，内嵌前端与定价数据）
make build

# 发布版（带优化与版本号信息）
make build-release

# 直接安装到本地 bin 目录
make install
```

Windows 上如果 `make` 不可用，等价的手工命令是：

```bash
cd frontend && npm ci && npm run build && cd ..
go run ./internal/pricing/cmd/litellm-snapshot -restore
CGO_ENABLED=1 go build -tags fts5 -o agentsview.exe ./cmd/agentsview
```

启动方式：运行 `agentsview`（或 `agentsview.exe`）后浏览器访问提示的本地地址。

## 打成安装包

项目使用 Tauri 把 Go 后端打包成桌面应用（Windows 为 NSIS 安装包）。有两条路：
本地构建和 GitHub Actions 云端构建。

### 方式一：GitHub Actions 云端构建（推荐，无需本地 Rust）

一条命令触发并等到结果，产物不下载：

```bash
./scripts/fork-package.sh              # 触发 + 轮询 + 报告结论
./scripts/fork-package.sh --download   # 顺便把 Windows 安装包下到 ~/Downloads
./scripts/fork-package.sh --status     # 只看最近一次运行
```

脚本做的是：调用 GitHub API 触发 `.github/workflows/desktop-artifacts.yml`，
轮询到结束，打印三个平台的任务结论与产物清单。

也可以手工操作。仓库自带工作流 `.github/workflows/desktop-artifacts.yml`，支持手动触发，
会构建 Windows（NSIS 安装包）和 Linux（AppImage）产物。在你的 fork 页面上：

1. 打开 **Actions** 标签页；
2. 左侧选择 **Desktop Artifacts**；
3. 右侧点 **Run workflow**，选 `main` 分支，确认运行；
4. 构建完成后在该次运行的 **Artifacts** 区域下载
   `agentsview-desktop-windows`；
5. 解压后得到 NSIS 安装包（`*-setup.exe`），双击安装。

公开仓库的 Actions 免费且有官方缓存，这是最省事的方式。注意 fork 页面默认
禁用 Actions，需要先在 **Settings → Actions → General** 里启用。

### 方式二：本地构建安装包

装好 Rust 工具链后执行：

```bash
# Windows NSIS 安装包，产出在 dist/desktop/windows/
make desktop-windows-installer
```

等价的详细过程：

```bash
cd desktop
npm ci
npm run tauri:build:windows
# 安装包位于 desktop/src-tauri/target/release/bundle/nsis/*-setup.exe
```

`tauri:build` 会自动先构建 Go 后端二进制（`prepare-sidecar`），所以本地构建
同样需要 Go 和 CGO 编译器。其他平台：

| 目标 | Makefile 目标 | 产物 |
| --- | --- | --- |
| Windows 安装包 | `make desktop-windows-installer` | NSIS `*-setup.exe` |
| macOS .app | `make desktop-macos-app` | `AgentsView.app` |
| macOS DMG | `make desktop-macos-dmg` | `.dmg` 镜像 |
| Linux AppImage | `make desktop-linux-appimage` | `.AppImage` |

桌面应用启动后在本机拉起 agentsview 服务进程，数据仍留在本机。

## 发布自己的版本（可选）

想给改版打标签、发 Release：

```bash
# 上游版本号基础上加后缀，避免与官方版本混淆，例如 v0.46.1-codefree.1
git tag v0.46.1-codefree.1
git push origin v0.46.1-codefree.1
```

然后在 fork 的 GitHub 页面 **Releases → Draft a new release**，选这个标签，
把云端构建出的安装包拖进附件即可。
