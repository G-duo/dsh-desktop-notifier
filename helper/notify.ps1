<#
  DSH desktop notifier helper (resident).

  Reads one JSON object per line from stdin and keeps a bottom-right stack of
  always-on-top Nocturne-style toasts in sync with that state:

    { "t": "pending", "items": [ {label, accent, title, count} ], "maxItems": 4, "shellPid": 15024 }
        Sticky rows: they stay until the next "pending" message (an empty
        items list clears them). Used for prompts that need a human.

    { "t": "events", "items": [ ... ], "durationMs": 5000, "suppressWhenFocused": true,
      "maxItems": 4, "shellPid": 15024 }
        One-shot rows that expire after durationMs.

  Each toast is drawn on a 32bpp ARGB surface and pushed to a per-pixel
  WS_EX_LAYERED window with UpdateLayeredWindow, so the rounded glass edges,
  the drop shadow and the gaps between toasts are truly translucent. The 3px
  vertical bar at the leading edge carries the row accent, which is what tells
  the notification kinds apart.

  The stack is visible only while it has rows and, when suppressWhenFocused is
  true, only while the DSH window is NOT the foreground window. Visibility is
  re-derived on every tick, so a stack suppressed earlier appears by itself as
  soon as the user looks away.

  Clicking anywhere on a toast raises the DSH window and snoozes the stack.

  Usage: powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File notify.ps1
         powershell.exe ... -File notify.ps1 -SelfTest [-Shot <png>]
