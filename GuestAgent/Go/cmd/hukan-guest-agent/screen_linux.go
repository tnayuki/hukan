package main

// The screen of a Linux guest, for the user half: what the host's screenshot, click, type, key
// and window-list tools ask for, answered over the X11 protocol itself — the core protocol for
// pictures and windows, XTEST for input — so the guest needs nothing installed for it. X11
// only: a session on Wayland has no X server to ask, and says so.
//
//	{"op":"screenshot","window":?}                 -> {"ok":true,"data":"<base64 PNG>"}
//	{"op":"windows"}                               -> {"ok":true,"text":"<id\tapp\ttitle\tx,y wxh a line>"}
//	{"op":"click","x":..,"y":..,"count":?,"right":?,"window":?}  -> {"ok":true}
//	{"op":"type","text":...}                       -> {"ok":true}
//	{"op":"key","key":"return","modifiers":["command"]?}  -> {"ok":true}
//
// Positions are in the pixels of a screenshot — of that window's own, given a window — which on
// X11 are the screen's own pixels.

import (
	"bytes"
	"encoding/base64"
	"fmt"
	"image"
	"image/png"
	"os"
	"strings"
	"time"
	"unicode"

	"github.com/jezek/xgb"
	"github.com/jezek/xgb/xproto"
	"github.com/jezek/xgb/xtest"

	"hukan/guestagent/agent"
)

func screen(request map[string]any) (map[string]any, bool) {
	op, _ := request["op"].(string)
	switch op {
	case "screenshot", "windows", "click", "type", "key":
	default:
		return nil, false
	}
	display, err := openDisplay()
	if err != nil {
		return agent.Failure(err.Error()), true
	}
	defer display.conn.Close()
	switch op {
	case "screenshot":
		return display.screenshot(request), true
	case "windows":
		return display.windows(), true
	case "click":
		return display.click(request), true
	case "type":
		return display.typeText(request), true
	default:
		return display.key(request), true
	}
}

type x11 struct {
	conn *xgb.Conn
	root xproto.Window
	// The keyboard as the server maps it now: keysyms per keycode, from minKeycode.
	minKeycode, maxKeycode xproto.Keycode
	perKeycode             int
	keysyms                []xproto.Keysym
}

// openDisplay reaches the session's X server: the display and authority the session gave
// systemd, or the first display and GDM's authority file when it has not given them yet.
func openDisplay() (*x11, error) {
	name := os.Getenv("DISPLAY")
	if name == "" {
		name = ":0"
	}
	if os.Getenv("XAUTHORITY") == "" {
		os.Setenv("XAUTHORITY", fmt.Sprintf("/run/user/%d/gdm/Xauthority", os.Getuid()))
	}
	conn, err := xgb.NewConnDisplay(name)
	if err != nil {
		return nil, fmt.Errorf("no X11 display to reach (%v) — the session may be on Wayland", err)
	}
	if err := xtest.Init(conn); err != nil {
		conn.Close()
		return nil, fmt.Errorf("the X server has no XTEST: %v", err)
	}
	setup := xproto.Setup(conn)
	d := &x11{
		conn: conn, root: setup.DefaultScreen(conn).Root,
		minKeycode: setup.MinKeycode, maxKeycode: setup.MaxKeycode,
	}
	if err := d.readKeyboard(); err != nil {
		conn.Close()
		return nil, err
	}
	return d, nil
}

func (d *x11) readKeyboard() error {
	count := byte(int(d.maxKeycode) - int(d.minKeycode) + 1)
	reply, err := xproto.GetKeyboardMapping(d.conn, d.minKeycode, count).Reply()
	if err != nil {
		return err
	}
	d.perKeycode = int(reply.KeysymsPerKeycode)
	d.keysyms = reply.Keysyms
	return nil
}

// origin is where a window's top-left is on the screen, or the screen's own for none.
func (d *x11) origin(request map[string]any) (x, y int, width, height int, err error) {
	if value, ok := request["window"].(float64); ok {
		window := xproto.Window(uint32(value))
		geometry, err := xproto.GetGeometry(d.conn, xproto.Drawable(window)).Reply()
		if err != nil {
			return 0, 0, 0, 0, fmt.Errorf("no window %d", uint32(value))
		}
		at, err := xproto.TranslateCoordinates(d.conn, window, d.root, 0, 0).Reply()
		if err != nil {
			return 0, 0, 0, 0, err
		}
		return int(at.DstX), int(at.DstY), int(geometry.Width), int(geometry.Height), nil
	}
	geometry, err := xproto.GetGeometry(d.conn, xproto.Drawable(d.root)).Reply()
	if err != nil {
		return 0, 0, 0, 0, err
	}
	return 0, 0, int(geometry.Width), int(geometry.Height), nil
}

