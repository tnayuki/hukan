package main

// The keys of a JIS Mac that Virtualization.framework's keyboard drops, for the root half: ¥ and
// ろ reach the guest as no key at all, since the keyboard VZ gives a guest is ANSI whatever the
// Mac's is. So they are typed on a keyboard of the agent's own, made with /dev/uinput, beside VZ's
// — everything else still goes through VZ by position, and a Shift held there combines with a key
// from here, the desktop reading both devices as one seat.
//
//	{"op":"jis_key","key":"yen"|"ro","down":true|false}  -> {"ok":true}
//	{"op":"jis_key","key":"next_source"}                -> {"ok":true}
//
// 英数 and かな are not keys here but a choice of input source, which the host makes, and the
// next source is GNOME's own Super+Space — typed on this keyboard, so it reaches a session on
// Wayland as well as one on X11.

import (
	"encoding/binary"
	"fmt"
	"os"
	"sync"
	"time"
	"unsafe"

	"golang.org/x/sys/unix"

	"hukan/guestagent/agent"
)

const (
	uiSetEvBit  = 0x40045564
	uiSetKeyBit = 0x40045565
	uiDevSetup  = 0x405C5503
	uiDevCreate = 0x5501
	evSyn       = 0
	evKey       = 1
)

var jisKeys = map[string]uint16{
	"yen": 124, // KEY_YEN
	"ro":  89,  // KEY_RO
}

const (
	keyLeftMeta = 125
	keySpace    = 57
)

// keyA is declared too, though nothing types it: udev calls a device a keyboard only when it has
// keys among the first few dozen, and a device that is not one is not handed to the desktop.
const keyA = 30

var keyboard struct {
	sync.Mutex
	file *os.File
}

// The device is made when the root half starts, not at the first key: the desktop picks a new
// device up a beat after it appears, and a key typed into that beat would be lost.
func init() {
	if len(os.Args) > 1 && os.Args[1] == "--root" {
		go func() {
			keyboard.Lock()
			defer keyboard.Unlock()
			keyboard.file, _ = makeKeyboard()
		}()
	}
}

// extras answers what this system adds to the common requests: the JIS keys, then the screen.
func extras(request map[string]any) (map[string]any, bool) {
	if request["op"] == "jis_key" {
		return jisKey(request), true
	}
	return screen(request)
}

func jisKey(request map[string]any) map[string]any {
	name, _ := request["key"].(string)
	code, known := jisKeys[name]
	if !known && name != "next_source" {
		return agent.Failure("jis_key needs a key: yen, ro or next_source")
	}
	down, _ := request["down"].(bool)
	keyboard.Lock()
	defer keyboard.Unlock()
	if keyboard.file == nil {
		file, err := makeKeyboard()
		if err != nil {
			return agent.Failure(err.Error())
		}
		keyboard.file = file
	}
	strokes := [][2]int32{{int32(code), 0}}
	if down {
		strokes[0][1] = 1
	}
	if name == "next_source" {
		strokes = [][2]int32{{keyLeftMeta, 1}, {keySpace, 1}, {keySpace, 0}, {keyLeftMeta, 0}}
	}
	for i, stroke := range strokes {
		// A beat between strokes, as a hand leaves one: written back to back, the desktop took the
		// Space before it had taken the Super, and typed a space.
		if i > 0 {
			time.Sleep(30 * time.Millisecond)
		}
		if err := emit(keyboard.file, evKey, uint16(stroke[0]), stroke[1]); err != nil {
			return agent.Failure(err.Error())
		}
		if err := emit(keyboard.file, evSyn, 0, 0); err != nil {
			return agent.Failure(err.Error())
		}
	}
	return map[string]any{"ok": true}
}

func makeKeyboard() (*os.File, error) {
	file, err := os.OpenFile("/dev/uinput", os.O_WRONLY, 0)
	if err != nil {
		return nil, fmt.Errorf("cannot open /dev/uinput: %v", err)
	}
	fd := int(file.Fd())
	fail := func(what string, err error) (*os.File, error) {
		file.Close()
		return nil, fmt.Errorf("uinput %s: %v", what, err)
	}
	if err := unix.IoctlSetInt(fd, uiSetEvBit, evKey); err != nil {
		return fail("event bit", err)
	}
	for _, code := range []uint16{jisKeys["yen"], jisKeys["ro"], keyLeftMeta, keySpace, keyA} {
		if err := unix.IoctlSetInt(fd, uiSetKeyBit, int(code)); err != nil {
			return fail("key bit", err)
		}
	}
	// struct uinput_setup: the input_id (bus, vendor, product, version), a name, ff_effects_max.
	var setup [92]byte
	binary.LittleEndian.PutUint16(setup[0:], 0x06) // BUS_VIRTUAL
	binary.LittleEndian.PutUint16(setup[2:], 0x1209)
	binary.LittleEndian.PutUint16(setup[4:], 0x4B4E)
	binary.LittleEndian.PutUint16(setup[6:], 1)
	copy(setup[8:88], "hukan JIS keys")
	if _, _, errno := unix.Syscall(
		unix.SYS_IOCTL, uintptr(fd), uiDevSetup, uintptr(unsafe.Pointer(&setup[0]))); errno != 0 {
		return fail("setup", errno)
	}
	if _, _, errno := unix.Syscall(unix.SYS_IOCTL, uintptr(fd), uiDevCreate, 0); errno != 0 {
		return fail("create", errno)
	}
	return file, nil
}

// emit writes one struct input_event: a timeval, then type, code and value.
func emit(file *os.File, kind, code uint16, value int32) error {
	var event [24]byte
	now := time.Now()
	binary.LittleEndian.PutUint64(event[0:], uint64(now.Unix()))
	binary.LittleEndian.PutUint64(event[8:], uint64(now.Nanosecond()/1000))
	binary.LittleEndian.PutUint16(event[16:], kind)
	binary.LittleEndian.PutUint16(event[18:], code)
	binary.LittleEndian.PutUint32(event[20:], uint32(value))
	_, err := file.Write(event[:])
	return err
}
