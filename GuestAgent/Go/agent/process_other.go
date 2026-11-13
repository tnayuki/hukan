//go:build !linux

package agent

import "os/exec"

func prepare(command *exec.Cmd) {}