// screenshot is read off the screen where the window stands, so what covers it is in the
// picture: without a compositor, X keeps no picture of the covered part of a window.
func (d *x11) screenshot(request map[string]any) map[string]any {
	x, y, width, height, err := d.origin(request)
	if err != nil {
		return agent.Failure(err.Error())
	}
	reply, err := xproto.GetImage(
		d.conn, xproto.ImageFormatZPixmap, xproto.Drawable(d.root), int16(x), int16(y),
		uint16(width), uint16(height), 0xffffffff).Reply()
	if err != nil {
		return agent.Failure(fmt.Sprintf("the screen could not be read: %v", err))
	}
	// Depth 24 comes as 32 bits a pixel, blue first.
	if len(reply.Data) < width*height*4 {
		return agent.Failure("the screen is not 32 bits a pixel")
	}
	picture := image.NewRGBA(image.Rect(0, 0, width, height))
	for i := 0; i < width*height; i++ {
		picture.Pix[i*4] = reply.Data[i*4+2]
		picture.Pix[i*4+1] = reply.Data[i*4+1]
		picture.Pix[i*4+2] = reply.Data[i*4]
		picture.Pix[i*4+3] = 0xff
	}
	var encoded bytes.Buffer
	if err := (&png.Encoder{CompressionLevel: png.BestSpeed}).Encode(&encoded, picture); err != nil {
		return agent.Failure(err.Error())
	}
	return map[string]any{"ok": true, "data": base64.StdEncoding.EncodeToString(encoded.Bytes())}
}

func (d *x11) atom(name string) xproto.Atom {
	reply, err := xproto.InternAtom(d.conn, true, uint16(len(name)), name).Reply()
	if err != nil {
		return xproto.AtomNone
	}
	return reply.Atom
}

func (d *x11) property(window xproto.Window, name string, kind xproto.Atom) []byte {
	reply, err := xproto.GetProperty(
		d.conn, false, window, d.atom(name), kind, 0, 1<<16).Reply()
	if err != nil || reply == nil {
		return nil
	}
	return reply.Value
}

// windows lists the window manager's clients, front to back, as EWMH has them stacked.
func (d *x11) windows() map[string]any {
	stacked := d.property(d.root, "_NET_CLIENT_LIST_STACKING", xproto.AtomWindow)
	var lines []string
	for i := len(stacked) - 4; i >= 0; i -= 4 {
		window := xproto.Window(xgb.Get32(stacked[i:]))
		title := string(d.property(window, "_NET_WM_NAME", d.atom("UTF8_STRING")))
		if title == "" {
			title = string(d.property(window, "WM_NAME", xproto.AtomString))
		}
		// WM_CLASS is the instance and the class, each ending in a NUL; the class names the app.
		class := strings.Split(strings.TrimRight(string(d.property(window, "WM_CLASS", xproto.AtomString)), "\x00"), "\x00")
		app := class[len(class)-1]
		x, y, width, height, err := d.origin(map[string]any{"window": float64(window)})
		if err != nil {
			continue
		}
		lines = append(lines, fmt.Sprintf(
			"%d\t%s\t%s\t%d,%d %dx%d", uint32(window), app, strings.ReplaceAll(title, "\t", " "), x, y, width, height))
	}
	return map[string]any{"ok": true, "text": strings.Join(lines, "\n")}
}

func number(value any) (int, bool) {
	if v, ok := value.(float64); ok {
		return int(v + 0.5), true
	}
	return 0, false
}

func (d *x11) click(request map[string]any) map[string]any {
	x, okX := number(request["x"])
	y, okY := number(request["y"])
	if !okX || !okY {
		return agent.Failure("click needs x and y")
	}
	left, top, _, _, err := d.origin(request)
	if err != nil {
		return agent.Failure(err.Error())
	}
	button := byte(1)
	if right, _ := request["right"].(bool); right {
		button = 3
	}
	count := 1
	if value, ok := number(request["count"]); ok && value > 1 {
		count = value
	}
	xtest.FakeInput(d.conn, xproto.MotionNotify, 0, 0, d.root, int16(left+x), int16(top+y), 0)
	for i := 0; i < count; i++ {
		xtest.FakeInput(d.conn, xproto.ButtonPress, button, 0, d.root, 0, 0, 0)
		xtest.FakeInput(d.conn, xproto.ButtonRelease, button, 0, d.root, 0, 0, 0)
	}
	return d.sync()
}

// sync waits for the server to have taken every event sent, so the answer comes after the input.
func (d *x11) sync() map[string]any {
	if _, err := xproto.GetInputFocus(d.conn).Reply(); err != nil {
		return agent.Failure(err.Error())
	}
	return map[string]any{"ok": true}
}

// keycode finds a key that types keysym now, and whether it needs Shift.
func (d *x11) keycode(keysym xproto.Keysym) (xproto.Keycode, bool, bool) {
	for i := 0; i+d.perKeycode <= len(d.keysyms); i += d.perKeycode {
		code := xproto.Keycode(int(d.minKeycode) + i/d.perKeycode)
		if d.keysyms[i] == keysym {
			return code, false, true
		}
		if d.perKeycode > 1 && d.keysyms[i+1] == keysym {
			return code, true, true
		}
	}
	return 0, false, false
}

