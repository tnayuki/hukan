// The interface of a Windows guest, for the user half of the agent: what is on the screen, through
// UI Automation, and the mouse and keyboard, through SendInput. Positions are pixels of a picture of
// the screen, or of one window's picture when a window is named.

using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Windows.Automation;

namespace HukanGuestAgent
{
    static class Interface
    {
        [StructLayout(LayoutKind.Sequential)] struct Rect { public int Left, Top, Right, Bottom; }
        [StructLayout(LayoutKind.Sequential)] struct Point32 { public int X, Y; }

        [StructLayout(LayoutKind.Sequential)]
        struct MouseInput { public int X, Y; public uint Data, Flags, Time; public IntPtr Extra; }

        [StructLayout(LayoutKind.Sequential)]
        struct KeyInput { public ushort Key, Scan; public uint Flags, Time; public IntPtr Extra; public int Pad1, Pad2; }

        [StructLayout(LayoutKind.Explicit)]
        struct InputUnion { [FieldOffset(0)] public MouseInput Mouse; [FieldOffset(0)] public KeyInput Key; }

        [StructLayout(LayoutKind.Sequential)]
        struct Input { public uint Type; public InputUnion Data; }

        delegate bool EnumProc(IntPtr window, IntPtr parameter);

        [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc proc, IntPtr parameter);
        [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr window);
        [DllImport("user32.dll")] static extern bool IsWindow(IntPtr window);
        [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr window, out Rect rect);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr window, StringBuilder text, int count);
        [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr window, out uint process);
        [DllImport("user32.dll")] static extern IntPtr WindowFromPoint(Point32 point);
        [DllImport("user32.dll")] static extern IntPtr GetAncestor(IntPtr window, uint flags);
        [DllImport("user32.dll")] static extern bool SetCursorPos(int x, int y);
        [DllImport("user32.dll")] static extern uint SendInput(uint count, Input[] inputs, int size);
        [DllImport("user32.dll")] static extern bool PrintWindow(IntPtr window, IntPtr context, uint flags);
        [DllImport("user32.dll")] static extern bool SetProcessDPIAware();
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern short VkKeyScan(char character);

        const uint RootAncestor = 2, PrintRenderFull = 2;
        const uint InputMouse = 0, InputKeyboard = 1;
        const uint LeftDown = 2, LeftUp = 4, RightDown = 8, RightUp = 16;
        const uint KeyUp = 2, KeyUnicode = 4;

        static Interface() { SetProcessDPIAware(); }

        static Dictionary<string, object> Fail(string message) =>
            new Dictionary<string, object> { ["ok"] = false, ["error"] = message };

        static Dictionary<string, object> Done(string text = null)
        {
            var reply = new Dictionary<string, object> { ["ok"] = true };
            if (text != null) reply["text"] = text;
            return reply;
        }

        static string Clip(string text)
        {
            var flat = (text ?? "").Replace('\n', ' ').Replace('\r', ' ');
            return flat.Length > 120 ? flat.Substring(0, 120) + "…" : flat;
        }

        static string Title(IntPtr window)
        {
            var text = new StringBuilder(512);
            GetWindowText(window, text, text.Capacity);
            return text.ToString();
        }

        // MARK: Windows

        public static Dictionary<string, object> Windows()
        {
            var lines = new List<string> { "id\tapp\ttitle\tframe" };
            EnumWindows((window, _) =>
            {
                var title = Title(window);
                if (!IsWindowVisible(window) || title.Length == 0 || !GetWindowRect(window, out var rect)) return true;
                if (rect.Right - rect.Left <= 1 || rect.Bottom - rect.Top <= 1) return true;
                GetWindowThreadProcessId(window, out var process);
                string app;
                try { app = System.Diagnostics.Process.GetProcessById((int)process).ProcessName; }
                catch (Exception) { app = "?"; }
                lines.Add($"{window.ToInt64()}\t{app}\t{Clip(title)}\t[{rect.Left},{rect.Top} {rect.Right - rect.Left}x{rect.Bottom - rect.Top}]");
                return true;
            }, IntPtr.Zero);
            return Done(string.Join("\n", lines));
        }

