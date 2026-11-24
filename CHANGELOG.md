# Changelog

## 0.2.3 — 2026-11-24

改名，为了和别人的同名插件区分开。

- 包名从 `dsh-desktop-notifier` 改为 **`dsh-win-notifier`**，仓库同步改名为 `G-duo/dsh-win-notifier`。
- 原因：`dsh-desktop-notifier` 这个名字在 npm 上已被 `lurejewel` 占用，在 DSH 插件市场（awesome-dsh-plugin 索引，按包名匹配）里也已有 `Mi-liu` 的同名条目，市场卡片会顶着别人的署名。换个不重名的名字之后，市场搜索才是唯一命中。
- `package.json` 的 `name` / `repository` / `homepage` / `bugs`、`cordis.patch.yml` 的条目 id、`index.js` 的模块注释、README 与 docs 里的链接全部同步更新。
- 功能没有任何改动。

## 0.2.2 — 2026-11-23

「运行失败」也进提醒列表，用红色。

- 新增「运行失败」这一档（红 `#E5484D`）：`turn/end` 的 `error`（就是 DSH 前端写「本轮运行失败」的那种）、`interrupted`（DSH 进程在本轮完成前退出）、以及被 `deepseek-account/signed-out` 钩子停掉的 `aborted`，三种都算失败。
- 前两种以前分别是「出错」和绿色「已中断」——后者在 DSH 里本来就会画一条失败行，用绿色是错的，这次一并纠正过来。
- 用户自己按停止键取消的 `aborted` 仍然是绿色「已中断」，没有改动。
- 无法识别的结局不再假装「已完成」，改为中性灰的「已结束」（`accentUnknown`）。
- 配置项 `accentError` 更名为 `accentFailed`；旧名字仍然被识别（两个都写时以 `accentFailed` 为准）。

## 0.2.1 — 2026-11-23

没人点击时多留一会儿。

- `durationMs` 默认从 5 秒改为 **30 秒**：toast 弹出后如果没人点，就一直待在桌面上，30 秒后自己消失；点了仍然立刻把 DSH 窗口拉到前台并收掉整叠。
- 助手进程的兜底值（收到消息里没带 `durationMs` 时）同步改为 30 秒。
- **修复：stdin 空闲时整个助手会卡住。** 原来用 `StreamReader.EndOfStream` 读 stdin——没有新消息时它会**阻塞** UI 线程，于是计时器、重绘、点击响应全部停摆：toast 只有在收到下一条消息（或管道关闭）时才会更新，「到点自己消失」「鼠标点一下」这些行为实际都不生效。现在改用 `PeekNamedPipe` 非阻塞探测，有数据才读；管道被写端关闭时干净退出（日志 `stdin closed: shutting down`）。实测：一条不点它的通知在屏幕上停留 29.9 秒后自行消失。

## 0.2.0 — 2026-11-23

改成 Nocturne 风格的 toast 叠层。

- 视觉重做：每张通知是一张玻璃 toast——暗紫渐变底、1px 白→紫渐变描边、内缘顶部高光发丝线、14 DIP 圆角、柔和投影；左侧 3px 竖条按状态做同色相亮→暗渐变，右上角 `×N` 合并徽标。
- 尺寸收敛：高度 60 DIP、间距 8 DIP，宽度按内容自适应（172–296 DIP，超长标题出省略号，整叠右边缘对齐），不再是一张固定宽度的大卡片。
- 排版改为两行：上排逐字加空格的状态字（小号灰紫），下排会话标题（白，超长省略）。
- 渲染方式从「一张带 Region 的 GDI 卡片」换成 32bpp ARGB 位图 + `UpdateLayeredWindow` 的逐像素透明分层窗口：圆角、投影、toast 间隙都真正透明。
- 声明 per-monitor DPI 感知并按 `DpiX / 96` 缩放：200% 缩放下不再被系统二次拉伸发虚。
- 一次最多叠 `maxPopupItems` 张 toast，超出折叠为「还有 N 条通知」；合并、点击激活、前台抑制、自动消失等行为不变。
- 自检产物更新为 `notify-toast-layer.png` / `notify-selftest-shot.png` / `selftest.log`。
- toast 之间的透明间隙与四周投影留白不再挡鼠标：`WM_NCHITTEST` 对非 toast 区域返回 `HTTRANSPARENT`，点击直接落到下面的窗口。

## 0.1.0 — 2026-11-23

首个版本。

- Host 插件监听 `approval/request`、`user-questions/request` 与 `session/event` 的 `turn/end`，把「待确认 / 待回答 / 轮次结束」变成一条不打扰的桌面提醒。
- 常驻 PowerShell 助手绘制右下角半透明置顶卡片：只显示会话标题、按状态配色、无声音、不抢焦点、可合并多条、点击激活 DSH 窗口。
- 会话标题解析：`session/title` 事件缓存 + `ctx.get('sessionTitle')` 兜底。
- 可配置提醒时机（窗口在前台时不弹）、合并窗口、停留时长、各状态配色、是否提醒子代理轮次。
- `helper/notify.ps1 -SelfTest` 自检模式，可独立验证卡片渲染与窗口激活链路。