#>
param(
  [switch]$SelfTest,
  [string]$LogFile = '',
  [string]$Shot = '',
  [int]$TickMs = 200
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Render at native pixels: the toast is a per-pixel layered window, so become
# per-monitor DPI aware before any Form or Screen call and scale every design
# metric by the real monitor DPI (200% here -> 320 DIP is 640 px).
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class DpiFix {
    [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr ctx);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
}
'@
$null = [DpiFix]::SetProcessDpiAwarenessContext([IntPtr](-4))

$HelperDir = $PSScriptRoot
if (-not $LogFile) { $LogFile = Join-Path $HelperDir 'notify-run.log' }
$script:LogPath = $LogFile

function Write-Log([string]$Message) {
  try {
    $item = Get-Item -LiteralPath $script:LogPath -ErrorAction SilentlyContinue
    if ($item -and $item.Length -gt 262144) { Set-Content -LiteralPath $script:LogPath -Value '' -Encoding UTF8 }
  } catch { }
  try {
    $stamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
    Add-Content -LiteralPath $script:LogPath -Value ('{0} {1}' -f $stamp, $Message) -Encoding UTF8
  } catch { }
}

$csharp = @'
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Text;
using System.Text;
using System.Windows.Forms;
using System.Runtime.InteropServices;

public static class DshWin
{
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }

    private delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern bool EnumWindows(EnumProc callback, IntPtr lParam);
    [DllImport("user32.dll")]
    private static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")]
    private static extern IntPtr GetWindow(IntPtr hWnd, uint cmd);
    [DllImport("user32.dll")]
    private static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int count);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetClassName(IntPtr hWnd, StringBuilder text, int count);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetWindowLong(IntPtr hWnd, int index);
    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")]
    private static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")]
    private static extern bool ShowWindow(IntPtr hWnd, int cmd);
    [DllImport("user32.dll")]
    private static extern bool IsIconic(IntPtr hWnd);
    [DllImport("user32.dll")]
    private static extern IntPtr SetActiveWindow(IntPtr hWnd);
    [DllImport("user32.dll")]
    private static extern bool AttachThreadInput(uint attach, uint attachTo, bool join);
    [DllImport("user32.dll")]
    private static extern bool SetWindowPos(IntPtr hWnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")]
    private static extern IntPtr WindowFromPoint(POINT point);
    [DllImport("user32.dll")]
    private static extern IntPtr SendMessage(IntPtr hWnd, int msg, IntPtr wParam, IntPtr lParam);
    [DllImport("kernel32.dll")]
    private static extern uint GetCurrentThreadId();

    [StructLayout(LayoutKind.Sequential)]
    public struct POINT { public int X; public int Y; }

    private const uint GW_OWNER = 4;
    private const int GWL_EXSTYLE = -20;
    private const int WS_EX_TOOLWINDOW = 0x00000080;
    private const int SW_SHOW = 5;
    private const int SW_RESTORE = 9;

    public static string TextOf(IntPtr hWnd)
    {
        StringBuilder buffer = new StringBuilder(512);
        GetWindowText(hWnd, buffer, buffer.Capacity);
        return buffer.ToString();
    }

    public static string ClassOf(IntPtr hWnd)
    {
        StringBuilder buffer = new StringBuilder(256);
        GetClassName(hWnd, buffer, buffer.Capacity);
        return buffer.ToString();
    }

    public static uint PidOf(IntPtr hWnd)
    {
        uint pid;
        GetWindowThreadProcessId(hWnd, out pid);
        return pid;
    }

    public static uint ForegroundPid()
    {
        return PidOf(GetForegroundWindow());
    }

    /// <summary>Put a window at the top of the topmost band without stealing focus.</summary>
    public static void Raise(IntPtr hWnd)
    {
        if (hWnd == IntPtr.Zero) return;
        // HWND_TOPMOST, SWP_NOSIZE | SWP_NOMOVE | SWP_NOACTIVATE | SWP_SHOWWINDOW
        SetWindowPos(hWnd, new IntPtr(-1), 0, 0, 0, 0, 0x0001 | 0x0002 | 0x0010 | 0x0040);
    }

    public static IntPtr WindowAt(int x, int y)
    {
        POINT point;
        point.X = x;
        point.Y = y;
        return WindowFromPoint(point);
    }

    /// <summary>Ask a window where a screen point lands (WM_NCHITTEST). -1 means pass-through.</summary>
    public static int HitTest(IntPtr hWnd, int screenX, int screenY)
    {
        if (hWnd == IntPtr.Zero) return 0;
        long packed = ((long)(screenY & 0xFFFF) << 16) | (uint)(screenX & 0xFFFF);
        return (int)SendMessage(hWnd, 0x0084, IntPtr.Zero, new IntPtr(packed));
    }

    public static string Describe(IntPtr hWnd)
    {
        return ClassOf(hWnd) + " | " + TextOf(hWnd) + " | pid=" + PidOf(hWnd);
    }

    /// <summary>Main window of a process (pid first), else a Chromium-style host window whose title matches.</summary>
    public static IntPtr Find(int shellPid, string titleHint)
    {
        IntPtr byPid = IntPtr.Zero;
        IntPtr byTitle = IntPtr.Zero;
        EnumProc proc = delegate(IntPtr hWnd, IntPtr lParam)
        {
            if (!IsWindowVisible(hWnd)) return true;
            if (GetWindow(hWnd, GW_OWNER) != IntPtr.Zero) return true;
            if ((GetWindowLong(hWnd, GWL_EXSTYLE) & WS_EX_TOOLWINDOW) != 0) return true;
            RECT rect;
            if (!GetWindowRect(hWnd, out rect)) return true;
            // A minimized window reports off-screen placeholder bounds, so only
            // size-filter windows that are actually restored on the desktop.
            if (!IsIconic(hWnd) && (rect.Right - rect.Left < 400 || rect.Bottom - rect.Top < 300)) return true;
            uint pid = PidOf(hWnd);
            string title = TextOf(hWnd);
            string cls = ClassOf(hWnd);
            bool chrome = cls.StartsWith("Chrome_WidgetWin", StringComparison.Ordinal);
            bool titleHit = titleHint.Length > 0 && title.IndexOf(titleHint, StringComparison.OrdinalIgnoreCase) >= 0;
            if (shellPid > 0 && (int)pid == shellPid && (chrome || titleHit))
            {
                byPid = hWnd;
                return false;
            }
            if (byTitle == IntPtr.Zero && titleHit && chrome) byTitle = hWnd;
            return true;
        };
        EnumWindows(proc, IntPtr.Zero);
        return byPid != IntPtr.Zero ? byPid : byTitle;
    }

    public static bool Activate(IntPtr hWnd)
    {
        if (hWnd == IntPtr.Zero) return false;
        if (IsIconic(hWnd)) ShowWindow(hWnd, SW_RESTORE);
        ShowWindow(hWnd, SW_SHOW);
        SetForegroundWindow(hWnd);
        if (GetForegroundWindow() == hWnd) return true;
        uint unused;
        uint foregroundThread = GetWindowThreadProcessId(GetForegroundWindow(), out unused);
        uint current = GetCurrentThreadId();
        bool attached = AttachThreadInput(current, foregroundThread, true);
        try
        {
            SetForegroundWindow(hWnd);
            SetActiveWindow(hWnd);
        }
        finally
        {
            if (attached) AttachThreadInput(current, foregroundThread, false);
        }
        return GetForegroundWindow() == hWnd;
    }
}

public sealed class NotifyRow
{
    public string Label = "";
    public string Title = "";
    public Color Accent = Color.Silver;
    public int Count = 1;
}

