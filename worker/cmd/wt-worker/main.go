// Command wt-worker is the optional WindowsTweaker background worker.
//
// It speaks the versioned JSON Lines protocol documented in docs/WORKER.md on stdin/stdout,
// writes diagnostics to stderr, never reads terminal input, never writes ANSI sequences and
// never changes a Windows setting. It is started by the PowerShell interface as an
// unprivileged child process; it is not a service, a listener or a scheduled task.
package main

import (
	"context"
	"flag"
	"log"
	"os"
	"os/signal"
	"syscall"

	"wintweaker.dev/worker/internal/server"
)

// Version is stamped with -ldflags "-X main.Version=..." when packaging.
var Version = "0.1.0"

func main() {
	logLevel := flag.Bool("verbose", false, "log every request to stderr")
	showVersion := flag.Bool("version", false, "print the worker version and exit")
	flag.Parse()

	if *showVersion {
		os.Stdout.WriteString("wt-worker " + Version + "\n")
		return
	}

	logger := log.New(os.Stderr, "wt-worker: ", log.LstdFlags|log.LUTC)

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	worker := server.New(os.Stdin, os.Stdout, logger, server.DefaultInfo(Version))
	if *logLevel {
		logger.Print("verbose mode")
	}

	if err := worker.Run(ctx); err != nil {
		logger.Printf("fatal: %v", err)
		os.Exit(1)
	}
}
