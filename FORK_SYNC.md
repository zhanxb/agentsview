# fork 维护手册：跟随上游 tag 同步 + 打包

本仓库是 [kenn-io/agentsview](https://github.com/kenn-io/agentsview) 的 fork，唯一实质改动是
**新增 CodeFree-O（中国电信研发云）会话源**。这份手册把「上游发新版本之后要做的全部动作」
固定下来，照做即可，不需要重新思考。

改动清单见 [README_zh.md](README_zh.md)。

---

## 0. 原则（先看这张表）

| 项目 | 规则 |
| --- | --- |
| 同步源 | 上游**正式 tag**（如 `v0.47.0`），**不再跟 `upstream/main`** |
| 同步时机 | 上游发布新 tag 之后（不追 main 上的日常提交） |
| 版本号 | `desktop/src-tauri/tauri.conf.json` 的 `version` = tag 去掉 `v`（如 `0.47.0`） |
| 主线分支 | `main`，唯一 |
| 验证 | `./scripts/fork-verify.sh` —— 只看"新增失败"，环境性失败有基线兜底 |
| 打包 | GitHub Actions `Desktop Artifacts`，产物不下下载也可以 |
| 本地构建安装包 | 不做。本机 MinGW 无法链接 libduckdb，安装包一律交给 CI |

**为什么跟 tag 而不是 main？**

`main` 上游每天几十个提交，夹着重构中间态，合并冲突面大、验证噪音多；tag 是官方发版点，
代码边界清晰。两者是**同一条历史的两个点**——tag 必然包含它之前的所有 main 提交，
所以"等 tag"不会丢代码，只是把同步时点推迟到官方认为稳定的那一刻。

**版本号为什么要跟着改？**

上游的桌面版本号（`tauri.conf.json`）长期停在 `0.12.1`，与 CLI 版本（`0.46.1`）是两条线。
我们把桌面版本号对齐 tag，好处是安装包文件名直接体现同步到了哪一版
（`AgentsView_0.47.0_x64-setup.exe`），覆盖安装时 Windows 也能正确识别为升级。
`Cargo.toml` 和 `frontend/package.json` 的 `0.1.0` 不用动，它们不影响安装包文件名。

---

## 0.5 两个脚本在哪运行（容易误解，先说清）

| 脚本 | 实际执行位置 | 干什么 |
| --- | --- | --- |
| `scripts/fork-verify.sh` | **你的电脑** | 编译、检查 12 处注册点、跑单元测试，全部在本地完成 |
| `scripts/fork-package.sh` | **你的电脑**发起 | 调 GitHub API 触发云端构建，再轮询进度。**编译打包在 GitHub 服务器上跑**，本机只发命令、收结果 |

`fork-package.sh` 自己不做任何构建：真正的 `go build` / `npm run build` / `tauri build`
发生在 `.github/workflows/desktop-artifacts.yml` 定义的 GitHub 托管机器上。所以本机不需要
Rust，也不需要能链接 libduckdb。脚本退出或关掉终端都不影响云端构建，只是不再显示进度
（进度可以去 Actions 页面看）。

### Windows 11 上怎么运行

两个都是 bash 脚本，**不能双击，也不能在 PowerShell 里直接写 `./scripts/xxx.sh`**。
两种可行方式：

方式一，用 Git Bash（推荐，一次学会长期用）：开始菜单搜 **Git Bash**，然后

```bash
cd /d/AppWorkspace/GoWorkspace/agentsview
./scripts/fork-verify.sh --with-frontend
```

方式二，在 PowerShell 里借用 Git 自带的 bash（本机 Git 装在 `D:\DevelopmentKit\Git`）：

```powershell
& "D:\DevelopmentKit\Git\bin\bash.exe" -c "cd /d/AppWorkspace/GoWorkspace/agentsview && ./scripts/fork-verify.sh"
```

依赖条件：

- `fork-verify.sh` 需要 Go 与 GCC，脚本会自动找 `C:\Program Files\Go\bin` 和 MinGW 便携版目录；
- `fork-package.sh` 需要 Python（解析 JSON，`py -3` 也认）、curl（Windows 10 以上自带）、
  已保存的 GitHub 凭据（执行过一次 `git push` 就有）、以及 10808 代理在运行
  （不想用代理就 `PROXY=none ./scripts/fork-package.sh`）。

---

## 1. 同步上游 tag（6 步）

```bash
cd /d/AppWorkspace/GoWorkspace/agentsview

# 1) 确认工作区干净（有未提交改动先处理掉）
git status --short

# 2) 记录回退点：出错可一键回到同步前
git branch -f backup-before-sync-$(date +%Y%m%d) HEAD
git rev-parse HEAD        # 记下这个 SHA

# 3) 拉取上游 tag（--tags 才会把新 tag 带下来）
git fetch upstream --tags

# 4) 看最新 tag 和它带来多少提交
git tag --sort=-v:refname | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | head -3
NEW_TAG=v0.47.0          # ← 换成实际最新 tag
git log --oneline HEAD..$NEW_TAG | head -30
git diff --stat HEAD $NEW_TAG | tail -3

# 5) 合并该 tag（不是 main）
git merge $NEW_TAG --no-edit

# 6) 冲突处理见第 6 节；无冲突则继续
git status --short
```

> 若 `fetch` 卡住，先确认代理：`curl -s --proxy socks5h://127.0.0.1:10808 https://api.github.com -o /dev/null -w '%{http_code}\n'`
> 返回 200 说明代理正常。仓库级已配置 `http.https://github.com.proxy = socks5://127.0.0.1:10808`。

---

## 2. 改版本号（1 处）

```bash
# 把 version 改成新 tag（去掉 v）
grep -n '"version"' desktop/src-tauri/tauri.conf.json
```

例如同步 `v0.47.0` 后：

```json
"productName": "AgentsView",
"version": "0.47.0",
```

⚠️ 这个文件同时是我们的"防自动更新"改动点，必须保持：

```json
"updater": {
  "pubkey": "NOT_SET",
  "endpoints": []
}
```

`endpoints` 不能有内容。否则应用会去查上游更新清单——虽然因签名公钥不匹配装不上，
但每次启动都会弹"下载失败"，很烦。`pubkey` 字段也不能删，插件反序列化要求它存在。

---

## 3. 本地验证

```bash
./scripts/fork-verify.sh --with-frontend
```

脚本做四件事，输出 `✅ 全部检查通过` 就放心推送：

1. `gofmt` / `go vet` / `go build ./internal/...`
2. **fork 改动完整性**——12 项 CodeFree-O 注册点检查逐个 grep，防止被上游覆盖（这是合并最容易出的错）
3. 版本号与最新 tag 是否一致（只提示，不阻断）
4. 跑 5 个包的测试，把失败与基线比对，**只报"新增失败"**

首次运行约 15~18 分钟（Go 测试缓存命中后会快很多）。想快速只验 CodeFree-O：

```bash
./scripts/fork-verify.sh --quick
```

### 它为什么能解决"每次本地一堆报错"

因为那 25 个报错绝大多数不是代码问题，而是 Windows 环境限制。脚本把它们记进
`scripts/fork-verify-baseline.txt` 当基线，日常只对比增量——**出现基线外的新失败才是信号**。

---

## 4. 已知环境性失败（25 个，全部与代码无关）

| 包 | 数量 | 根因 |
| --- | --- | --- |
| `internal/parser` | 14 | 符号链接权限 |
| `internal/sync` | 4 | 3 个符号链接 + 1 个 IO 错误模拟 |
| `internal/rawarchive` | 6 | 符号链接权限 |
| `internal/db` | 1 | 并发时序 flaky（`TestUsageCacheGenerationPublishesConcurrently`） |

### 根因一：Windows 符号链接权限（24 个）

报错长这样：

```
A required privilege is not held by the client.
```

测试要在临时目录里创建 symlink，而 Windows 默认只允许**管理员**或**开启开发者模式**的
账户创建符号链接。当前机器的状态是：

```
AllowDevelopmentWithoutDevLicense = 0   ← 开发者模式未开启
IsAdmin = False                          ← 也不是管理员
```

**根治办法（推荐，能一次消掉 24 个）**：设置 → 隐私和安全性 → 开发者选项 → 打开
**开发人员模式**。开完重新打开终端，再跑脚本，这批失败会消失，脚本会提示"可清理基线"，
届时执行 `./scripts/fork-verify.sh --update-baseline` 重新生成即可。

**兜底办法（不改系统）**：基线机制。日常就不必再逐个甄别了。

### 根因二：libduckdb 链接失败（不是 25 个之一，是"跑不起来"）

`internal/server` 的测试、`cmd/*` 的二进制在本机**链接阶段**就失败：

```
undefined reference to `__stdio_common_vsnprintf_s'
undefined reference to `__emutls_get_address'
```

原因是项目依赖的 libduckdb 预编译静态库按 **MSVC 运行库**构建，本机 MinGW-GCC 无法链接。
这与代码无关，也**无法在本地绕过**。结论：

- 本地不跑 `./cmd/...` 和 `internal/server` 的测试；
- 这两个包的验证**由 GitHub Actions 负责**（CI 用官方 runner，链接正常）；
- 所以「本地全绿」不等于「CI 会过」，打包结果才是最终判据。

### 顺带两个环境坑

| 现象 | 原因 | 解法 |
| --- | --- | --- |
| `go build` 卡在下载模块 / `connection reset` | goproxy.cn 断流 | `GOPROXY=direct HTTPS_PROXY=socks5://127.0.0.1:10808 go mod download` |
| `npm ci` 失败、node_modules 被拦 | 安全钩子拦截批量删除 | 用 `npm install` 代替 |
| `package-lock.json` 出现大量改动 | npm 换镜像导致 | `git checkout -- frontend/package-lock.json` 恢复 |

---

## 5. 推送并打包

```bash
git push origin main
```

然后触发云端构建（产物不必下载）：

```bash
./scripts/fork-package.sh            # 触发 + 轮询到结束，打印结论
./scripts/fork-package.sh --watch    # 同上（默认就是 watch）
```

脚本只报结果，不下载文件。想手工操作也可以：fork 页面 → **Actions** →
**Desktop Artifacts** → **Run workflow**（选 `main`）。

构建约 15~25 分钟，Windows job 最慢（Rust 首次编译）。成功的标志是三个桌面任务
（Windows / Linux / Linux arm64）全部 green。产物名形如：

```
agentsview-desktop-windows → AgentsView_0.47.0_x64-setup.exe
```

需要安装时再去 Actions 页面下载，或让脚本加 `--download` 拉到 `~/Downloads`。

> 说明：如果这次同步改到了 `desktop/**`、`frontend/**` 或 `go.mod`，`git push` 会**自动**
> 触发一次构建；随后脚本再手动触发一次，两者属于同一并发组，先启动的那次会被取消
> （日志里显示 cancelled，属正常）。脚本查的是 `workflow_dispatch` 那次，结论以它为准。

---

## 6. 冲突处理规则

同步时冲突几乎只出现在以下文件。判断原则：**上游的改动要保留，我们的改动也要保留，
两者是并列关系，不是二选一**。

| 文件 | 处理 |
| --- | --- |
| `desktop/src-tauri/tauri.conf.json` | 保留 `"version": "<新tag>"` 和 `"endpoints": []`，其余取上游 |
| `internal/parser/types.go` | AgentDef 列表两边都留：上游新增的 agent + `AgentCodeFreeO` |
| `internal/parser/discovery.go` | `codefreeOFmt` 与上游新增格式并列保留 |
| `internal/parser/provider.go` / `provider_migration.go` | 工厂映射两边都留 |
| `internal/parser/opencode_provider.go` | CodeFree-O 分支与上游 OpenCode 家族改动共存 |
| `internal/ingest/history_opencode.go` | 家族清单里保留 `AgentCodeFreeO` |
| `internal/sync/engine.go` / `opencode_container_gate.go` | 家族清单里保留 `AgentCodeFreeO` |
| `frontend/src/lib/utils/agents.ts` / `agents.test.ts` | KNOWN_AGENTS 清单保留 `codefree-o` 条目 |
| `docs/internal/session-format-sources.md` | 保留 CodeFree-O 条目，`checked` 日期可更新 |
| `internal/parser/*_test.go`（枚举类） | 上游若新增 agent，把 `codefree-o` 加进期望列表 |

解完冲突后**必须**跑 `./scripts/fork-verify.sh`——第 2 步的 12 项完整性检查就是专门抓
"改漏一处注册"这类问题的（编译能过，但运行时会漏掉 CodeFree-O 的会话）。

如果合并彻底搞砸了：

```bash
git merge --abort                                   # 还没提交
git reset --hard <第 1 步记下的 SHA>                # 已提交但想重来
```

---

## 7. 下次上游发新 tag 时，把这段话发给 AI

> 上游 agentsview 发了新 tag。按仓库里的 `FORK_SYNC.md` 执行完整同步流程：
> 1. 确认工作区干净，打 `backup-before-sync-<日期>` 分支做回退点；
> 2. `git fetch upstream --tags`，找出最新正式 tag（形如 `vX.Y.Z`），报告它带来多少提交、改了哪些文件；
> 3. `git merge <tag>`，有冲突按 FORK_SYNC.md 第 6 节的规则解，原则是上游改动和 CodeFree-O 改动都要保留；
> 4. 把 `desktop/src-tauri/tauri.conf.json` 的 `version` 改成 tag 去掉 v，并确认 `"endpoints": []` 还在；
> 5. 跑 `./scripts/fork-verify.sh --with-frontend`，**只把新增失败告诉我**，基线内的环境性失败不用提；
> 6. 验证通过后推送 `origin main`，用 `./scripts/fork-package.sh` 触发 Desktop Artifacts 并等到结束，告诉我三个平台的结论和产物文件名。
> 安装包不用下载。

想更省事，只说一句也行：

> 上游发新 tag 了，按 FORK_SYNC.md 同步并打包，不用下载安装包。

---

## 8. 常见问题

**Q：合并后应用里看不到 CodeFree-O 的会话了？**
先跑 `./scripts/fork-verify.sh --quick`。多半是某处注册点被上游覆盖，脚本会直接指出是哪个文件。
其次是环境变量/配置：默认扫描 `%USERPROFILE%\.codefree-o\.local\share`，
可用 `CODEFREEO_DIR` 或配置项 `codefreeo_dirs` 覆盖。

**Q：安装包版本号和上游 CLI 版本号不一样，正常吗？**
正常。上游桌面版有自己的版本线（长期是 `0.12.1`），CLI 是 `v0.46.x`。我们让桌面版对齐 tag，
所以两者一致；上游官方桌面包则不会。

**Q：会不会被自动更新成原版？**
不会。产物没有官方签名私钥，`pubkey` 是 `NOT_SET`，更新包签名校验必然失败；
现在 `endpoints` 也为空，连检查都不会发起。

**Q：能不能改回跟 main 同步？**
可以，`git merge upstream/main` 即可。但会失去"版本边界清晰、只同步发版代码"的好处，
且每次冲突面更大，不建议。

**Q：我现在的代码已经包含 tag 之后的 main 提交，切到 tag 策略会"回退"吗？**
不会。git 不会删除已经在历史里的提交。下次 `merge v0.47.0` 时，那个 tag 本身也包含这些
提交（tag 是从 main 上打的），合并结果是"新 tag 的全部内容 + 我们的 CodeFree-O 改动"。
tag 策略的作用是**从此以后只在新发版时同步**，不是让现有历史变干净。
若真想让代码等于"纯 v0.46.1 + fork 改动"，得 reset 到 tag 再 cherry-pick fork 提交，
代价是丢掉那些提交带来的功能，不建议。

**Q：gitee 能替代 GitHub Actions 打包吗？**
不能。Gitee Go 的云端 runner 只有 Linux，Windows 构建需要自托管机器。Gitee 镜像只能当代码备份。
