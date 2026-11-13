package agent

import (
	"os/exec"
	"syscall"
)

// prepare puts a command in a process group of its own, so a timeout stops what it started too
// rather than leaving a shell's children behind.
func prepare(command *exec.Cmd) {
	command.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	command.Cancel = func() error {
		if command.Process == nil {
			return nil
		}
		return syscall.Kill(-command.Process.Pid, syscall.SIGKILL)
	}
}
