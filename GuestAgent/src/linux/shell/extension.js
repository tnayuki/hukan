// The screen of a hukan machine, for the guest agent's user half (shell.zig). A Wayland compositor
// lets no client read another's pixels, list its windows or type into it, so the agent asks GNOME
// Shell itself, over a unix socket in the user's runtime directory, which only the user can open:
// one JSON request a line, one JSON answer a line, then the connection closes.
//
//   {"op":"screenshot","window":?}                  -> {"ok":true,"data":"<base64 PNG>"}
//   {"op":"windows"}                                -> {"ok":true,"text":"<id\tapp\ttitle\tx,y wxh a line>"}
//   {"op":"click","x":..,"y":..,"count":?,"right":?,"window":?}  -> {"ok":true}
//   {"op":"keys","keysyms":[...]}                   -> {"ok":true}
//   {"op":"type","text":...}                        -> {"ok":true}
//
// The clipboard is not here: spice-vdagent carries it.

import Clutter from 'gi://Clutter';
import GdkPixbuf from 'gi://GdkPixbuf';
import Gio from 'gi://Gio';
import IBus from 'gi://IBus';
import GLib from 'gi://GLib';
import Meta from 'gi://Meta';
import Shell from 'gi://Shell';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as IBusManager from 'resource:///org/gnome/shell/misc/ibusManager.js';
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';

Gio._promisify(Shell.Screenshot.prototype, 'screenshot_area');
Gio._promisify(Gio.DataInputStream.prototype, 'read_line_async');
Gio._promisify(Gio.OutputStream.prototype, 'write_all_async');

const now = () => GLib.get_monotonic_time();

const pause = milliseconds => new Promise(done => {
    GLib.timeout_add(GLib.PRIORITY_DEFAULT, milliseconds, () => {
        done();
        return GLib.SOURCE_REMOVE;
    });
});

/// A position rounded half up, as the host has always had it rounded.
const rounded = value => Math.floor(value + 0.5);

export default class HukanShell extends Extension {
    enable() {
        const seat = Clutter.get_default_backend().get_default_seat();
        this._pointer = seat.create_virtual_device(Clutter.InputDeviceType.POINTER_DEVICE);
        this._keyboard = seat.create_virtual_device(Clutter.InputDeviceType.KEYBOARD_DEVICE);
        const path = GLib.build_filenamev([GLib.get_user_runtime_dir(), 'hukan-shell.sock']);
        GLib.unlink(path);
        this._service = new Gio.SocketService();
        this._service.add_address(Gio.UnixSocketAddress.new(path), Gio.SocketType.STREAM,
            Gio.SocketProtocol.DEFAULT, null);
        this._service.connect('incoming', (_service, connection) => {
            this._serve(connection).catch(e => logError(e, 'hukan'));
            return true;
        });
        this._service.start();
        this._path = path;
    }

    disable() {
        if (this._service) {
            this._service.stop();
            this._service.close();
            GLib.unlink(this._path);
        }
        this._service = null;
        this._pointer = null;
        this._keyboard = null;
    }

    async _serve(connection) {
        const input = new Gio.DataInputStream({base_stream: connection.get_input_stream()});
        let answer;
        try {
            const [line] = await input.read_line_async(GLib.PRIORITY_DEFAULT, null);
            answer = await this._answer(JSON.parse(new TextDecoder().decode(line)));
        } catch (e) {
            answer = {ok: false, error: String(e.message ?? e)};
        }
        try {
            await connection.get_output_stream().write_all_async(
                new TextEncoder().encode(`${JSON.stringify(answer)}\n`), GLib.PRIORITY_DEFAULT, null);
        } finally {
            connection.close(null);
        }
    }

    _window(id) {
        const found = global.get_window_actors().map(actor => actor.meta_window)
            .find(window => String(window.get_id()) === String(id));
        if (!found)
            throw new Error(`no window ${id}`);
        return found;
    }

    /// Where a window's frame stands, or the whole screen's for none: the frame and not the
    /// buffer, so a client's own shadow is not part of it.
    _frame(id) {
        if (id === undefined || id === null)
            return {x: 0, y: 0, width: global.screen_width, height: global.screen_height};
        return this._window(id).get_frame_rect();
    }

    _answer(r) {
        switch (r.op) {
        case 'windows': return this._windows();
        case 'screenshot': return this._screenshot(r);
        case 'click': return this._click(r);
        case 'keys': return this._keys(r);
        case 'type': return this._type(r);
        default:
            return {ok: false, error: `unknown op ${r.op}`};
        }
    }

    /// Front to back.
    _windows() {
        const listed = global.display.sort_windows_by_stacking(
            global.display.get_tab_list(Meta.TabList.NORMAL_ALL, null)).reverse();
        const lines = listed.map(window => {
            const f = window.get_frame_rect();
            const title = (window.get_title() ?? '').replace(/\t/g, ' ');
            return `${window.get_id()}\t${window.get_wm_class() ?? ''}\t${title}\t${f.x},${f.y} ${f.width}x${f.height}`;
        });
        return {ok: true, text: lines.join('\n')};
    }

