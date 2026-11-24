# dsh-win-notifier

给 **DeepSeek Harness（DSH）桌面端**加一个不打扰的桌面提醒：有待确认的审批、待回答的提问，或者一轮任务结束时，在**屏幕右下角弹出一叠 Nocturne 风格的半透明置顶 toast**——只显示会话标题，**左侧竖条按状态区分颜色**，**没有声音**，点一下就把 DSH 窗口拉到前台。

> Windows toast-free desktop notifications for the DSH desktop app: a stack of Nocturne-style translucent, always-on-top toasts in the bottom-right corner when an approval or question is pending, or a turn ends. Each toast shows only the session title, with a leading colour bar for the state; no sound, and clicking raises the DSH window.

```
┌────────────────────────┐
│ ▎ 待 确 认              │  ← 琥珀色竖条：等你点确认
│   撤销代码块禁用要求     │
└────────────────────────┘
┌────────────────────────┐
│ ▎ 已 完 成              │  ← 绿色竖条：轮次正常结束
│   重构插件市场文档       │
└────────────────────────┘
┌────────────────────────┐
│ ▎ 已 中 断        ×2    │  ← 同状态同标题合并计数
│   长任务                │
└────────────────────────┘
┌────────────────────────┐
│ ▎ 还有 2 条通知         │  ← 超过上限时折叠
└────────────────────────┘
```

> 示意图：单张 toast 高 60 DIP，宽度按内容自适应（172–296 DIP），整叠右边缘对齐。

## 功能

- **只在看不到窗口时提醒**：DSH 窗口已经在前台、你正在看的时候不弹（可配置关闭）。
- **至多 4 张 toast 叠放**：并发事件在 150ms 窗口内合并，同状态同标题折叠成一条并带 `×N`，超出 `maxPopupItems` 的折叠成「还有 N 条通知」。
- **只显示会话标题**：不显示正文、工具名、参数，不担心弹窗把隐私内容亮在屏幕上；标题拿不到时回退为「当前会话」。
- **点击即回到 DSH**：任意一张 toast 点一下，还原并激活 DSH 主窗口，然后整叠消失。
- **不点就留 30 秒**：没人点的 toast 会在桌面上停留 30 秒（`durationMs` 可调）再自己消失，不会一闪就没，也不会一直杵着。
- **失败一定看得见（红）**：和 DSH 前端的失败行对齐——「本轮运行失败」(`error`)、进程在本轮完成前退出 (`interrupted`)、因退出登录被停 (`aborted`) 都归为红色「运行失败」，一眼就和绿色「已完成」区分开。
- **真正的圆角与阴影**：每张 toast 画在 32bpp ARGB 位图上，用 `UpdateLayeredWindow` 推给每像素透明的分层窗口，圆角、投影、toast 之间的间隙都是透的；并且按显示器 DPI 用物理像素渲染（200% 缩放下也清晰）。
- **不挡手**：只有 toast 本体接收点击，toast 之间的透明间隙和四周的投影留白会直接把点击透给下面的窗口。
- **没有声音、不抢焦点**：toast 是 `WS_EX_NOACTIVATE` 的置顶窗体，不会偷走你的输入焦点。
- **子代理轮次默认忽略**：只在你关心的主会话上提醒。

## 环境要求

- **Windows 10 / 11**（卡片由系统自带的 Windows PowerShell 5.1 + WinForms 绘制，无需安装任何依赖）。
- **官方 DSH 桌面端**（`@deepseek-ai/dsh-desktop`）。插件跑在桌面端拉起的 Node 宿主进程里，因此只依赖 DSH 自己的宿主事件，不依赖任何 Electron API。

## 安装

三种方式任选：

1. **插件市场**：在 DSH 的插件面板（dshmarket / Plugins 页）搜索 `dsh-win-notifier`。（需要先收录进 awesome-dsh-plugin 精选列表）
   > 本插件 0.2.3 起由 `dsh-desktop-notifier` 改名而来。市场里可能仍能搜到另一个同名条目 `Mi-liu/dsh-desktop-notifier`、以及 npm 上 `lurejewel` 发布的同名包——两者都与此仓库无关。
2. **命令行**：
   ```sh
   dsh plugin --profile desktop add github:G-duo/dsh-win-notifier
   ```
3. **本地目录**：把本仓库下载到本地，在 Plugins 面板里「添加插件 → 选择本地目录」。

安装后无需重启：插件会立刻生效；如果你是从本地目录安装并改了代码，在插件面板里把它关掉再打开即可重新加载。

## 360 等安全软件的「弹窗拦截」提示

toast 是一个**由 `powershell.exe` 创建的独立置顶窗口**（无边框、不进任务栏），360 安全卫士的「弹窗拦截」会把它识别成弹窗并在每次弹卡时询问「是否过滤」。360 自己的弹窗记录里就是这么记的：

```
path=C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe
winclass=WindowsForms10.Window.8.app.*_r16_ad1
```

360 是按「弹出窗口的程序」记账的，**没有任何第三方可以替使用者的电脑加白**（360 的信任数据在本机、且受自保护），所以这是**每个使用者点一次**的事：

1. **最快**：弹出 360 提示时直接点提示里的「信任该程序 / 不再提醒」。
2. 或者：360 安全卫士 → 功能大全 → **弹窗拦截** → 设置 / 管理 → **信任列表** → 添加程序 → 选 `C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe`。
3. 若 360 的「木马查杀 / 防护中心」也报警，在 **信任区** 里同样添加该路径。

> 第 2 步等于信任**所有** PowerShell 弹窗；只想放过本插件就用第 1 步。分发本插件时，请把这一节一并告知使用者。

