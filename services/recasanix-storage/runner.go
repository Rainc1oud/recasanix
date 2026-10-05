package main

import (
	"bytes"
	"context"
	"errors"
	"os"
	"os/exec"
	"time"
)

// Runner runs an external program. It takes an argument vector, never a shell string: nothing that
// arrives over HTTP is ever interpreted by a shell, and in this service nothing that arrives over
// HTTP reaches a command line at all.
type Runner interface {
	// Run returns the program's standard output. When the program exits non-zero the output is still
	// returned together with the error, because some tools (smartctl) report through both.
	Run(ctx context.Context, name string, args ...string) ([]byte, error)
}

// maxOutput bounds what a child process may hand back.
const maxOutput = 8 << 20

var errOutputTooLarge = errors.New("command output too large")

type execRunner struct {
	timeout time.Duration
}

func (r execRunner) Run(ctx context.Context, name string, args ...string) ([]byte, error) {
	ctx, cancel := context.WithTimeout(ctx, r.timeout)
	defer cancel()

	cmd := exec.CommandContext(ctx, name, args...)
	// A minimal, predictable environment: tools are found through PATH (the unit's `path`), and
	// their output must not depend on the host's locale.
	cmd.Env = []string{"PATH=" + os.Getenv("PATH"), "LC_ALL=C"}
	out := &limitedBuffer{max: maxOutput}
	cmd.Stdout = out
	err := cmd.Run()
	if out.exceeded {
		return nil, errOutputTooLarge
	}
	return out.buf.Bytes(), err
}

// limitedBuffer stops accepting data past max instead of growing without bound.
type limitedBuffer struct {
	buf      bytes.Buffer
	max      int
	exceeded bool
}

func (l *limitedBuffer) Write(p []byte) (int, error) {
	if l.buf.Len()+len(p) > l.max {
		l.exceeded = true
		return 0, errOutputTooLarge
	}
	return l.buf.Write(p)
}
