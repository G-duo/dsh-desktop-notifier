# Changelog

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
