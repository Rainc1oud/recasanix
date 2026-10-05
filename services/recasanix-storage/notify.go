package main

import (
	"net"
	"os"
	"strings"
)

// notifyReady tells systemd (Type=notify) that the service is up. Without NOTIFY_SOCKET — outside
// systemd, in tests — it does nothing. Written against the protocol directly: a datagram "READY=1".
func notifyReady() {
	sock := os.Getenv("NOTIFY_SOCKET")
	if sock == "" {
		return
	}
	if strings.HasPrefix(sock, "@") { // abstract socket
		sock = "\x00" + sock[1:]
	}
	conn, err := net.Dial("unixgram", sock)
	if err != nil {
		return
	}
	defer conn.Close()
	_, _ = conn.Write([]byte("READY=1"))
}