        /// A window's own picture: PrintWindow reads what it draws, so one covered by another comes out whole.
        public static Dictionary<string, object> Screenshot(long id)
        {
            var window = new IntPtr(id);
            if (!IsWindow(window) || !GetWindowRect(window, out var rect)) return Fail("no window " + id);
            using (var bitmap = new Bitmap(rect.Right - rect.Left, rect.Bottom - rect.Top, PixelFormat.Format32bppArgb))
            using (var graphics = Graphics.FromImage(bitmap))
            using (var stream = new MemoryStream())
            {
                var context = graphics.GetHdc();
                var drawn = PrintWindow(window, context, PrintRenderFull);
                graphics.ReleaseHdc(context);
                if (!drawn) return Fail("window " + id + " could not be drawn");
                bitmap.Save(stream, ImageFormat.Png);
                var reply = Done();
                reply["data"] = Convert.ToBase64String(stream.ToArray());
                return reply;
            }
        }

        // MARK: The tree

        static AutomationElement Root(string app, long? window, out string prefix)
        {
            if (window != null)
            {
                prefix = window.Value + "/";
                return AutomationElement.FromHandle(new IntPtr(window.Value));
            }
            var handle = IntPtr.Zero;
            EnumWindows((candidate, _) =>
            {
                if (!IsWindowVisible(candidate) || Title(candidate).Length == 0) return true;
                if (app != null)
                {
                    GetWindowThreadProcessId(candidate, out var process);
                    try
                    {
                        if (!string.Equals(System.Diagnostics.Process.GetProcessById((int)process).ProcessName, app, StringComparison.OrdinalIgnoreCase))
                            return true;
                    }
                    catch (Exception) { return true; }
                }
                handle = candidate;
                return false;
            }, IntPtr.Zero);
            if (handle == IntPtr.Zero) throw new InvalidOperationException("no such application has a window");
            prefix = handle.ToInt64() + "/";
            return AutomationElement.FromHandle(handle);
        }

        static string Describe(AutomationElement element, string id, int depth, Rect? origin)
        {
            var current = element.Current;
            var line = new StringBuilder(new string(' ', depth)).Append(id).Append(' ')
                .Append(current.ControlType.ProgrammaticName.Replace("ControlType.", ""));
            if (!string.IsNullOrEmpty(current.Name)) line.Append(" \"").Append(Clip(current.Name)).Append('"');
            if (element.TryGetCurrentPattern(ValuePattern.Pattern, out var value))
            {
                var text = ((ValuePattern)value).Current.Value;
                if (!string.IsNullOrEmpty(text)) line.Append(" value=\"").Append(Clip(text)).Append('"');
            }
            var box = current.BoundingRectangle;
            if (!box.IsEmpty && !double.IsInfinity(box.X))
            {
                var x = (int)box.X - (origin?.Left ?? 0);
                var y = (int)box.Y - (origin?.Top ?? 0);
                line.Append($" [{x},{y} {(int)box.Width}x{(int)box.Height}]");
            }
            var actions = element.GetSupportedPatterns().Select(p => p.ProgrammaticName.Replace("Identifiers.Pattern", "").Replace("Pattern", ""))
                .Where(n => n == "Invoke" || n == "Toggle" || n == "ExpandCollapse" || n == "SelectionItem").ToArray();
            if (actions.Length > 0) line.Append(" {").Append(string.Join(",", actions)).Append('}');
            return line.ToString();
        }