public sealed class ToastLayerForm : Form
{
    [StructLayout(LayoutKind.Sequential)] private struct POINT { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)] private struct SIZE { public int cx, cy; }
    [StructLayout(LayoutKind.Sequential, Pack = 1)]
    private struct BLENDFUNCTION { public byte BlendOp, BlendFlags, SourceConstantAlpha, AlphaFormat; }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool UpdateLayeredWindow(IntPtr hwnd, IntPtr hdcDst, ref POINT pptDst, ref SIZE psize,
        IntPtr hdcSrc, ref POINT pptSrc, int crKey, ref BLENDFUNCTION pblend, int dwFlags);
    [DllImport("user32.dll")] private static extern IntPtr GetDC(IntPtr hWnd);
    [DllImport("user32.dll")] private static extern int ReleaseDC(IntPtr hWnd, IntPtr hDC);
    [DllImport("gdi32.dll")] private static extern IntPtr CreateCompatibleDC(IntPtr hDC);
    [DllImport("gdi32.dll")] private static extern bool DeleteDC(IntPtr hdc);
    [DllImport("gdi32.dll")] private static extern IntPtr SelectObject(IntPtr hDC, IntPtr hObject);
    [DllImport("gdi32.dll")] private static extern bool DeleteObject(IntPtr hObject);

    // ---- Nocturne-style toast metrics, in DIP (scaled by S at paint time) ----
    // The card width is measured from its content and clamped, so a short title
    // gets a small pill instead of a wide card with an empty right half.
    public const int MinCardW = 172;
    public const int MaxCardW = 296;
    public const int CardH = 60;
    public const int Gap = 8;
    public const int Pad = 20;      // transparent margin that holds the drop shadow
    public const int Radius = 14;
    private const int BarX = 8;
    private const int BarW = 3;
    private const int BarTop = 11;
    private const int TextX = 20;
    private const int TextRightPad = 13;
    private const int LabelY = 14;
    private const int TitleY = 29;
    private const float LabelPt = 9.6f;
    private const float TitlePt = 13.6f;
    private const float CountPt = 10.6f;

    private static readonly Color BgTop = Color.FromArgb(226, 20, 16, 29);
    private static readonly Color BgBottom = Color.FromArgb(240, 8, 6, 14);
    private static readonly Color LabelCol = Color.FromArgb(158, 198, 194, 210);
    private static readonly Color TitleCol = Color.FromArgb(246, 244, 241, 250);
    private static readonly Color CountCol = Color.FromArgb(142, 190, 186, 200);
    private static readonly FontFamily Ui = new FontFamily("Microsoft YaHei UI");

    private NotifyRow[] rows = new NotifyRow[0];
    private int cardWpx;
    public Action onPick;
    public float S = 1f;

    public ToastLayerForm()
    {
        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar = false;
        StartPosition = FormStartPosition.Manual;
        TopMost = true;
        AutoScaleMode = AutoScaleMode.None;
        DoubleBuffered = true;
        SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.UserPaint, true);
    }

    protected override bool ShowWithoutActivation { get { return true; } }

    protected override CreateParams CreateParams
    {
        get
        {
            CreateParams cp = base.CreateParams;
            cp.ExStyle |= 0x00080000;    // WS_EX_LAYERED (per-pixel alpha)
            cp.ExStyle |= 0x08000000;    // WS_EX_NOACTIVATE
            return cp;
        }
    }

    public int RowCount { get { return rows.Length; } }
    public int PadPx { get { return Px(Pad); } }
    public int CardPx { get { return cardWpx > 0 ? cardWpx : Px(MinCardW); } }
    public int CardPxH { get { return Px(CardH); } }

    private int Px(float dip) { return (int)Math.Round(dip * S); }
    private float PxPt(float dip) { return dip * S; }

    public void SetRows(NotifyRow[] next)
    {
        rows = next == null ? new NotifyRow[0] : next;
        cardWpx = MeasureCardWidth();
        int count = rows.Length < 1 ? 1 : rows.Length;
        ClientSize = new Size(cardWpx + Px(Pad) * 2, count * Px(CardH) + (count - 1) * Px(Gap) + Px(Pad) * 2);
    }

    /// <summary>Card width = widest row, clamped. Every card in the stack shares it
    /// so the right edges line up.</summary>
    private int MeasureCardWidth()
    {
        int widest = 0;
        using (Bitmap probe = new Bitmap(1, 1))
        using (Graphics g = Graphics.FromImage(probe))
        using (Font labelFont = new Font(Ui, PxPt(LabelPt), FontStyle.Bold, GraphicsUnit.Pixel))
        using (Font titleFont = new Font(Ui, PxPt(TitlePt), FontStyle.Regular, GraphicsUnit.Pixel))
        using (Font countFont = new Font(Ui, PxPt(CountPt), FontStyle.Regular, GraphicsUnit.Pixel))
        {
            foreach (NotifyRow row in rows)
            {
                int need = Px(TextX) + Px(TextRightPad);
                if (row.Title != null && row.Title.Length > 0)
                {
                    need += (int)Math.Ceiling(g.MeasureString(row.Title, titleFont, new PointF(0, 0), StringFormat.GenericTypographic).Width);
                    if (row.Count > 1)
                        need += (int)Math.Ceiling(g.MeasureString("\u00D7" + row.Count, countFont, new PointF(0, 0), StringFormat.GenericTypographic).Width) + Px(8);
                }
                else
                {
                    need += (int)Math.Ceiling(g.MeasureString(row.Label, labelFont, new PointF(0, 0), StringFormat.GenericTypographic).Width);
                }
                if (need > widest) widest = need;
            }
        }
        int min = Px(MinCardW), max = Px(MaxCardW);
        if (widest < min) widest = min;
        if (widest > max) widest = max;
        return widest;
    }

    public void RefreshLayer()
    {
        if (!IsHandleCreated) return;
        using (Bitmap bmp = Render()) Push(bmp);
    }

    public Bitmap Render()
    {
        int cardW = CardPx, cardH = Px(CardH), gap = Px(Gap), pad = Px(Pad);
        int n = rows.Length;
        Bitmap bmp = new Bitmap(ClientSize.Width, ClientSize.Height, System.Drawing.Imaging.PixelFormat.Format32bppArgb);
        bmp.SetResolution(96f, 96f);
        using (Graphics g = Graphics.FromImage(bmp))
        {
            g.Clear(Color.Transparent);
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.PixelOffsetMode = PixelOffsetMode.HighQuality;
            g.TextRenderingHint = TextRenderingHint.AntiAlias;

            for (int i = 0; i < n; i++)
            {
                Rectangle card = new Rectangle(pad, pad + i * (cardH + gap), cardW, cardH);
                for (int r = 1; r <= 10; r++)
                {
                    int grow = (int)(r * 1.6f * S);
                    Rectangle sr = Rectangle.Inflate(card, grow, grow);
                    sr.Offset(0, Px(3) + grow / 4);
                    using (GraphicsPath sp = Round(sr, Radius * S + grow))
                    using (SolidBrush sb = new SolidBrush(Color.FromArgb(6, 0, 0, 0)))
                        g.FillPath(sb, sp);
                }
            }

            using (Font labelFont = new Font(Ui, PxPt(LabelPt), FontStyle.Bold, GraphicsUnit.Pixel))
            using (Font titleFont = new Font(Ui, PxPt(TitlePt), FontStyle.Regular, GraphicsUnit.Pixel))
            using (Font countFont = new Font(Ui, PxPt(CountPt), FontStyle.Regular, GraphicsUnit.Pixel))
            {
                for (int i = 0; i < n; i++)
                {
                    NotifyRow row = rows[i];
                    Rectangle card = new Rectangle(pad, pad + i * (cardH + gap), cardW, cardH);
                    Color accent = row.Accent;

                    using (GraphicsPath cp = Round(card, Radius * S))
                    {
                        using (LinearGradientBrush bg = new LinearGradientBrush(
                            new Rectangle(card.X - 2, card.Y - 2, card.Width + 4, card.Height + 4),
                            BgTop, BgBottom, 55f))
                            g.FillPath(bg, cp);
                        using (LinearGradientBrush bb = new LinearGradientBrush(card,
                            Color.FromArgb(54, 255, 255, 255), Color.FromArgb(84, 167, 139, 250), 45f))
                        using (Pen pen = new Pen(bb, Math.Max(1f, Px(1f))))
                            g.DrawPath(pen, cp);
                    }

                    // hairline highlight hugging the inside of the top edge: reads as glass, not a flat pill
                    Rectangle inner = Rectangle.Inflate(card, -Px(0.5f), -Px(0.5f));
                    if (inner.Width > 4 && inner.Height > 4)
                    {
                        using (GraphicsPath ip = Round(inner, Math.Max(2f, Radius * S - Px(0.5f))))
                        using (LinearGradientBrush hl = new LinearGradientBrush(
                            new Rectangle(inner.X, inner.Y, inner.Width, inner.Height),
                            Color.FromArgb(24, 255, 255, 255), Color.FromArgb(0, 255, 255, 255), 90f))
                        using (Pen hp = new Pen(hl, Math.Max(1f, Px(1f))))
                            g.DrawPath(hp, ip);
                    }

                    Rectangle bar = new Rectangle(card.X + Px(BarX), card.Y + Px(BarTop),
                        Math.Max(2, Px(BarW)), card.Height - Px(BarTop) * 2);
                    using (GraphicsPath bp = Round(bar, Math.Max(1.5f, bar.Width / 2f)))
                    using (LinearGradientBrush barBrush = new LinearGradientBrush(
                        new Rectangle(bar.X, bar.Y - 1, bar.Width, bar.Height + 2),
                        Mix(accent, Color.White, 0.30f), Mix(accent, Color.Black, 0.22f), 90f))
                        g.FillPath(barBrush, bp);

                    int rightLimit = card.Right - Px(TextRightPad);
                    bool hasTitle = row.Title != null && row.Title.Length > 0;
                    if (hasTitle)
                    {
                        using (SolidBrush lb = new SolidBrush(LabelCol))
                            g.DrawString(Spaced(row.Label), labelFont, lb,
                                card.X + Px(TextX), card.Y + Px(LabelY), StringFormat.GenericTypographic);
                    }

                    if (row.Count > 1)
                    {
                        string badge = "\u00D7" + row.Count;
                        SizeF bs = g.MeasureString(badge, countFont);
                        using (SolidBrush cb = new SolidBrush(CountCol))
                            g.DrawString(badge, countFont, cb, rightLimit - bs.Width,
                                card.Y + Px(TitleY), StringFormat.GenericTypographic);
                        rightLimit -= (int)bs.Width + Px(8);
                    }

                    if (hasTitle)
                    {
                        RectangleF tr = new RectangleF(card.X + Px(TextX), card.Y + Px(TitleY),
                            Math.Max(10, rightLimit - (card.X + Px(TextX))), Px(24));
                        StringFormat sf = new StringFormat(StringFormat.GenericTypographic);
                        sf.Trimming = StringTrimming.EllipsisCharacter;
                        sf.FormatFlags |= StringFormatFlags.NoWrap;
                        sf.LineAlignment = StringAlignment.Near;
                        using (SolidBrush tb = new SolidBrush(TitleCol))
                            g.DrawString(row.Title, titleFont, tb, tr, sf);
                    }
                    else
                    {
                        // overflow summary: one muted line, no second row
                        RectangleF tr = new RectangleF(card.X + Px(TextX), card.Y + Px(TitleY),
                            Math.Max(10, rightLimit - (card.X + Px(TextX))), Px(24));
                        StringFormat sf = new StringFormat(StringFormat.GenericTypographic);
                        sf.Trimming = StringTrimming.EllipsisCharacter;
                        sf.FormatFlags |= StringFormatFlags.NoWrap;
                        using (SolidBrush tb = new SolidBrush(CountCol))
                            g.DrawString(row.Label, titleFont, tb, tr, sf);
                    }
                }
            }
        }
        return bmp;
    }

    public void Push(Bitmap bmp)
    {
        IntPtr screenDc = GetDC(IntPtr.Zero);
        IntPtr memDc = CreateCompatibleDC(screenDc);
        IntPtr hBmp = bmp.GetHbitmap(Color.FromArgb(0, 0, 0, 0));
        IntPtr old = SelectObject(memDc, hBmp);
        try
        {
            SIZE size = new SIZE();
            size.cx = bmp.Width; size.cy = bmp.Height;
            POINT src = new POINT();
            POINT dst = new POINT();
            dst.X = Left; dst.Y = Top;
            BLENDFUNCTION bf = new BLENDFUNCTION();
            bf.BlendOp = 0; bf.BlendFlags = 0; bf.SourceConstantAlpha = 255; bf.AlphaFormat = 1;
            UpdateLayeredWindow(Handle, screenDc, ref dst, ref size, memDc, ref src, 0, ref bf, 2);
        }
        finally
        {
            SelectObject(memDc, old);
            DeleteObject(hBmp);
            DeleteDC(memDc);
            ReleaseDC(IntPtr.Zero, screenDc);
        }
    }

    private static Color Mix(Color a, Color b, float t)
    {
        return Color.FromArgb(a.A,
            (int)(a.R + (b.R - a.R) * t),
            (int)(a.G + (b.G - a.G) * t),
            (int)(a.B + (b.B - a.B) * t));
    }

    private static string Spaced(string s)
    {
        if (string.IsNullOrEmpty(s) || s.Length < 2) return s;
        var sb = new System.Text.StringBuilder();
        for (int i = 0; i < s.Length; i++)
        {
            if (i > 0) sb.Append('\u2009');
            sb.Append(s[i]);
        }
        return sb.ToString();
    }

    private static GraphicsPath Round(Rectangle r, float radius)
    {
        float d = radius * 2f;
        if (d > r.Width) d = r.Width;
        if (d > r.Height) d = r.Height;
        GraphicsPath p = new GraphicsPath();
        p.AddArc(r.X, r.Y, d, d, 180, 90);
        p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
        p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
        p.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
        p.CloseFigure();
        return p;
    }

    /// <summary>Client-space hit test against the painted toast cards (shadow padding
    /// and the gaps between toasts are not clickable).</summary>
    private bool HitCard(Point client)
    {
        int cardW = CardPx, cardH = Px(CardH), gap = Px(Gap), pad = Px(Pad);
        int n = rows.Length < 1 ? 1 : rows.Length;
        for (int i = 0; i < n; i++)
        {
            Rectangle card = new Rectangle(pad, pad + i * (cardH + gap), cardW, cardH);
            if (card.Contains(client)) return true;
        }
        return false;
    }

    protected override void WndProc(ref Message m)
    {
        if (m.Msg == 0x0084) // WM_NCHITTEST
        {
            int lp = m.LParam.ToInt32();
            int x = (short)(lp & 0xFFFF);
            int y = (short)((lp >> 16) & 0xFFFF);
            if (!HitCard(PointToClient(new Point(x, y))))
            {
                m.Result = new IntPtr(-1); // HTTRANSPARENT: clicks fall through to the desktop/app below
                return;
            }
        }
        base.WndProc(ref m);
    }

    protected override void OnMouseDown(MouseEventArgs e)
    {
        if (onPick != null) onPick();
        base.OnMouseDown(e);
    }
}
'@

