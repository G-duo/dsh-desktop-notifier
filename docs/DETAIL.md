# 桌面通知（dsh-win-notifier）

有待确认 / 待回答的请求，或者一轮任务结束时，在屏幕右下角弹出**一叠半透明深色、置顶、无声音的 Nocturne 风格 toast**；每张 toast **只显示会话标题**，左侧一条 3px 竖条按状态渐变着色，点一下就把 DSH 窗口拉到前台。

## 触发时机

| 来源 | 钩子 | 卡片状态字 | 默认颜色 |
| --- | --- | --- | --- |
| 工具调用等待确认 | `approval/request` | 待确认 | 黄 `#F0B429` |
| 提问等待回答 | `user-questions/request` | 待回答 | 黄 `#F0B429` |
| 一轮正常结束 | `session/event` → `turn/end`（`completed`） | 已完成 | 绿 `#2FBF71` |
| 一轮被用户 / 父级取消 | `turn/end`（`aborted`，原因不是退出登录） | 已中断 | 绿 `#2FBF71`（可改成红） |
| 一轮被阻断 | `turn/end`（`blocked`） | 已阻断 | 橙 `#FF8A3D` |
| 一轮运行失败 | `turn/end`（`error`，即 DSH 画「本轮运行失败」那种） | 运行失败 | 红 `#E5484D` |
| 一轮被进程中止 | `turn/end`（`interrupted`，进程在本轮完成前退出） | 运行失败 | 红 `#E5484D` |
| 一轮因退出登录而停 | `turn/end`（`aborted` + `deepseek-account/signed-out`） | 运行失败 | 红 `#E5484D` |
| 输出达到上限 | `turn/end`（`max-tokens`） | 已达输出上限 | 黄 `#F0B429` |
| 其它（未知结局） | `turn/end`（无法识别的原因） | 已结束 | 灰 `#8B8F98` |

> 「运行失败」这一档严格对齐 DSH 自己的失败行：客户端 `turn-error.ts` 只为 `error`、`interrupted`、「退出登录导致的 aborted」三种结局画失败行（`locale.ts` 里那句 `本轮运行失败` 对应 `error`），所以这三种都用红色。用户自己按停止键的 `aborted` 仍然是绿色「已中断」。

## 卡片行为

- 布局：主屏工作区**右下角**，距边缘 18 DIP；每张 toast 高 60 DIP、圆角 14 DIP、间距 8 DIP，宽度**按内容自适应**（最宽一行决定整叠宽度，172–296 DIP，超过 296 就出省略号），自下而上叠放、右边缘对齐。
- 外观：暗紫玻璃渐变（`rgba(20,16,29,0.886)` → `rgba(8,6,14,0.941)`），1 DIP 白→紫渐变描边，紧贴内缘还有 1 DIP 顶部高光发丝线，3 DIP 前部竖条按状态做「同色相亮→暗」渐变，10 层黑色圆角矩形叠出柔和投影；整张位图经 `UpdateLayeredWindow` 推到每像素透明的分层窗口，因此圆角、投影和 toast 之间的间隙都能透出桌面。
- 排版：上排是逐字加空格的状态字（9.6 DIP 灰紫粗体），下排是会话标题（13.6 DIP 白，过长自动省略号）；文字块上下留白各约 15.5 DIP，视觉居中；右上角 `×N` 表示合并条数；「还有 N 条通知」折叠行只显示一行灰字，竖条为灰色。
- DPI：助手启动时先 `SetProcessDpiAwarenessContext(PER_MONITOR_AWARE_V2)`，再按 `DpiX / 96` 缩放全部设计尺寸（200% 缩放下 toast 是 356×120 物理像素），文字用 `GraphicsUnit.Pixel` 并按 scale 放大，避免系统二次拉伸导致发虚。
- 合并：同一时刻的多个事件在 150ms 窗口内合成一次请求；同一叠内「相同状态 + 相同标题」的 toast 会合并并标 `×N`；超过 `maxPopupItems` 张时折叠成一张「还有 N 条通知」。
- 打扰控制：`suppressWhenFocused: true` 时，如果 DSH 窗口正在前台（你正看着它），**不弹**；整叠已经显示时，新事件直接并进当前叠，而不是再弹一叠。
- 无声音：不播放任何提示音。
- 点击：任意一张 toast 点一下即把 DSH 窗口激活到前台（已最小化会先还原；被其他前台窗口占着时会用 `AttachThreadInput` 兜底），整叠随后隐藏。toast 之间的透明间隙和四周的投影留白不挡鼠标——窗口在 `WM_NCHITTEST` 里对这些点回 `HTTRANSPARENT`，点击直接落到下面的窗口。
- 停留：没人点击时 `durationMs`（默认 **30 秒**）后自动消失；鼠标不需要移上去，点了就立刻走「点击」那条链路提前收掉整叠。

