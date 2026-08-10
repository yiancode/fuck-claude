# fuck-claude

把本机环境调成更容易在 [fuck-claude.app](https://fuck-claude.app/) 拿到 **CLEAR** 的状态，并支持一键恢复。

支持：

| 平台 | Apply | Restore |
|------|-------|---------|
| **macOS** | `./bin/apply.sh` | `./bin/restore.sh` |
| **Linux** | `./bin/apply.sh` | `./bin/restore.sh` |
| **Windows** | `.\bin\apply.ps1` | `.\bin\restore.ps1` |

> 社区探测页调优脚本，**非** Claude / Anthropic 官方工具。  
> 与 Claude Code **一一对应**的主要是 **系统时区**；其它是相关指纹。

## 背景

| 信号 | 权重（约） | 脚本是否处理 |
|------|------------|--------------|
| 系统时区（Claude 同款） | 26 | 改为非中国区（默认洛杉矶 / Pacific） |
| 浏览器语言 | 20 | 仅 `en-US` / `en` |
| 中文字体 | 17 | **不处理**（删系统字体风险高） |
| Intl 区域 | 8 | 尽量 `en_US` / `en-US` |
| 时区偏移 | 6 | 随系统时区 |
| DNT / GPC | 3 | 尽量开启 |

常见「够用」结果（Brave + 正确时区）：

- **Verdict: CLEAR**
- 字体项在中文系统上仍可能 **+17**（可忽略）

## 仓库结构

```text
bin/
  apply.sh / restore.sh     # Unix 路由（自动选 macOS / Linux）
  apply-macos.sh
  restore-macos.sh
  apply-linux.sh
  restore-linux.sh
  apply.ps1                 # Windows
  restore.ps1
lib/
  common.sh                 # bash 公共
  browsers.py               # 跨平台 Chromium Preferences
```

状态目录（所有平台）：

```text
~/.fuck-claude/   (Windows: %USERPROFILE%\.fuck-claude\)
  state.json
  backups/<timestamp>/
  last-run.log
```

## 安装

```bash
git clone https://github.com/yiancode/fuck-claude.git
cd fuck-claude
chmod +x bin/*.sh
```

Windows 建议安装 [Python 3](https://www.python.org/)（JSON 补丁更安全）。PowerShell 5.1+ 即可运行。

---

## macOS

```bash
./bin/apply.sh              # 或 ./bin/apply-macos.sh
./bin/apply.sh --dry-run
FUCK_CLAUDE_TIMEZONE=America/New_York ./bin/apply.sh
./bin/restore.sh
```

会改：

1. 时区 → `America/Los_Angeles`（管理员密码）
2. 关闭自动时区
3. `AppleLocale` / `AppleLanguages`
4. Chrome / Edge / Brave Preferences + 部分 policy
5. `~/.curlrc` GPC/DNT 头（可选追加）

验证：

```bash
readlink /etc/localtime
date +%z
open -a "Brave Browser" "https://fuck-claude.app/"
```

---

## Linux

依赖：`python3`、`systemd`/`timedatectl`（改时区需要 sudo）。

```bash
./bin/apply.sh              # 或 ./bin/apply-linux.sh
sudo ./bin/apply-linux.sh   # 若希望少交互，也可先 sudo 再跑时区段
./bin/restore.sh
```

会改：

1. `timedatectl set-timezone America/Los_Angeles`（sudo）
2. `localectl`（若可用）+ 用户级 `~/.config/fuck-claude/env.sh`（`LANG=en_US.UTF-8`）
3. 补丁 `~/.config` 下 Chrome / Chromium / Edge / Brave
4. `~/.curlrc`

验证：

```bash
timedatectl
date +%z
# 新开终端后
echo "$LANG"
xdg-open https://fuck-claude.app/   # 或手动打开 Brave
```

---

## Windows

在 **PowerShell** 中（改时区建议「以管理员身份运行」）：

```powershell
cd path\to\fuck-claude
Set-ExecutionPolicy -Scope Process Bypass

.\bin\apply.ps1
.\bin\apply.ps1 -DryRun
.\bin\apply.ps1 -Timezone "Eastern Standard Time"
.\bin\restore.ps1
```

默认时区：`Pacific Standard Time`（对应 `America/Los_Angeles`）。

可用环境变量：

```powershell
$env:FUCK_CLAUDE_TIMEZONE_WIN = "Pacific Standard Time"
```

会改：

1. `tzutil /s ...`
2. 用户语言列表尽量 `en-US`
3. Chrome / Edge / Brave `Preferences`（优先 Python）
4. `%USERPROFILE%\.curlrc`

验证：

```powershell
tzutil /g
start https://fuck-claude.app/
```

---

## 通用说明

### 执行前

- **完全退出** 浏览器，避免 Preferences 被写回
- 记下当前时区（`restore` 会从快照恢复）

### 不会做的事

- 不删除中文字体
- 不改 VPN / IP
- 不保证 100% 通过（时区被改回中国区会立刻失败）

### 时区又变回中国？

- macOS：关掉「自动设置时区」
- Linux：检查是否有工具在改 `timedatectl`
- Windows：检查「自动设置时区」与定位服务

然后重新 `apply`。

### 环境变量（Unix）

| 变量 | 默认 | 含义 |
|------|------|------|
| `FUCK_CLAUDE_TIMEZONE` | `America/Los_Angeles` | IANA 时区 |
| `FUCK_CLAUDE_LOCALE` | `en_US` | 区域 |
| `FUCK_CLAUDE_LANGS` | `en-US` | 语言列表 |
| `FUCK_CLAUDE_STATE_DIR` | `~/.fuck-claude` | 状态目录 |

## 安全与免责

- 改系统时区需要管理员 / sudo
- 状态只写在用户目录
- 与 Anthropic 无关；请遵守当地法律与服务条款
- MIT License — 见 [LICENSE](./LICENSE)

## 推荐浏览器

日常用 **Brave**（Fingerprinting → Strict，语言仅 English）。  
字体 +17 在中文系统上很常见，**CLEAR 判决下可忽略**。