Add-Type -TypeDefinition $csharp -ReferencedAssemblies System.Windows.Forms, System.Drawing

$script:Dpi = 96
try {
  $probe = [System.Drawing.Graphics]::FromHwnd([IntPtr]::Zero)
  $script:Dpi = [int][Math]::Round($probe.DpiX)
  $probe.Dispose()
} catch { }
$script:Scale = $script:Dpi / 96.0
$script:Margin = [int][Math]::Round(18 * $script:Scale)

$script:ShellPid = 0
$script:SuppressWhenFocused = $true
$script:MaxItems = 4
$script:PendingRows = New-Object System.Collections.ArrayList
$script:EventRows = New-Object System.Collections.ArrayList
$script:SnoozeUntil = [DateTime]::MinValue
$script:LastSignature = ''
$script:LastRaisedSignature = ''
$script:WindowHint = 'DeepSeek Harness'

# This file must stay ASCII-only: Windows PowerShell 5.1 reads .ps1 files with
# the ANSI code page, so CJK literals would be mangled. Localized text is
# carried as \u escapes inside a JSON snippet and decoded at run time.
function Get-Text([string]$Json) { return ($Json | ConvertFrom-Json).s }
$script:TextNotice = Get-Text '{"s":"\u901A\u77E5"}'
$script:TextMoreFmt = '{{"s":"\u8FD8\u6709 {0} \u6761\u901A\u77E5"}}'