## 实现方式

插件本体是一个 **Host 插件**（`index.js`，ESM，导出 `apply(ctx, config)`），它只做两件事：监听上面那些钩子，把「要显示什么」写成一整行 JSON 通过 stdin 交给助手进程。

画卡片的是包内的 **常驻 PowerShell 助手** `helper/notify.ps1`：Windows PowerShell 5.1 + WinForms + 少量 P/Invoke（`user32`、`gdi32`、`kernel32`），一个进程只启动一次，之后一直等 stdin 的下一行，因此每次弹卡没有冷启动延迟。助手内的计时器跑在 WinForms 消息循环上，所以读 stdin 必须**非阻塞**——它用 `PeekNamedPipe` 先探「有没有可读的数据」再决定要不要读，否则没有新消息时会把消息循环堵死，计时器、重绘和点击响应会一起停摆（管道被写端关闭时则干净退出）。助手内嵌的 C# `ToastLayerForm : Form` 负责渲染：在 32bpp ARGB 位图上画完 shadow / 玻璃 / 描边 / 竖条 / 文字后，用 `GetDC` + `CreateCompatibleDC` + `SelectObject` 把位图交给 `UpdateLayeredWindow(ULW_ALPHA)`，窗口本身带 `WS_EX_LAYERED | WS_EX_NOACTIVATE`，所以既支持逐像素透明，又不会抢焦点；`WM_NCHITTEST` 只把画了 toast 的矩形算作客户区，其余透明区域返回 `HTTRANSPARENT`。

之所以要单独起一个进程：DSH 桌面版是用 `ELECTRON_RUN_AS_NODE=1` 把宿主当普通 Node 子进程拉起来的，插件里拿不到 Electron API，DSH 也没有给插件暴露系统通知 / 置顶窗口的接口。

## 配置

在插件行的 `config` 里改（配置文件是插件包的 `cordis.patch.yml`，重新安装或重启 DSH 后生效）。全部字段都有默认值：

| 字段 | 默认值 | 说明 |
| --- | --- | --- |
| `durationMs` | `30000` | 没人点击时 toast 停留毫秒数 |
| `suppressWhenFocused` | `true` | DSH 窗口在前台时不弹 |
| `mergeWindowMs` | `150` | 合并同一时刻多个事件的等待窗口 |
| `notifyApprovals` | `true` | 待确认提醒 |
| `notifyQuestions` | `true` | 待回答提醒 |
| `notifyTurnEnd` | `true` | 任务结束提醒 |
| `skipSubagentTurns` | `true` | 子代理的轮次结束不提醒 |
| `maxPopupItems` | `4` | 最多几张 toast，多出的折叠成「还有 N 条通知」 |
| `accentPending` | `#F0B429` | 待确认 / 待回答 / 输出上限的颜色 |
| `accentDone` | `#2FBF71` | 完成的颜色 |
| `accentInterrupted` | `#2FBF71` | 中断的颜色（想跟"完成"区分开就写 `#E5484D`） |
| `accentBlocked` | `#FF8A3D` | 阻断的颜色 |
| `accentFailed` | `#E5484D` | 「运行失败」（出错 / 进程中止 / 退出登录）的颜色 |
| `accentUnknown` | `#8B8F98` | 无法识别的结局「已结束」的颜色 |
| `accentError` | — | `accentFailed` 的旧名字，仍然被识别（两个都写时以 `accentFailed` 为准） |
| `debug` | `false` | 打开后往插件目录写 `notifier-debug.log`（超过 256 KiB 自动清空） |

