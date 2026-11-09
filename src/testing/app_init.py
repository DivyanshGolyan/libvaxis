"""Run the native allocation fault under a live controlling-terminal owner."""

import fcntl
import os
import signal
import subprocess
import sys
import termios


def foreground_child():
    os.tcsetpgrp(0, os.getpgrp())
    signal.signal(signal.SIGTTOU, signal.SIG_DFL)


def leader(binary, slave):
    fcntl.ioctl(slave, termios.TIOCSCTTY, 0)
    original = termios.tcgetattr(slave)
    original[3] |= termios.ICANON | termios.ECHO
    termios.tcsetattr(slave, termios.TCSANOW, original)
    signal.signal(signal.SIGTTOU, signal.SIG_IGN)
    child = subprocess.Popen(
        [binary], stdin=slave, stdout=slave, stderr=subprocess.PIPE,
        process_group=0, preexec_fn=foreground_child,
    )
    try:
        _, diagnostic = child.communicate(timeout=5)
        assert child.returncode == 0, (child.returncode, diagnostic)
        assert diagnostic == b"App.init: OutOfMemory\n", diagnostic
        actual = termios.tcgetattr(slave)
        assert actual[3] & termios.ICANON, "App.init left canonical input disabled"
        assert actual[3] & termios.ECHO, "App.init left echo disabled"
        print("App.init OutOfMemory: ICANON and ECHO restored; process exited")
    finally:
        if child.poll() is None:
            child.kill()
            child.communicate(timeout=5)


if __name__ == "__main__":
    if len(sys.argv) == 4 and sys.argv[1] == "--leader":
        leader(sys.argv[2], int(sys.argv[3]))
    else:
        master, slave = os.openpty()
        try:
            subprocess.run(
                [sys.executable, __file__, "--leader", os.path.abspath(sys.argv[1]), str(slave)],
                pass_fds=(slave,), start_new_session=True, check=True, timeout=10,
            )
        finally:
            os.close(master)
            os.close(slave)