        public static Dictionary<string, object> Tree(string app, long? window)
        {
            var root = Root(app, window, out var prefix);
            Rect? origin = null;
            if (window != null && GetWindowRect(new IntPtr(window.Value), out var rect)) origin = rect;
            var lines = new List<string>();
            const int limit = 2000;
            void Walk(AutomationElement element, string id, int depth)
            {
                if (lines.Count >= limit || depth > 40) return;
                // An element can fail on its own — a popup going away, or one that answers
                // E_UNEXPECTED — and that costs its own branch, never the rest of the tree.
                try { lines.Add(Describe(element, id, depth, origin)); }
                catch (Exception error) { lines.Add(new string(' ', depth) + id + " (unreadable: " + Clip(error.Message) + ")"); }
                var index = 0;
                AutomationElement child;
                try { child = TreeWalker.ControlViewWalker.GetFirstChild(element); }
                catch (Exception) { return; }
                while (child != null && lines.Count < limit)
                {
                    Walk(child, id.EndsWith("/") ? id + index : id + "." + index, depth + 1);
                    index++;
                    try { child = TreeWalker.ControlViewWalker.GetNextSibling(child); }
                    catch (Exception) { break; }
                }
            }
            Walk(root, prefix, 0);
            if (lines.Count >= limit) lines.Add("… cut at " + limit + " lines");
            return Done(string.Join("\n", lines));
        }

        /// An id is the window and the child positions down to the element, as in the macOS agent.
        static AutomationElement Find(string id)
        {
            var slash = id?.IndexOf('/') ?? -1;
            if (slash < 0) throw new InvalidOperationException("no element " + id);
            var element = AutomationElement.FromHandle(new IntPtr(long.Parse(id.Substring(0, slash))));
            foreach (var part in id.Substring(slash + 1).Split(new[] { '.' }, StringSplitOptions.RemoveEmptyEntries))
            {
                var child = TreeWalker.ControlViewWalker.GetFirstChild(element);
                for (var index = int.Parse(part); index > 0 && child != null; index--)
                    child = TreeWalker.ControlViewWalker.GetNextSibling(child);
                element = child ?? throw new InvalidOperationException("no element " + id);
            }
            return element;
        }

        public static Dictionary<string, object> Press(string id, string action)
        {
            var element = Find(id);
            switch (action ?? "Invoke")
            {
                case "Press":
                case "Invoke":
                    if (element.TryGetCurrentPattern(InvokePattern.Pattern, out var invoke)) { ((InvokePattern)invoke).Invoke(); return Done(); }
                    if (element.TryGetCurrentPattern(TogglePattern.Pattern, out var press)) { ((TogglePattern)press).Toggle(); return Done(); }
                    if (element.TryGetCurrentPattern(SelectionItemPattern.Pattern, out var pick)) { ((SelectionItemPattern)pick).Select(); return Done(); }
                    break;
                case "Toggle":
                    if (element.TryGetCurrentPattern(TogglePattern.Pattern, out var toggle)) { ((TogglePattern)toggle).Toggle(); return Done(); }
                    break;
                case "ExpandCollapse":
                    if (element.TryGetCurrentPattern(ExpandCollapsePattern.Pattern, out var expand))
                    {
                        var pattern = (ExpandCollapsePattern)expand;
                        if (pattern.Current.ExpandCollapseState == ExpandCollapseState.Collapsed) pattern.Expand(); else pattern.Collapse();
                        return Done();
                    }
                    break;
                case "SelectionItem":
                    if (element.TryGetCurrentPattern(SelectionItemPattern.Pattern, out var select)) { ((SelectionItemPattern)select).Select(); return Done(); }
                    break;
            }
            return Fail("that element does not take " + (action ?? "Invoke"));
        }

        public static Dictionary<string, object> SetValue(string id, string value)
        {
            var element = Find(id);
            if (!element.TryGetCurrentPattern(ValuePattern.Pattern, out var pattern)) return Fail("that element has no value to set");
            ((ValuePattern)pattern).SetValue(value);
            return Done();
        }

        // MARK: Mouse and keyboard

        static void Send(params Input[] inputs) => SendInput((uint)inputs.Length, inputs, Marshal.SizeOf(typeof(Input)));

        static Input Mouse(uint flags) =>
            new Input { Type = InputMouse, Data = new InputUnion { Mouse = new MouseInput { Flags = flags } } };

        static Input Key(ushort key, ushort scan, uint flags) =>
            new Input { Type = InputKeyboard, Data = new InputUnion { Key = new KeyInput { Key = key, Scan = scan, Flags = flags } } };