function New-RowObject($item) {
  $row = New-Object NotifyRow
  $row.Label = if ($null -ne $item.label -and "$($item.label)" -ne '') { "$($item.label)" } else { $script:TextNotice }
  $row.Title = if ($null -ne $item.title) { "$($item.title)" } else { '' }
  $row.Count = if ($item.count) { [int]$item.count } else { 1 }
  $accent = if ($null -ne $item.accent) { "$($item.accent)" } else { '#F0B429' }
  try { $row.Accent = [System.Drawing.ColorTranslator]::FromHtml($accent) } catch { $row.Accent = [System.Drawing.Color]::FromArgb(240, 180, 41) }
  return $row
}

function Get-ComposedRows {
  $list = New-Object System.Collections.Generic.List[NotifyRow]
  $now = [DateTime]::UtcNow
  $seen = @{}
  $all = @()
  $all += @($script:PendingRows)
  $all += @($script:EventRows)
  foreach ($entry in $all) {
    if ($null -eq $entry) { continue }
    if ($entry.ContainsKey('Expires') -and $entry.Expires -le $now) { continue }
    $row = $entry.Row
    if ($null -eq $row) { continue }
    $key = '{0}|{1}' -f $row.Label, $row.Title
    if ($seen.ContainsKey($key)) {
      $seen[$key].Count = $seen[$key].Count + $row.Count
      continue
    }
    $seen[$key] = $row
    $list.Add($row)
  }
  if ($list.Count -gt $script:MaxItems -and $script:MaxItems -ge 2) {
    $extra = 0
    for ($index = $script:MaxItems - 1; $index -lt $list.Count; $index++) { $extra += $list[$index].Count }
    while ($list.Count -gt ($script:MaxItems - 1)) { $list.RemoveAt($list.Count - 1) }
    $more = New-Object NotifyRow
    $more.Label = (($script:TextMoreFmt -f $extra) | ConvertFrom-Json).s
    $more.Title = ''
    $more.Accent = [System.Drawing.Color]::FromArgb(150, 158, 170)
    $list.Add($more)
  }
  return , $list
}

