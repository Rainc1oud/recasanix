package main

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"strings"
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
	stderr := &limitedBuffer{max: maxStderr}
	cmd.Stdout, cmd.Stderr = out, stderr
	err := cmd.Run()
	if out.exceeded {
		return nil, errOutputTooLarge
	}
	if err != nil {
		err = withStderr(err, stderr.buf.String())
	}
	return out.buf.Bytes(), err
}

// maxStderr bounds what a failing command says; its last lines go into the error.
const maxStderr = 16 << 10

// withStderr adds the last lines a failed command wrote to its error (for the log and a job's error).
func withStderr(err error, stderr string) error {
	lines := strings.Split(strings.TrimSpace(stderr), "\n")
	if len(lines) == 1 && lines[0] == "" {
		return err
	}
	if len(lines) > 3 {
		lines = lines[len(lines)-3:]
	}
	return fmt.Errorf("%w: %s", err, strings.Join(lines, " | "))
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
