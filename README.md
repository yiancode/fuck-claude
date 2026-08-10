# fuck-claude

把 **macOS** 环境调成更容易在 [fuck-claude.app](https://fuck-claude.app/) 上拿到 **CLEAR** 的状态，并支持一键恢复。

> 这是社区探测页的**环境调优脚本**，不是 Claude / Anthropic 官方工具。  
> 探测页自己也说明：与 Claude Code **一一对应**的主要是 **系统时区**；其它项是相关指纹。

## 背景

[fuck-claude.app](https://fuck-claude.app/) 会扫描约 11 项浏览器/系统信号，例如：

| 信号 | 权重（约） | 本仓库是否处理 |
|------|------------|----------------|
| 系统时区（Claude 同款） | 26 | ✅ `apply` 改为非中国区（默认 `America/Los_Angeles`） |
| 浏览器语言 | 20 | ✅ 仅 `en-US` / `en` |
| 中文字体 | 17 | ❌ 系统字体，不删（有风险） |
| Intl 区域 | 8 | ✅ `en_US` |
| 时区偏移 | 6 | ✅ 随系统时区 |
| Emoji / WebGL / 分辨率等 | 低 | 部分间接影响 / 不强制 |
| DNT / GPC | 3 | ✅ 尽量开启 |

在 macOS + **Brave** 上，常见「够用」结果是：

- **Verdict: CLEAR**
- 时区 / 语言 / GPC 等为 0
- **中文字体仍可能 +17**（正常，可忽略）

## 要求

- macOS
- 会弹窗要管理员密码（改系统时区）
- 建议先**完全退出** Chrome / Edge / Brave，再执行

## 安装

```bash
git clone https://github.com/yiancode/fuck-claude.git
cd fuck-claude
chmod +x bin/apply.sh bin/restore.sh
```

## 使用

### 1. 应用（改环境）

```bash
./bin/apply.sh
```

会：

1. 把当前状态快照到 `~/.fuck-claude/state.json`
2. 备份 Chrome / Edge / Brave 的 `Preferences`
3. 设置时区、语言、浏览器 Accept-Language、DNT/GPC、Brave 指纹 Strict 等

可选：

```bash
./bin/apply.sh --dry-run
FUCK_CLAUDE_TIMEZONE=America/New_York ./bin/apply.sh
./bin/apply.sh --force    # 覆盖已有快照（慎用）
```

### 2. 验证

```bash
# 时区不应再是 Asia/Shanghai
readlink /etc/localtime
date +'%Z %z'

# 用 Brave 打开探测页重新扫描
open -a "Brave Browser" "https://fuck-claude.app/"
```

### 3. 恢复（还原）

```bash
./bin/restore.sh
```

从 `~/.fuck-claude/state.json` 与浏览器备份恢复时区、语言、Preferences 等。

```bash
./bin/restore.sh --dry-run
./bin/restore.sh --keep-state   # 恢复但保留快照文件
```

## 状态目录

```text
~/.fuck-claude/
  state.json           # 当前 apply 快照（restore 用）
  backups/<timestamp>/ # 浏览器 Preferences 备份
  last-run.log
```

## 推荐浏览器

| 浏览器 | 建议 |
|--------|------|
| **Brave**（推荐日常） | Shields → Fingerprinting → **Strict**；语言仅 English |
| Chrome / Edge | 可用；字体项通常仍 +17 |
| Mullvad / Tor | 字体指纹更强，但不必日常使用 |

## 不会做什么

- 不删除 / 不停用系统中文字体（PingFang 等）
- 不修改 VPN / 出口 IP
- 不保证 100% 通过（时区若被系统自动改回上海会立刻失败）
- 不绕过任何服务的真实服务条款审查——只调整**本机指纹相关环境**

## 时区又变回上海？

常见原因：

1. **系统设置 → 日期与时间 → 自动设置时区** 被打开  
2. 其它脚本/工具改了 `/etc/localtime`  
3. 在另一台机器上扫描  

`apply` 会关闭自动时区；若仍被改回，请手动关掉自动时区后再执行一次 `apply`。

## 安全说明

- 改时区需要**本机管理员权限**（macOS 图形密码框）
- 状态与备份只写在用户目录 `~/.fuck-claude/`
- 请先读脚本再执行；欢迎审计 `bin/` 与 `lib/`

## 许可证

MIT — 见 [LICENSE](./LICENSE)

## 免责声明

本项目与 Anthropic / Claude 官方无关。  
使用风险自负；请遵守你所在地区的法律法规与服务条款。
