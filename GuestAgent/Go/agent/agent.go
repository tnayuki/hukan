// Package agent is what every hukan guest agent says, whatever system it runs on: one JSON
// request a line, one JSON answer a line, over a connection the host opened. What a system adds
// is how it is reached — vsock on Linux — and the requests only it can answer; this is the part
// that is the same everywhere, kept apart so the next agent written in Go starts from it.
//
//	{"op":"ping"}                                  -> {"ok":true,"version":"1","mode":"user"}
//	{"op":"exec","argv":[...],"cwd":?,"env":{}?,"stdin":"<base64>"?,"timeout":seconds?}
//	                                               -> {"ok":true,"exit":0,"stdout":"<b64>","stderr":"<b64>","timedOut":false}
//	{"op":"read","path":...}                       -> {"ok":true,"data":"<base64>"}
//	{"op":"write","path":...,"data":"<b64>","mode":420?}  -> {"ok":true}
//
// A failure is {"ok":false,"error":"..."}.
package agent

import (
	"bufio"
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"time"
)

// Version is what a ping answers. The host does not compare it — it compares the binary itself —
// so it only has to change when someone reading a ping by hand needs to tell two apart.
const Version = "1"

// MaxRequest is the most one request line may be: a file written whole, in base64, with room.
const MaxRequest = 512 << 20

// Agent answers requests in one mode, "user" or "root".
type Agent struct {
	Mode string
	// Extra answers the requests a system adds; nil, or false for one it does not know.
	Extra func(request map[string]any) (map[string]any, bool)
}

// Serve reads one request from conn, answers it, and returns.
func (a *Agent) Serve(conn io.ReadWriter) {
	line, err := bufio.NewReaderSize(conn, 64<<10).ReadBytes('\n')
	if err != nil && !(errors.Is(err, io.EOF) && len(line) > 0) {
		return
	}
	if len(line) > MaxRequest {
		Respond(conn, Failure("request too large"))
		return
	}
	var request map[string]any
	if json.Unmarshal(line, &request) != nil {
		Respond(conn, Failure("malformed request"))
		return
	}
	Respond(conn, a.Handle(request))
}

// Handle answers one request.
func (a *Agent) Handle(request map[string]any) map[string]any {
	switch request["op"] {
	case "ping":
		return map[string]any{"ok": true, "version": Version, "mode": a.Mode}
	case "exec":
		return a.execute(request)
	case "read":
		path, _ := request["path"].(string)
		if path == "" {
			return Failure("read needs a path")
		}
		data, err := os.ReadFile(path)
		if err != nil {
			return Failure(fmt.Sprintf("cannot read %s: %v", path, err))
		}
		return map[string]any{"ok": true, "data": base64.StdEncoding.EncodeToString(data)}
	case "write":
		path, _ := request["path"].(string)
		encoded, _ := request["data"].(string)
		data, err := base64.StdEncoding.DecodeString(encoded)
		if path == "" || err != nil {
			return Failure("write needs a path and base64 data")
		}
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			return Failure(err.Error())
		}
		mode := os.FileMode(0o644)
		if value, ok := request["mode"].(float64); ok {
			mode = os.FileMode(int(value))
		}
		if err := os.WriteFile(path, data, mode); err != nil {
			return Failure(err.Error())
		}
		// WriteFile leaves the mode of a file that was already there alone.
		if _, given := request["mode"]; given {
			if err := os.Chmod(path, mode); err != nil {
				return Failure(err.Error())
			}
		}
		return map[string]any{"ok": true}
	}
	if a.Extra != nil {
		if answer, ok := a.Extra(request); ok {
			return answer
		}
	}
	return Failure("unknown op")
}

func (a *Agent) execute(request map[string]any) map[string]any {
	raw, _ := request["argv"].([]any)
	argv := make([]string, 0, len(raw))
	for _, item := range raw {
		text, ok := item.(string)
		if !ok {
			return Failure("exec needs argv of strings")
		}
		argv = append(argv, text)
	}
	if len(argv) == 0 {
		return Failure("exec needs argv")
	}
	timeout := 600.0
	if value, ok := request["timeout"].(float64); ok && value > 0 {
		timeout = value
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Duration(timeout*float64(time.Second)))
	defer cancel()

	// The PATH is this process's own, set once by main: the lookup of argv[0] reads it there.
	environment := os.Environ()
	if extra, ok := request["env"].(map[string]any); ok {
		for key, value := range extra {
			if text, ok := value.(string); ok {
				environment = append(environment, key+"="+text)
			}
		}
	}
	command := exec.CommandContext(ctx, argv[0], argv[1:]...)
	command.Env = environment
	prepare(command)
	if cwd, ok := request["cwd"].(string); ok && cwd != "" {
		command.Dir = cwd
	}
	if encoded, ok := request["stdin"].(string); ok {
		data, err := base64.StdEncoding.DecodeString(encoded)
		if err != nil {
			return Failure("stdin is not base64")
		}
		command.Stdin = bytes.NewReader(data)
	}
	var stdout, stderr bytes.Buffer
	command.Stdout = &stdout
	command.Stderr = &stderr
	// What a command left running in the background must not hold the answer back for good.
	command.WaitDelay = 5 * time.Second
	err := command.Run()
	timedOut := errors.Is(ctx.Err(), context.DeadlineExceeded)
	// The command is done but something it started still holds its output — `app &` — so the
	// output is what there was by then, and the exit is the command's.
	if errors.Is(err, exec.ErrWaitDelay) {
		err = nil
		if command.ProcessState != nil && !command.ProcessState.Success() {
			err = &exec.ExitError{ProcessState: command.ProcessState}
		}
	}
	exit := 0
	if err != nil {
		var exitError *exec.ExitError
		switch {
		case errors.As(err, &exitError):
			exit = exitError.ExitCode()
		case timedOut:
			exit = -1
		default:
			return Failure(fmt.Sprintf("cannot run %s: %v", argv[0], err))
		}
	}
	return map[string]any{
		"ok": true, "exit": exit,
		"stdout":   base64.StdEncoding.EncodeToString(stdout.Bytes()),
		"stderr":   base64.StdEncoding.EncodeToString(stderr.Bytes()),
		"timedOut": timedOut,
	}
}

// Hello is what an agent says to the host when it comes up, and again every fifteen seconds.
func Hello(mode string) map[string]any {
	return map[string]any{"hello": mode, "version": Version}
}

// Failure is an answer saying why not.
func Failure(message string) map[string]any {
	return map[string]any{"ok": false, "error": message}
}

// Respond writes one answer as one line.
func Respond(conn io.Writer, answer map[string]any) {
	data, err := json.Marshal(answer)
	if err != nil {
		data, _ = json.Marshal(Failure("the answer could not be encoded"))
	}
	conn.Write(append(data, '\n'))
}