// spare is a keycode nothing is mapped to, for a character no key types: it is given that
// character for the one stroke, the way xdotool types what the layout has no key for.
func (d *x11) spare() (xproto.Keycode, bool) {
	for i := len(d.keysyms) - d.perKeycode; i >= 0; i -= d.perKeycode {
		empty := true
		for j := 0; j < d.perKeycode; j++ {
			if d.keysyms[i+j] != 0 {
				empty = false
				break
			}
		}
		if empty {
			return xproto.Keycode(int(d.minKeycode) + i/d.perKeycode), true
		}
	}
	return 0, false
}

func (d *x11) press(code xproto.Keycode) {
	xtest.FakeInput(d.conn, xproto.KeyPress, byte(code), 0, d.root, 0, 0, 0)
}

func (d *x11) release(code xproto.Keycode) {
	xtest.FakeInput(d.conn, xproto.KeyRelease, byte(code), 0, d.root, 0, 0, 0)
}

func runeKeysym(r rune) xproto.Keysym {
	switch {
	case r == '\n':
		return 0xff0d
	case r == '\t':
		return 0xff09
	case (r >= 0x20 && r <= 0x7e) || (r >= 0xa0 && r <= 0xff):
		return xproto.Keysym(r)
	default:
		return xproto.Keysym(0x01000000 + r)
	}
}

func (d *x11) typeText(request map[string]any) map[string]any {
	text, ok := request["text"].(string)
	if !ok {
		return agent.Failure("type needs text")
	}
	shift, _, _ := d.keycode(0xffe1) // Shift_L
	for _, r := range text {
		keysym := runeKeysym(r)
		code, shifted, found := d.keycode(keysym)
		if !found {
			spare, ok := d.spare()
			if !ok {
				return agent.Failure("no free key to type " + string(r) + " with")
			}
			// Both columns, or a letter given alone is read as its lower and upper case.
			column := make([]xproto.Keysym, d.perKeycode)
			column[0] = keysym
			if d.perKeycode > 1 {
				column[1] = keysym
			}
			xproto.ChangeKeyboardMapping(d.conn, 1, spare, byte(d.perKeycode), column)
			d.sync()
			// The mapping reaches the clients as an event they act on; a beat lets them.
			time.Sleep(20 * time.Millisecond)
			d.press(spare)
			d.release(spare)
			d.sync()
			xproto.ChangeKeyboardMapping(d.conn, 1, spare, byte(d.perKeycode), make([]xproto.Keysym, d.perKeycode))
			continue
		}
		if shifted && shift != 0 {
			d.press(shift)
		}
		d.press(code)
		d.release(code)
		if shifted && shift != 0 {
			d.release(shift)
		}
		d.sync()
		time.Sleep(8 * time.Millisecond)
	}
	return d.sync()
}

var namedKeys = map[string]xproto.Keysym{
	"return": 0xff0d, "enter": 0xff0d, "tab": 0xff09, "space": 0x20, "delete": 0xff08,
	"forwarddelete": 0xffff, "escape": 0xff1b, "esc": 0xff1b, "left": 0xff51, "up": 0xff52,
	"right": 0xff53, "down": 0xff54, "home": 0xff50, "end": 0xff57, "pageup": 0xff55,
	"pagedown": 0xff56,
}

var modifierKeys = map[string]xproto.Keysym{
	"command": 0xffeb, "cmd": 0xffeb, "super": 0xffeb, // Super_L, as the Windows key is on Windows
	"shift": 0xffe1, "option": 0xffe9, "alt": 0xffe9, "control": 0xffe3, "ctrl": 0xffe3,
}

func keysymFor(key string) (xproto.Keysym, bool) {
	lower := strings.ToLower(key)
	if keysym, ok := namedKeys[lower]; ok {
		return keysym, true
	}
	var function int
	if n, _ := fmt.Sscanf(lower, "f%d", &function); n == 1 && function >= 1 && function <= 12 &&
		lower == fmt.Sprintf("f%d", function) {
		return xproto.Keysym(0xffbe + function - 1), true
	}
	runes := []rune(lower)
	if len(runes) == 1 && (unicode.IsLetter(runes[0]) || unicode.IsDigit(runes[0])) {
		return runeKeysym(runes[0]), true
	}
	return 0, false
}

func (d *x11) key(request map[string]any) map[string]any {
	name, _ := request["key"].(string)
	keysym, ok := keysymFor(name)
	if !ok {
		return agent.Failure("unknown key " + name)
	}
	code, _, found := d.keycode(keysym)
	if !found {
		return agent.Failure("no key on this keyboard types " + name)
	}
	var held []xproto.Keycode
	modifiers, _ := request["modifiers"].([]any)
	for _, item := range modifiers {
		modifier, _ := item.(string)
		modifierKeysym, ok := modifierKeys[strings.ToLower(modifier)]
		if !ok {
			return agent.Failure("unknown modifier " + modifier)
		}
		if modifierCode, _, found := d.keycode(modifierKeysym); found {
			held = append(held, modifierCode)
		}
	}
	for _, modifier := range held {
		d.press(modifier)
	}
	d.press(code)
	d.release(code)
	for i := len(held) - 1; i >= 0; i-- {
		d.release(held[i])
	}
	return d.sync()
}
