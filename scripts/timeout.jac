"""Portable gtimeout replacement: run a command under a wall-clock limit (exit 124 on timeout)."""
import sys;
import subprocess;

def eprint(msg: str) {
    err: any = sys.stderr;
    err.write(msg + "\n");
}

def run_with_timeout(argv: list[str], seconds: float) -> int {
    try {
        return subprocess.run(argv, timeout=seconds).returncode;
    } except subprocess.TimeoutExpired {
        return 124;
    }
}

with entry {
    args: list[str] = sys.argv;
    # strict arg check: under `jac test` argv is the jac CLI's own args, so never dispatch loosely
    if len(args) >= 3 and args[1].replace(".", "", 1).isdigit() {
        sys.exit(run_with_timeout(args[2:], float(args[1])));
    }
    eprint("usage: jac run timeout.jac <seconds> <cmd> [args...]");
    sys.exit(2);
}
