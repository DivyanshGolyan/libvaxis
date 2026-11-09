"""Distinguish terminal-reader EOF from an application's own EOF error."""

import fcntl
import os
import select
import struct
import subprocess
import sys
import termios
import time


def controlling_terminal():
    fcntl.ioctl(0, termios.TIOCSCTTY, 0)


def run(binary, hangup):
    master, slave = os.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
    child = None
    try:
        child = subprocess.Popen(
            [binary], stdin=slave, stdout=slave, stderr=subprocess.PIPE,
            start_new_session=True, preexec_fn=controlling_terminal,
        )
        output = bytearray()
        answered = False
        deadline = time.monotonic() + 5
        while b"ready" not in output or b"\x1b[?2026l" not in output:
            remaining = deadline - time.monotonic()
            assert remaining > 0, (child.poll(), output)
            if select.select([master], [], [], remaining)[0]:
                output.extend(os.read(master, 65536))
            assert len(output) < 1024 * 1024
            if not answered and b"\x1b[c" in output:
                os.write(master, b"\x1b[?1;2c")
                answered = True
        if hangup:
            os.close(master)
            master = None
        else:
            os.write(master, b"\r")
        _, diagnostic = child.communicate(timeout=5)
        if hangup:
            assert child.returncode == 0, (child.returncode, diagnostic)
            assert b"reader quit\n" in diagnostic, diagnostic
            assert b"EndOfStream" not in diagnostic, diagnostic
        else:
            assert child.returncode == 1, (child.returncode, diagnostic)
            assert b"error: EndOfStream\n" in diagnostic, diagnostic
            assert b"reader quit" not in diagnostic, diagnostic
        print(f"App EOF: hangup={hangup}, exit={child.returncode}")
    finally:
        if child is not None and child.poll() is None:
            child.kill()
            child.communicate(timeout=5)
        if master is not None:
            os.close(master)
        os.close(slave)


if __name__ == "__main__":
    binary = os.path.abspath(sys.argv[1])
    run(binary, False)
    run(binary, True)