function Get-RowSignature($list) {
  $parts = @()
  foreach ($row in $list) { $parts += ('{0}|{1}|{2}|{3}' -f $row.Label, $row.Title, $row.Count, $row.Accent.ToArgb()) }
  return ($parts -join ';')
}

$script:pickAction = [Action]{
  try {
    $hwnd = [DshWin]::Find($script:ShellPid, $script:WindowHint)
    $ok = [DshWin]::Activate($hwnd)
    Write-Log ("click activate={0} hwnd={1} foreground={2}" -f $ok, $hwnd, [DshWin]::ForegroundPid())
    if ($ok) { $script:SnoozeUntil = [DateTime]::UtcNow.AddSeconds(20) }
  } catch {
    Write-Log ("click failed: {0}" -f $_.Exception.Message)
  }
}
$card = New-Object ToastLayerForm
$card.S = [float]$script:Scale
$card.onPick = $script:pickAction

function Sync-Card {
  $rows = Get-ComposedRows
  $signature = Get-RowSignature $rows
  $changed = $signature -ne $script:LastSignature
  if ($changed) {
    $script:LastSignature = $signature
    $card.SetRows([NotifyRow[]]$rows.ToArray())
    $area = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    # the window carries a transparent Pad border for the drop shadow, so the
    # visible toast edge sits Margin away from the working-area corner.
    $card.Left = $area.Right - $card.Width - $script:Margin + $card.PadPx
    $card.Top = $area.Bottom - $card.Height - $script:Margin + $card.PadPx
    Write-Log ("toasts rows={0} size={1}x{2} at={3},{4} scale={5}" -f $rows.Count, $card.Width, $card.Height, $card.Left, $card.Top, $script:Scale)
  }
  $want = $rows.Count -gt 0
  if ($want -and $script:SnoozeUntil -gt [DateTime]::UtcNow) { $want = $false }
  if ($want -and $script:SuppressWhenFocused -and $script:ShellPid -gt 0) {
    if ([DshWin]::ForegroundPid() -eq $script:ShellPid) { $want = $false }
  }
  if ($want) {
    if (-not $card.Visible) {
      $card.Show()
      $card.RefreshLayer()
      [DshWin]::Raise($card.Handle)
      Write-Log ("toasts shown rows={0} foreground={1}" -f $rows.Count, [DshWin]::ForegroundPid())
    } elseif ($changed) {
      $card.RefreshLayer()
      [DshWin]::Raise($card.Handle)
    }
    $script:LastRaisedSignature = $signature
  } elseif ($card.Visible) {
    $card.Hide()
    Write-Log 'toasts hidden'
  }
}

