// hukan-guest-agent for a Linux guest: what hukan reaches it through, over vsock.
//
// It runs twice from one binary, as the macOS agent does: as a systemd user service in the
// logged-in user's graphical session (`--user`, port 7737), where a command runs as the person
// would with the desktop there, and as a system service (`--root`, port 7738) for what needs an
// administrator. Neither listens on the network: vsock is a channel between the guest and the host
// running it, and a connection from anywhere but the host (CID 2) is closed unanswered, so nothing
// inside the guest can borrow the root half. The user half also answers for the screen, over
// X11 (screen_linux.go).
//
// Built by Vendor/build-linux-agent.sh into Resources/hukan-guest-agent-linux; hukan puts it into
// a template while making it, and replaces it at boot when it differs from the one it ships.
package main

import (
	"encoding/json"
	"fmt"
	"os"
	"time"

	"golang.org/x/sys/unix"

	"hukan/guestagent/agent"
)

const (
	hostCID   = 2
	userPort  = 7737
	rootPort  = 7738
	helloPort = 7739
)

func main() {
	root := len(os.Args) > 1 && os.Args[1] == "--root"
	mode, port := "user", uint32(userPort)
	if root {
		mode, port = "root", uint32(rootPort)
	}
	// What a login's PATH would be: a bare name is looked up the way a shell would look it up.
	os.Setenv("PATH", "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin")

	listener, err := unix.Socket(unix.AF_VSOCK, unix.SOCK_STREAM|unix.SOCK_CLOEXEC, 0)
	if err != nil {
		fail("socket: %v", err)
	}
	if err := unix.Bind(listener, &unix.SockaddrVM{CID: unix.VMADDR_CID_ANY, Port: port}); err != nil {
		fail("bind %d: %v", port, err)
	}
	if err := unix.Listen(listener, 16); err != nil {
		fail("listen: %v", err)
	}

	// The host is told this half is up rather than finding out by connecting: a connection to a
	// guest port nobody listens on has crashed Virtualization.framework in the host, so hukan only
	// dials an agent that has said it is there. Again every fifteen seconds, since a hukan that
	// restored the machine from a saved state did not hear the first one.
	go func() {
		for {
			announce(mode)
			time.Sleep(15 * time.Second)
		}
	}()

	served := &agent.Agent{Mode: mode, Extra: screen}
	for {
		client, peer, err := unix.Accept4(listener, unix.SOCK_CLOEXEC)
		if err != nil {
			if err == unix.EINTR || err == unix.ECONNABORTED {
				continue
			}
			fail("accept: %v", err)
		}
		// The host and nothing else: a process in the guest connecting to its own vsock port must
		// not be handed a root shell.
		if vm, ok := peer.(*unix.SockaddrVM); !ok || vm.CID != hostCID {
			unix.Close(client)
			continue
		}
		go func() {
			connection := os.NewFile(uintptr(client), "vsock")
			defer connection.Close()
			served.Serve(connection)
		}()
	}
}

func announce(mode string) {
	fd, err := unix.Socket(unix.AF_VSOCK, unix.SOCK_STREAM|unix.SOCK_CLOEXEC, 0)
	if err != nil {
		return
	}
	connection := os.NewFile(uintptr(fd), "hello")
	defer connection.Close()
	if unix.Connect(fd, &unix.SockaddrVM{CID: hostCID, Port: helloPort}) != nil {
		return
	}
	data, _ := json.Marshal(agent.Hello(mode))
	connection.Write(append(data, '\n'))
}

func fail(format string, values ...any) {
	fmt.Fprintf(os.Stderr, "hukan-guest-agent: "+format+"\n", values...)
	os.Exit(1)
}