## 已知限制

- **压不过独占全屏**：全屏游戏、播放器，或同样是置顶且更晚创建的窗口，可能盖住 toast。这是 Windows 置顶窗口的正常行为，不是本插件能绕过的。
- **只在 Windows + Windows PowerShell 下工作**：助手用 `System.Windows.Forms` 画窗口；非 Windows 平台不会弹卡（插件本身不报错，只是静默不发）。
- **只认桌面版窗口**：点击拉起靠的是标题里含 `DeepSeek Harness` 的窗口（优先用 DSH 主进程 pid 精确匹配）。如果你用浏览器打开 Web GUI，toast 仍会弹，但点击拉起的不是浏览器窗口。
- **只显示会话标题**：这是刻意取舍（防止在锁屏/投屏时泄露正文），因此 toast 不告诉你具体在等什么工具。
- **安装影响整个 profile**：插件对所有会话生效；安装/启用在 Plugins 面板确认即可，实测**不需要重启 DSH**（改完代码后把插件关掉再打开就会重新加载）。
- **子代理 / 后台任务**：默认不提醒子代理的轮次结束（`skipSubagentTurns`），因为一次主任务会顺带结束很多子代理轮次。
- **助手是插件自己拉起的进程**：它不受工具沙箱约束（沙箱管的是模型调用的命令），因此首次弹卡时你可能会看到 PowerShell 进程一闪而过（默认隐藏窗口）。
- **360「弹窗拦截」会拦这个 toast**：toast 是 `powershell.exe` 创建的独立置顶无边框窗口，360 按「弹出窗口的程序」记账（记录形如 `path=...\powershell.exe`、`winclass=WindowsForms10.Window.8.app.*_r16_ad1`），因此每次弹卡都可能问「是否过滤」；第三方无法替使用者加白，需使用者点一次「信任该程序」，或在 弹窗拦截 → 信任列表 添加 `C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe`（详见 README）。
- **玻璃底色固定**：不像 Nocturne 那样按壁纸明暗自适应调节透明度，浅色文档上会显得更实一些，换取可读性。

## 自检与验证

不依赖真实事件，可以手动跑一次自检：它会弹出 4 张假 toast（含 `×2` 合并与「还有 N 条通知」折叠形态），约 4 秒后模拟点击把 DSH 窗口拉到前台，并在 `helper/` 下留下 `notify-toast-layer.png`（推送的原始 ARGB 位图）、`notify-selftest-shot.png`（屏幕上截下的 toast 区域）和 `selftest.log`（尺寸 / DPI / 命中测试 / 像素采样）：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File helper\notify.ps1 -SelfTest
```

排查问题时把 `debug` 设为 `true`，`notifier-debug.log` 里会记录每次钩子收到的会话、原因和最终发给助手的 JSON。

## 卸载

在 Plugins（插件管理）面板里把 `dsh-win-notifier` 移除即可；助手进程随插件停用一起退出，不残留后台进程。

## 实测记录

仓库作者在 Windows 11 + DSH 桌面版 0.2.2-rc.5 上实测通过的部分：轮次结束 toast 的弹出与自动消失、会话标题解析（含子代理会话标题）、子代理轮次过滤、点击 toast 把 DSH 窗口拉到前台、多事件合并与「还有 N 条通知」溢出、助手进程干净退出；渲染侧在 2880×1800 / 200% 缩放的屏幕上验证过逐像素透明、圆角、投影与 `×2` 徽标（一次喂 5 条通知 → 3 张实卡 + 1 张折叠卡，窗口 436×608 物理像素、单卡 356×120 物理像素，文字块上下留白各 15.5 DIP，右下角 40px 物理边距）。

尚未观测到的部分：**真实的审批/提问瀑布**没有在作者的环境里触发过（本机审批被系统策略放行或被禁用），所以「待确认 / 待回答」两张黄卡的接线是照着 `dsh-user-approval`、`dsh-user-questions` 的源码写的，但还没有真实事件跑过。欢迎提 issue 反馈。