function Apply-Message($message) {
  $type = if ($message.t) { "$($message.t)" } else { 'events' }
  if ($message.shellPid) { $script:ShellPid = [int]$message.shellPid }
  if ($message.maxItems) { $script:MaxItems = [int]$message.maxItems }
  if ($null -ne $message.suppressWhenFocused) { $script:SuppressWhenFocused = [bool]$message.suppressWhenFocused }
  $items = @($message.items)
  if ($type -eq 'pending') {
    $script:PendingRows.Clear()
    foreach ($item in $items) { [void]$script:PendingRows.Add(@{ Row = (New-RowObject $item) }) }
    Write-Log ("recv pending items={0} shellPid={1}" -f $items.Count, $script:ShellPid)
  } else {
    $duration = if ($message.durationMs) { [int]$message.durationMs } else { 5000 }
    if ($duration -lt 300) { $duration = 300 }
    $expires = [DateTime]::UtcNow.AddMilliseconds($duration)
    foreach ($item in $items) { [void]$script:EventRows.Add(@{ Row = (New-RowObject $item); Expires = $expires }) }
    Write-Log ("recv events items={0} durationMs={1} shellPid={2}" -f $items.Count, $duration, $script:ShellPid)
  }
}

$tick = New-Object System.Windows.Forms.Timer
$tick.Interval = $TickMs
$tick.Add_Tick({
  try { Sync-Card } catch { Write-Log ("tick error: {0}: {1}" -f $_.Exception.GetType().Name, $_.Exception.Message) }
})

