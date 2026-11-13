package agent

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestServeAnswersOneLine(t *testing.T) {
	var out bytes.Buffer
	(&Agent{Mode: "root"}).Serve(struct {
		io.Reader
		io.Writer
	}{strings.NewReader(`{"op":"ping"}` + "\n"), &out})
	if !strings.HasSuffix(out.String(), "\n") || strings.Count(out.String(), "\n") != 1 {
		t.Fatalf("not one line: %q", out.String())
	}
	var answer map[string]any
	if err := json.Unmarshal(out.Bytes(), &answer); err != nil {
		t.Fatal(err)
	}
	if answer["ok"] != true || answer["mode"] != "root" {
		t.Fatalf("ping answered %v", answer)
	}
}

func TestExecCarriesStdinAndExit(t *testing.T) {
	answer := (&Agent{}).Handle(map[string]any{
		"op": "exec", "argv": []any{"/bin/sh", "-c", "cat; echo err >&2; exit 3"},
		"stdin": base64.StdEncoding.EncodeToString([]byte("in")),
	})
	if answer["exit"] != 3 || decode(t, answer["stdout"]) != "in" || decode(t, answer["stderr"]) != "err\n" {
		t.Fatalf("exec answered %v", answer)
	}
}

func TestExecWithSomethingLeftRunningAnswers(t *testing.T) {
	answer := (&Agent{}).Handle(map[string]any{
		"op": "exec", "argv": []any{"/bin/sh", "-c", "sleep 30 & echo started"},
	})
	if answer["ok"] != true || answer["exit"] != 0 || decode(t, answer["stdout"]) != "started\n" {
		t.Fatalf("exec answered %v", answer)
	}
}

func TestExecTimesOut(t *testing.T) {
	answer := (&Agent{}).Handle(map[string]any{
		"op": "exec", "argv": []any{"/bin/sh", "-c", "sleep 30"}, "timeout": 0.2,
	})
	if answer["timedOut"] != true {
		t.Fatalf("exec answered %v", answer)
	}
}

func TestWriteThenRead(t *testing.T) {
	path := filepath.Join(t.TempDir(), "a", "b.txt")
	written := (&Agent{}).Handle(map[string]any{
		"op": "write", "path": path, "data": base64.StdEncoding.EncodeToString([]byte("hello")),
		"mode": float64(0o600),
	})
	if written["ok"] != true {
		t.Fatalf("write answered %v", written)
	}
	if info, _ := os.Stat(path); info.Mode().Perm() != 0o600 {
		t.Fatalf("mode %v", info.Mode())
	}
	read := (&Agent{}).Handle(map[string]any{"op": "read", "path": path})
	if decode(t, read["data"]) != "hello" {
		t.Fatalf("read answered %v", read)
	}
}

func TestUnknownOpGoesToExtraThenFails(t *testing.T) {
	a := &Agent{Extra: func(request map[string]any) (map[string]any, bool) {
		if request["op"] == "display" {
			return map[string]any{"ok": true}, true
		}
		return nil, false
	}}
	if a.Handle(map[string]any{"op": "display"})["ok"] != true {
		t.Fatal("extra op not answered")
	}
	if a.Handle(map[string]any{"op": "nonsense"})["ok"] != false {
		t.Fatal("unknown op answered")
	}
}

func decode(t *testing.T, value any) string {
	t.Helper()
	data, err := base64.StdEncoding.DecodeString(value.(string))
	if err != nil {
		t.Fatal(err)
	}
	return string(data)
}