## 配置

配置写在插件清单 `cordis.patch.yml` 的 `config` 里（在插件面板或 profile 里改），全部有默认值：

| 字段 | 默认值 | 说明 |
| --- | --- | --- |
| `durationMs` | `30000` | 没人点击时 toast 停留毫秒数（30 秒） |
| `suppressWhenFocused` | `true` | DSH 窗口在前台时不弹 |
| `mergeWindowMs` | `150` | 并发事件合并窗口 |
| `maxPopupItems` | `4` | 最多几张 toast，多出的折叠为「还有 N 条通知」 |
| `notifyApprovals` | `true` | 待确认审批是否提醒 |
| `notifyQuestions` | `true` | 待回答提问是否提醒 |
| `notifyTurnEnd` | `true` | 轮次结束是否提醒 |
| `skipSubagentTurns` | `true` | 忽略子代理会话的轮次结束 |
| `accentPending` | `#F0B429` | 待确认颜色（琥珀） |
| `accentDone` | `#2FBF71` | 完成颜色（绿） |
| `accentInterrupted` | `#2FBF71` | 中断颜色（绿，按用户习惯与完成同色） |
| `accentBlocked` | `#FF8A3D` | 被阻断颜色（橙） |
| `accentFailed` | `#E5484D` | 「运行失败」颜色（红）：出错、进程中止、退出登录 |
| `accentUnknown` | `#8B8F98` | 无法识别的结局「已结束」颜色（灰） |
| `debug` | `false` | 往 `notifier-debug.log` 写调试日志 |

颜色写法是 `#RRGGBB`；中断想单独用别的颜色，把 `accentInterrupted` 改掉即可。（`accentError` 是 `accentFailed` 从前的名字，写了仍然认。）

## 工作原理

- `index.js` 是 Host 插件，用 `ctx.effect` 注册三个监听：
  - `approval/request`（waterfall）→ 有待确认的审批；
  - `user-questions/request`（waterfall）→ 有待回答的提问；
  - `session/event` 里的 `turn/end` → 轮次结束，用 `event.data.reason.kind` 区分完成 / 已中断 / 阻断 / 运行失败 / 达到输出上限；其中「运行失败」这一档与 DSH 前端的失败行一一对应（`error`、进程中途退出的 `interrupted`、退出登录导致的 `aborted`），都用红色。
  - 两个 waterfall 监听器结尾都会 `return next()`，把决定权原样交还给 DSH 原本的应答者，不改变任何审批结果。
- 会话标题来自 `session/title` 事件（本地缓存）＋ `ctx.get('sessionTitle')` 作为兜底，拿不到就用「当前会话」。
- 卡片由一个**常驻的 PowerShell 助手进程**绘制（`helper/notify.ps1`）。它先把自己声明为 per-monitor DPI aware，再按 `DpiX / 96` 缩放每一条设计尺寸；每张 toast 都画在 ARGB 位图上（暗紫渐变玻璃、1px 白→紫渐变描边、内缘顶部高光发丝线、按状态着色的 3px 前部竖条、柔和投影），宽度按标题长度自适应，再通过 `UpdateLayeredWindow` 交给每像素透明的 `WS_EX_LAYERED` 窗口。助手用 `PeekNamedPipe` 非阻塞地探 stdin（没消息时不占着消息循环，计时、重绘、点击都照常），插件只在第一次需要时启动它，之后通过 stdin 传一行 JSON；助手退出时插件会回收进程。DSH 没有给插件任何系统通知或置顶窗口的接口，所以弹窗必须由外部进程完成——这是这个插件的存在理由。

## 已知限制

- 置顶卡片**盖不过独占全屏的游戏/视频**和其他置顶窗口；它只保证在普通桌面上浮在最前。
- 助手进程是插件自己拉起的，因此**不受 DSH 工具沙箱约束**；它只做两件事：读 stdin 的一行 JSON、画 toast/激活窗口。
- 安装插件会影响**整个 profile**（所有会话），这是 DSH 插件的既有行为。
- 只监听「待确认 / 待回答 / 轮次结束」三类事件，不会替 DSH 做任何决定。
- 玻璃底色是固定的暗色（约 88%–94% 不透明），不会像 Nocturne 那样按壁纸明暗自动调 tone；在纯白文档上依然保证可读。
- **360 等安全软件的「弹窗拦截」会把它当弹窗询问**：toast 由 `powershell.exe` 创建，360 按程序记账、无法由插件自带白名单；见上文「360 等安全软件的「弹窗拦截」提示」一节。
- 目前只支持 Windows。

## 自检

不想等真实事件，可以直接验证 toast 渲染与「点击拉起窗口」这条链路：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File helper\notify.ps1 -SelfTest
```

它会弹一叠假 toast（待确认 / 已完成 / `×2` 合并 / **运行失败（红）** / 「还有 N 条通知」五种形态），约 4 秒后模拟点击把 DSH 窗口拉到前台，并在 `helper/` 下留下三份可查的产物：

- `notify-toast-layer.png`：推送给分层窗口的原始 ARGB 位图；
- `notify-selftest-shot.png`：从屏幕上原样截下的 toast 区域（带桌面背景，可检查圆角与投影）；
- `selftest.log`（`-LogFile` 可改）：尺寸、DPI、命中测试、采样像素的实测记录。

## 卸载

在插件面板里移除即可，助手进程随之退出。

## 许可

[MIT](LICENSE)。使用前请自行评估：该插件会在你的桌面上显示会话标题，并会启动一个 PowerShell 子进程。