if ($SelfTest) {
  $shotPath = if ($Shot) { $Shot } else { Join-Path $HelperDir 'notify-selftest-shot.png' }
  $script:stage = 0
  $timer = New-Object System.Windows.Forms.Timer
  $timer.Interval = 900
  $timer.Add_Tick({
    $script:stage = $script:stage + 1
    try {
      if ($script:stage -eq 1) {
        $fixtureJson = '[' +
          '{"label":"\u5F85\u786E\u8BA4","title":"\u91CD\u6784\u684C\u9762\u901A\u77E5\u52A9\u624B","accent":"#F0B429","count":1},' +
          '{"label":"\u5DF2\u5B8C\u6210","title":"\u63D2\u4EF6\u4E0Eskill\u662F\u5426\u540C\u4E49","accent":"#2FBF71","count":1},' +
          '{"label":"\u5DF2\u4E2D\u65AD","title":"\u64A4\u9500\u4EE3\u7801\u5757\u7981\u7528\u8981\u6C42","accent":"#2FBF71","count":2},' +
          '{"label":"\u51FA\u9519","title":"probe \u5931\u8D25\u6392\u67E5","accent":"#E5484D","count":1},' +
          '{"label":"\u5F85\u56DE\u7B54","title":"\u53D1\u5E03\u5230 GitHub \u7684\u4ED3\u5E93\u540D","accent":"#F0B429","count":1}' +
        ']'
        $fixture = @()
        $fixtureJson | ConvertFrom-Json | ForEach-Object { $fixture += $_ }
        Apply-Message @{ t = 'pending'; items = $fixture; maxItems = 4; shellPid = 0 }
        $script:SuppressWhenFocused = $false
        Sync-Card
        Write-Log ("selftest stage1 visible={0} topmost={1} size={2}x{3} at={4},{5} rows={6} scale={7}" -f `
            $card.Visible, $card.TopMost, $card.Width, $card.Height, $card.Left, $card.Top, $card.RowCount, $script:Scale)
        Start-Sleep -Milliseconds 400
        try {
          $layerPath = Join-Path $HelperDir 'notify-toast-layer.png'
          $layer = $card.Render()
          $layer.Save($layerPath, [System.Drawing.Imaging.ImageFormat]::Png)
          $layer.Dispose()
          $cx = [int]($card.Left + $card.PadPx + $card.CardPx / 2)
          $cy = [int]($card.Top + $card.PadPx + $card.CardPxH / 2)
          $top = [DshWin]::WindowAt($cx, $cy)
          Write-Log ("selftest topAtToast={0} cardHwnd={1} topIsCard={2} topWindow={3}" -f `
              $top, $card.Handle, ($top -eq $card.Handle), [DshWin]::Describe($top))
          Write-Log ("selftest layer={0}" -f $layerPath)
        } catch { Write-Log ("selftest render failed: {0}" -f $_.Exception.Message) }
        try {
          $m = [int](30 * $script:Scale)
          $x = [Math]::Max(0, $card.Left - $m)
          $y = [Math]::Max(0, $card.Top - $m)
          $w = [Math]::Min($card.Width + $m * 2, [System.Windows.Forms.Screen]::PrimaryScreen.Bounds.Width - $x)
          $h = [Math]::Min($card.Height + $m * 2, [System.Windows.Forms.Screen]::PrimaryScreen.Bounds.Height - $y)
          $bmp = New-Object System.Drawing.Bitmap($w, $h)
          $gfx = [System.Drawing.Graphics]::FromImage($bmp)
          $gfx.CopyFromScreen($x, $y, 0, 0, $bmp.Size)
          $bmp.Save($shotPath, [System.Drawing.Imaging.ImageFormat]::Png)
          $barX = [int]($card.Left - $x + $card.PadPx + 9 * $script:Scale)
          $midY = [int]($card.Top - $y + $card.PadPx + $card.CardPxH / 2)
          $bar = $bmp.GetPixel($barX, $midY)
          $title = $bmp.GetPixel([int]($card.Left - $x + $card.PadPx + 90 * $script:Scale), $midY)
          $gap = $bmp.GetPixel([int]($card.Left - $x + $card.PadPx + $card.CardPx / 2), [int]($card.Top - $y + $card.PadPx + $card.CardPxH + 5 * $script:Scale))
          $outside = $bmp.GetPixel(2, 2)
          Write-Log ("selftest screenshot={0} region={1},{2},{3}x{4} bar={5},{6},{7} title={8},{9},{10} gap={11},{12},{13} outside={14},{15},{16}" -f `
              $shotPath, $x, $y, $w, $h, $bar.R, $bar.G, $bar.B, $title.R, $title.G, $title.B, $gap.R, $gap.G, $gap.B, $outside.R, $outside.G, $outside.B)
          $gfx.Dispose(); $bmp.Dispose()
          $cx = [int]($card.Left + $card.PadPx + $card.CardPx / 2)
          $cy = [int]($card.Top + $card.PadPx + $card.CardPxH / 2)
          $gx = [int]($card.Left + $card.PadPx + 20 * $script:Scale)
          $gy = [int]($card.Top + $card.PadPx + $card.CardPxH + 5 * $script:Scale)
          $mx = [int]($card.Left + 4 * $script:Scale)
          $my = [int]($card.Top + $card.PadPx + $card.CardPxH / 2)
          Write-Log ("selftest hittest cardCenter=({0},{1})->{2} gap=({3},{4})->{5} shadowMargin=({6},{7})->{8} (1=client -1=passthrough)" -f `
              $cx, $cy, ([DshWin]::HitTest($card.Handle, $cx, $cy)), $gx, $gy, ([DshWin]::HitTest($card.Handle, $gx, $gy)),
              $mx, $my, ([DshWin]::HitTest($card.Handle, $mx, $my)))
        } catch { Write-Log ("selftest screenshot failed: {0}" -f $_.Exception.Message) }
      } elseif ($script:stage -eq 2) {
        Write-Log ("selftest stage2 stillVisible={0}" -f $card.Visible)
      } elseif ($script:stage -eq 3) {
        $hwnd = [DshWin]::Find($script:ShellPid, $script:WindowHint)
        Write-Log ("selftest stage3 find hwnd={0} foreground={1}" -f $hwnd, [DshWin]::ForegroundPid())
      } elseif ($script:stage -eq 4) {
        $script:pickAction.Invoke()
        Write-Log ("selftest stage4 afterInvoke visible={0} foreground={1}" -f $card.Visible, [DshWin]::ForegroundPid())
      } else {
        $timer.Stop()
        Write-Log ("selftest done visible={0}" -f $card.Visible)
        [System.Windows.Forms.Application]::ExitThread()
      }
    } catch {
      Write-Log ("selftest error: {0}: {1}" -f $_.Exception.GetType().Name, $_.Exception.Message)
    }
  })
  $tick.Start()
  $timer.Start()
  Write-Log 'selftest start'
  [System.Windows.Forms.Application]::Run()
  Write-Log 'helper stop (selftest)'
  exit 0
}

$reader = New-Object System.IO.StreamReader([Console]::OpenStandardInput(), [System.Text.Encoding]::UTF8)
$poll = New-Object System.Windows.Forms.Timer
$poll.Interval = $TickMs
$poll.Add_Tick({
  try {
    if ($reader.EndOfStream) { return }
    $line = $reader.ReadLine()
    if ($null -eq $line) { return }
    if ($line.Trim().Length -eq 0) { return }
    try {
      $message = $line | ConvertFrom-Json
      Apply-Message $message
    } catch {
      Write-Log ("bad json: {0}" -f $_.Exception.Message)
    }
  } catch {
    Write-Log ("read error: {0}" -f $_.Exception.Message)
  }
})

$tick.Start()
$poll.Start()
Write-Log ("helper start pid={0} log={1}" -f $PID, $script:LogPath)
[System.Windows.Forms.Application]::Run()
Write-Log 'helper stop'