        public static Dictionary<string, object> Click(double x, double y, int count, bool right, long? window)
        {
            var point = new Point32 { X = (int)x, Y = (int)y };
            if (window != null)
            {
                var handle = new IntPtr(window.Value);
                if (!IsWindow(handle) || !GetWindowRect(handle, out var rect)) return Fail("no window " + window);
                point.X += rect.Left;
                point.Y += rect.Top;
                if (point.X >= rect.Right || point.Y >= rect.Bottom || point.X < rect.Left || point.Y < rect.Top)
                    return Fail($"that point of window {window} is outside it");
                // A click goes to whatever is on top there, which is not necessarily the window asked for.
                var top = GetAncestor(WindowFromPoint(point), RootAncestor);
                if (top != handle) return Fail($"that point of window {window} is covered by \"{Clip(Title(top))}\"; bring it to the front first");
            }
            SetCursorPos(point.X, point.Y);
            Thread.Sleep(50);
            var (down, up) = right ? (RightDown, RightUp) : (LeftDown, LeftUp);
            for (var i = 0; i < Math.Max(count, 1); i++)
            {
                Send(Mouse(down));
                Thread.Sleep(30);
                Send(Mouse(up));
                Thread.Sleep(30);
            }
            return Done();
        }

        public static Dictionary<string, object> Type(string text)
        {
            foreach (var unit in text)
            {
                Send(Key(0, unit, KeyUnicode));
                Send(Key(0, unit, KeyUnicode | KeyUp));
                Thread.Sleep(8);
            }
            return Done();
        }

        static readonly Dictionary<string, ushort> Keys = new Dictionary<string, ushort>
        {
            ["return"] = 0x0D, ["tab"] = 0x09, ["space"] = 0x20, ["delete"] = 0x08, ["escape"] = 0x1B,
            ["left"] = 0x25, ["up"] = 0x26, ["right"] = 0x27, ["down"] = 0x28, ["home"] = 0x24, ["end"] = 0x23,
            ["pageup"] = 0x21, ["pagedown"] = 0x22,
        };

        static readonly Dictionary<string, ushort> Modifiers = new Dictionary<string, ushort>
        {
            ["command"] = 0x5B, ["cmd"] = 0x5B, ["windows"] = 0x5B, ["shift"] = 0x10, ["option"] = 0x12, ["alt"] = 0x12,
            ["control"] = 0x11, ["ctrl"] = 0x11,
        };

        public static Dictionary<string, object> Press(string key, IEnumerable<string> modifiers)
        {
            var name = key.ToLowerInvariant();
            ushort code;
            if (Keys.TryGetValue(name, out var named)) code = named;
            else if (name.Length == 1 && char.IsLetterOrDigit(name[0])) code = char.ToUpperInvariant(name[0]);
            else if (name.Length >= 2 && name[0] == 'f' && int.TryParse(name.Substring(1), out var f) && f >= 1 && f <= 12) code = (ushort)(0x6F + f);
            else if (name.Length == 1 && VkKeyScan(name[0]) != -1) code = (ushort)(VkKeyScan(name[0]) & 0xFF);
            else return Fail("no key named " + key);
            var held = new List<ushort>();
            // A symbol's key is the layout's, and on some layouts it takes Shift to reach.
            if (name.Length == 1 && !char.IsLetterOrDigit(name[0]) && (VkKeyScan(name[0]) & 0x100) != 0) held.Add(0x10);
            foreach (var modifier in modifiers)
            {
                if (!Modifiers.TryGetValue(modifier.ToLowerInvariant(), out var vk)) return Fail("no modifier named " + modifier);
                held.Add(vk);
            }
            foreach (var vk in held) Send(Key(vk, 0, 0));
            Send(Key(code, 0, 0));
            Thread.Sleep(30);
            Send(Key(code, 0, KeyUp));
            for (var i = held.Count - 1; i >= 0; i--) Send(Key(held[i], 0, KeyUp));
            return Done();
        }
    }
}