    /// Read off the screen where the window stands, so what covers it is in the picture. The part
    /// off the screen is black and the picture stays the window's size, so a
    /// position in it is still a position in the window.
    async _screenshot(r) {
        const frame = this._frame(r.window);
        const left = Math.max(frame.x, 0);
        const top = Math.max(frame.y, 0);
        const right = Math.min(frame.x + frame.width, global.screen_width);
        const bottom = Math.min(frame.y + frame.height, global.screen_height);
        if (right <= left || bottom <= top)
            return {ok: false, error: `window ${r.window} is not on the screen`};
        const stream = Gio.MemoryOutputStream.new_resizable();
        await new Shell.Screenshot().screenshot_area(left, top, right - left, bottom - top, stream);
        stream.close(null);
        let png = stream.steal_as_bytes();
        if (left !== frame.x || top !== frame.y || right - left !== frame.width || bottom - top !== frame.height) {
            const loader = new GdkPixbuf.PixbufLoader();
            loader.write_bytes(png);
            loader.close();
            const seen = loader.get_pixbuf();
            const whole = GdkPixbuf.Pixbuf.new(GdkPixbuf.Colorspace.RGB, true, 8, frame.width, frame.height);
            whole.fill(0x000000ff);
            seen.copy_area(0, 0, seen.get_width(), seen.get_height(), whole, left - frame.x, top - frame.y);
            const [, buffer] = whole.save_to_bufferv('png', [], []);
            png = buffer;
        }
        const bytes = png instanceof Uint8Array ? png : png.toArray();
        return {ok: true, data: GLib.base64_encode(bytes)};
    }

    _click(r) {
        if (typeof r.x !== 'number' || typeof r.y !== 'number')
            return {ok: false, error: 'click needs x and y'};
        const frame = this._frame(r.window);
        const button = r.right ? Clutter.BUTTON_SECONDARY : Clutter.BUTTON_PRIMARY;
        const count = Math.max(1, rounded(r.count ?? 1));
        this._pointer.notify_absolute_motion(now(), frame.x + rounded(r.x), frame.y + rounded(r.y));
        for (let i = 0; i < count; i++) {
            this._pointer.notify_button(now(), button, Clutter.ButtonState.PRESSED);
            this._pointer.notify_button(now(), button, Clutter.ButtonState.RELEASED);
        }
        return {ok: true};
    }

    /// Keysyms pressed in order and released the other way round: a key with its modifiers held.
    _keys(r) {
        const keysyms = r.keysyms ?? [];
        for (const keyval of keysyms)
            this._keyboard.notify_keyval(now(), keyval, Clutter.KeyState.PRESSED);
        for (const keyval of [...keysyms].reverse())
            this._keyboard.notify_keyval(now(), keyval, Clutter.KeyState.RELEASED);
        return {ok: true};
    }

    /// Text no key types, committed to whatever has the keyboard. Through IBus's panel — GNOME Shell
    /// is IBus's panel — the daemon hands it to the focused input context: an X11 app's own on
    /// Xwayland, or the shell's, which passes it to the Wayland client or entry it serves. Without
    /// IBus, only the shell's input method is left.
    _commit(text) {
        const panel = IBusManager.getIBusManager()._panelService;
        if (panel)
            panel.commit_text(IBus.Text.new_from_string(text));
        else
            Main.inputMethod.commit(text);
    }

    /// Waits for the keys sent so far to have reached whatever has the keyboard.
    async _settleKeys() {
        await pause(80);
    }

    /// Printable ASCII, a newline and a tab are typed as keys, which every layout has and which
    /// reach anything, the shell's search too (a key is what focuses it). Anything else is
    /// committed (_commit), since a keysym the keymap lacks is dropped on Wayland, where X11 could
    /// be given a spare key for it: a run of such characters as one commit, as an input method
    /// would — commits one character at a time, close together, left a Wayland client only the
    /// last. Keys and commits reach a client by different roads, so each waits for the other.
    async _type(r) {
        const text = r.text;
        if (typeof text !== 'string')
            return {ok: false, error: 'type needs text'};
        let run = '';
        let afterKey = false;
        for (const character of text) {
            const code = character.codePointAt(0);
            const keyval = character === '\n' ? Clutter.KEY_Return
                : character === '\t' ? Clutter.KEY_Tab
                : code >= 0x20 && code < 0x7f ? code : 0;
            if (!keyval) {
                run += character;
                continue;
            }
            if (run) {
                if (afterKey)
                    await this._settleKeys();
                this._commit(run);
                run = '';
                await pause(50);
            }
            this._keyboard.notify_keyval(now(), keyval, Clutter.KeyState.PRESSED);
            this._keyboard.notify_keyval(now(), keyval, Clutter.KeyState.RELEASED);
            afterKey = true;
            await pause(8);
        }
        if (run) {
            if (afterKey)
                await this._settleKeys();
            this._commit(run);
        }
        return {ok: true};
    }
}
