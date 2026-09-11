# LingDongDao for Mac

基于 [Atoll](https://github.com/Ebullioscopic/Atoll)（macOS 灵动岛应用，GPL-3.0）的个人分支。

本分支在上游基础上新增了 **AI 编程 CLI 的实时活动**：`pi`、`Codex CLI`、`Claude Code`、`DSH`（终端里的 `dst`）在灵动岛里像计时器一样实时显示正在做什么，并附带缓存命中率与 token 用量。

---

## 新增功能

### 1. CLI 实时活动（收起状态的一行）

四个 CLI 各自有图标与配色，收起时一行显示：

```
( π )  deepseek-v4.1-flash-expires-on-0910  high   99.97%   01:42
  ↑        ↑                                  ↑      ↑      ↑
 图标    模型名（过长自动滚动）           思考程度 命中率  计时
```

- **模型名**：超出宽度用跑马灯滚动，不会把灵动岛无限拉长
- **思考程度**：按等级着色（`off #8E8E93` · `minimal #64D2FF` · `low #5E5CE6` · `medium #BF5AF2` · `high/max #FF9F0A`）
- **缓存命中率**：`已缓存 prompt token ÷ 全部 prompt token`，统一归一化到百分比，**保留两位小数**（缓存通常占 prompt 的绝大部分，取整会看不出 99% 与 99.97% 的差别）
- **计时**：运行中向上计时，结束瞬间换成对勾（出错时换成红色警告三角形）
- 开始/结束都有和系统计时器一致的过渡动画

### 媒体与任务同时进行

任务（pi / Codex / Claude / DSH）占着收起状态的灵动岛时，正在播放的媒体不会消失，也不会抢主位：它缩成右侧一个小圆圈，圆圈里只有专辑封面，前面用一条 1pt 细线隔开——和手机灵动岛把通话放左边、音乐放右边一个思路。多个 CLI 堆叠时同样只在右侧放**一个**圆圈，纵向居中。

```
( π )  deepseek-v4.1-flash-expires-on-0910  max  99.97%  01:42  │  ●
                                                                    ↑ 专辑封面
```

- 圆圈直径跟随胶囊高度（约 22pt），分割线与两侧各留 8pt；计时列多余的空档会被补偿掉，所以计时到分割线的距离和「命中率→计时」一致
- 显示条件与内置的媒体配对完全一致：媒体活动开着、没有锁屏、没有因为解锁后延迟而隐藏、`hideOnClosed` 为假；没有音乐时这块宽度为 0，布局与之前逐像素相同
- 媒体单独出现（旁边没有任务）时仍是原来的大封面布局

### 2. 展开面板：只显示当前任务 + 用量

鼠标悬停或点击灵动岛展开后（展开尺寸与 Home 一致）：

```
[π] Pi  deepseek-v4.1-…  high  01:42
Running  [bash]  npm run build  ●          ← 只显示正在执行的一个任务
Cache hit 99.97%   Tokens 111K   in / out 12.4K / 830   cached 98K
```

- **只显示"正在执行"的那一个任务**，不列已完成 / 待执行的任务
- 模型思考间隙显示最近一次工具；完全没有工具活动时显示 `No tool activity yet`
- **服务商错误直接显示**：如免费额度用尽会显示红色警告 + `Rate limit exceeded: free-models-per-day…`，而不是让人以为"没在干活"
- 点击展开时保留顶部标签栏（可切回 Home）；悬停展开为沉浸模式（隐藏标签栏）

### 3. 多 CLI 同时运行 → 竖向堆叠 + 展开不再滚动

pi / Codex / Claude / DSH 同时工作时，收起状态**长度不变、只变厚**，每行一个 CLI，命中率列对齐。

展开后呢？面板**按活跃数量撑高**（`计数 × 卡片高度 + 间距`，见 `cliActivityDetailHeight`），并且**每多一个 CLI 就往下长一截**（灵动岛顶边固定在屏幕顶部，只向下扩展）：

| 活跃 CLI | 灵动岛高度 |
|---|---|
| 1 | 218pt |
| 2 | 278pt |
| 3 | 386pt |

- 点击展开时表头（Home / 计时器 / 中转站…）保持可见，面板会主动**让出表头高度**再画卡片，不会互相遮挡
- 面板里没有 `ScrollView`，内容一次显示完，不需要滚动

### 4. 结束音效（pi / Codex / Claude Code）

任一 CLI 任务结束时播放声音（设置 → 媒体 → **Finish Sound**，可关闭）：

| 情况 | 音效 |
|---|---|
| 任务正常结束 | **成功** |
| 模型连接失败 / 连接超时 / 输出失败 / 限流 / 被中断 | **失败** |
| 本轮最后一个工具执行失败（命令非 0 退出、读取失败…） | **失败** |
| 智能体卡在等人确认（权限弹窗、批准对话框、"等待输入"） | **手动确认** |
| DSH 调用 `ask_user_question` 等你回答 | **手动确认** |
| pi 进程直接消失（来不及上报状态） | 不播放 |

音效文件放在 Atoll 自己的目录，不会因为「下载」文件夹被清理而失效：

```
~/Library/Application Support/Atoll/Sounds/
  成功.mp3        成功音
  错误.mp3        失败音（也认 失败.mp3 / error.mp3 / failure.mp3）
  手动确认.mp3    确认音（也认 确认.mp3 / confirm.mp3）
```

```bash
bash scripts/install-sounds.sh            # 从 ~/Downloads 复制并写好设置
bash scripts/install-sounds.sh ~/Desktop  # 或指定目录
```

- 也可以在设置里直接改三个路径，每行有"文件是否存在"提示与试听按钮；留空或文件缺失时回退到系统音（`Glass` / `Basso` / `Ping`）
- 播放使用 `AVAudioPlayer`（不受系统"提醒音量"影响——那个经常是 0）

- 两个音效路径都能在设置里改，带"文件是否存在"提示与试听按钮；留空则回退到系统音（`Glass` / `Basso`）
- "本轮最后一个工具失败"采用**最后一次工具**的成败：pi 先失败后修好并成功，结尾仍是成功音
- 判定来源（三个 CLI 语义一致）：
  - pi：消息 `stopReason: error/aborted` → `error` 字段；`tool_execution_end.isError` → `failed` 字段
  - Claude Code：`PostToolUseFailure` 事件 → `failed`；transcript 里的 `isApiErrorMessage` → `error`
  - Codex：`post_tool_use` 的 `is_error` / `tool_response.exit_code != 0` / `interrupted` → `failed`

### 5. Hook：实时行为检测

会话 JSONL 是缓冲写入的（约 16 KB 才 flush），所以实时数据必须靠 hook 事件。

**pi** — `hooks/pi/atoll-notch-status.ts`（pi 启动时自动加载）

| 事件 | 上报 |
|---|---|
| `agent_start` | busy、重置本轮任务列表 |
| `message_end` | 本轮全部工具调用（含尚未执行的）、token 用量 |
| `tool_execution_start/end` | 当前工具 → running / completed，并记录该工具是否失败（`isError`） |
| `agent_settled` / `session_shutdown` | idle |
| 模型 / 思考等级切换 | 模型、思考程度 |

**DSH（`dst`）** — **不需要 hook**：它的会话文件本身就是数据源。`dst`（`dsh --profile dsh-tui`）把会话写成逐帧追加的 zstd JSONL，监视器只解压尾部若干帧（约 5 ms），读取 `turn/start`·`turn/end`·`tool/call`·`tool/result`·`request/header`·`model/selection`·`assistant/message.usage`·`todo/write`·`llm/retry`，因此同样能给出当前任务、模型、思考等级、命中率与失败判定。

模型与思考等级要特别说明：DSH 只在**切换模型**（`model/selection`）或**每次请求**（`request/header.header.config`）时写一次，长回合里它们会落在尾部窗口之外（本机实测：距文件末尾约 1000 条记录）。所以监视器按三级兜底取值：① 尾部窗口里最新的那条 → ② 本次会话已记住的值（按会话文件缓存，切换会话即失效）→ ③ 首次见到该会话文件时向后深扫一次（2 MB → 8 MB → 32 MB 逐级放大，用 `zstd | grep | tail` 流式过滤，不把窗口展开进内存）；仍未找到就退到 `~/.dsh/settings.yaml` 的 `agent-default-model`。收起状态里模型名会做简写（`deepseek-v4.1-flash-expires-on-0910` → `v4.1-flash`），完整 id 保留在悬停提示与展开面板中。

**Claude Code & Codex** — `hooks/cli/atoll-notch-status.py`（同一个脚本，分别注册在 `~/.claude/settings.json` 与 `~/.codex/hooks.json`；脚本把状态写在**自己所在目录**，所以两份互不干扰）

两个 CLI 的 hook 输入字段一致（`hook_event_name` / `tool_name` / `tool_input` / `tool_response` / `is_error` / `transcript_path`），事件名两种写法都认（`PostToolUse` 与 `post_tool_use`）。

| 事件 | 上报 |
|---|---|
| `SessionStart` / `UserPromptSubmit` | busy、重置任务列表 |
| `PreToolUse` / `PostToolUse` | 当前工具与目标（Read/shell→read/bash、apply_patch→edit、update_plan→todo…） |
| `PostToolUseFailure`（Claude） | 该工具失败 → `failed` |
| `PermissionRequest` / `Notification`（Claude、Codex） | 正在等用户确认 → `confirm` |
| `ui_prompt_start` / `ui_prompt_end`（pi） | 正在等用户确认 → `confirm` |
| `post_tool_use` 的 `is_error` / `exit_code != 0`（Codex） | 该工具失败 → `failed` |
| `Stop` / `SessionEnd` | idle；并检查 transcript 的 `isApiErrorMessage` → `error` |

工具名归一化后写入状态文件，格式与 pi 一致：

```json
{ "busy": true, "since": 1788955540832,
  "tool": { "name": "bash", "target": "npm run build", "pending": true },
  "tasks": [ { "id": "…", "name": "read", "target": "~/.zshrc", "state": "completed" } ],
  "usage": { "input": 88, "output": 90, "cacheRead": 7808 },
  "cacheHitRate": 0.9888,
  "error": "429: {…}",   // 模型/连接/输出失败时才有
  "failed": true,        // 本轮最后一个工具执行失败时才有
  "confirm": "bash rm -rf build" }   // 卡在等用户确认时才有
```

> TodoWrite 会把标记为 `in_progress` 的待办内容当作当前任务显示。

### 6. 全屏隐藏规则：菜单栏被遮挡就隐藏

- 任何窗口**盖住系统菜单栏**（原生全屏、浏览器视频全屏、无边框游戏）→ 自动隐藏灵动岛，退出后恢复
- 普通"最大化"窗口停在菜单栏下方，不会误触发
- 设置 → 媒体 → **Hide DynamicIsland Options** 三种模式：
  - `Hide when any app covers the menu bar`（默认）
  - `Hide only when NowPlaying app is in fullscreen`
  - `Never hide`

---

## 安装

### 构建并安装应用（本机）

```bash
bash scripts/install-local.sh
```

需要 Xcode。使用本机 ad-hoc 签名（不需要 Apple 开发者账号），构建产物安装到 `/Applications/Atoll.app`。

### 安装 hook

```bash
bash scripts/install-pi-hook.sh          # pi：复制到 ~/.pi/agent/extensions/
bash scripts/install-claude-hook.sh      # Claude Code：合并进 ~/.claude/settings.json
bash scripts/install-codex-hook.sh       # Codex：合并进 ~/.codex/hooks.json
bash scripts/install-codex-hook.sh --uninstall
bash scripts/install-sounds.sh           # 把音效文件装到 Atoll 目录
```

三个 CLI 的 hook 都在会话启动时加载，安装后需要新开一个会话（pi 也可以直接 `/reload`）。
合并脚本会**保留你已有的 hook**（例如 Codex 里其他灵动岛应用的条目）。

### 测试

```bash
# hook 契约测试（不消耗模型额度）
node --experimental-strip-types --test hooks/pi/atoll-notch-status.test.mjs
python3 hooks/cli/atoll-notch-status.test.py

# App 单元测试
xcodebuild test -scheme DynamicIsland -destination 'platform=macOS' \
  -only-testing:DynamicIslandTests/PiSessionMonitorTests \
  -only-testing:DynamicIslandTests/DshSessionMonitorTests \
  -only-testing:DynamicIslandTests/CodexSessionMonitorTests \
  -only-testing:DynamicIslandTests/ClaudeSessionMonitorTests
```

---

## 代码结构（新增部分）

```
hooks/
  pi/atoll-notch-status.ts          pi 状态桥接（+ 契约测试）
  cli/atoll-notch-status.py         Claude Code / Codex 共用桥接（+ 契约测试）
scripts/
  install-local.sh                  构建 + 安装到 /Applications
  install-pi-hook.sh                pi hook 安装/卸载
  install-claude-hook.sh            Claude Code hook 安装/卸载
  install-codex-hook.sh             Codex hook 安装/卸载
  install-sounds.sh                 音效文件复制到 Application Support
DynamicIsland/
  managers/PiSessionMonitor.swift       pi 会话监视（状态文件 + JSONL 兜底）
  managers/CodexSessionMonitor.swift    Codex rollout 解析
  managers/ClaudeSessionMonitor.swift   Claude transcript 解析 + hook 状态
  managers/DshSessionMonitor.swift      DSH 会话（zstd JSONL）尾部解析
  managers/CLIActivityDebugLog.swift    诊断日志（默认关闭）
  managers/CLIFinishSound.swift         音效（成功/失败/手动确认，含系统音回退）
  models/CLIUsage.swift                 token 用量 / 命中率（三种 provider 归一化）
  models/CLIToolActivity.swift          当前工具与任务列表
  components/Pi|Codex|Claude|Dsh/       四个 CLI 的收起态活动
  components/CLIActivityDetailView.swift  展开面板
  components/CLIStackActivityView.swift   多 CLI 堆叠（含 DSH）
  observers/FullscreenMediaDetection.swift 菜单栏遮挡检测
```

## 排查问题

打开诊断日志（写入 `~/.pi/agent/atoll-cli-debug.log`）：

```bash
defaults write com.Ebullioscopic.Atoll enableCLIActivityDebugLog -bool true
# 复现问题后查看
cat ~/.pi/agent/atoll-cli-debug.log
defaults write com.Ebullioscopic.Atoll enableCLIActivityDebugLog -bool false
```

日志会记录：hook 是否把工具/任务送达 App、面板当前渲染的那一行、全屏隐藏状态的变化、命中率。

---

## 许可

继承上游 [Atoll](https://github.com/Ebullioscopic/Atoll) 的 **GPL-3.0**（见 `LICENSE` / `NOTICE`）。
