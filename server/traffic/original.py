"""Supervise an isolated original-node shadow without changing network routing."""

import os
from pathlib import Path
import signal
import subprocess
import sys
import time

from dashboard.constants import SOURCE_ORIGINAL
from prepare_original import COLLECTOR_PORT, HEALTH_TARGET_PORT, XRAY

ROOT = Path(__file__).resolve().parent
DATA_DIR = Path(os.environ["TRAFFIC_DATA_DIR"]).resolve()


def main():
    """Run the original-node collector, shadow listener, and health client."""
    database = DATA_DIR / "traffic.sqlite3"
    server = DATA_DIR / "original-server.json"
    client = DATA_DIR / "original-client.json"
    if not all(path.is_file() for path in (database, server, client)):
        raise RuntimeError("Original-node shadow files are missing")
    commands = [
        [sys.executable, str(ROOT / "collector_async.py"), "--database", str(database), "--port", str(COLLECTOR_PORT), "--source", SOURCE_ORIGINAL, "--health-port", str(HEALTH_TARGET_PORT)],
        [XRAY, "run", "-c", str(server)],
        [XRAY, "run", "-c", str(client)],
    ]
    processes = []
    stopping = False

    def stop(_signum, _frame):
        """Request a shutdown of the shadow processes.

        Args:
            _signum: Signal number.
            _frame: Interrupted stack frame.
        """
        nonlocal stopping
        stopping = True

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    try:
        for command in commands:
            processes.append(subprocess.Popen(command, cwd=ROOT))
        while not stopping:
            if any(process.poll() is not None for process in processes):
                raise RuntimeError("An original-node shadow process exited")
            time.sleep(1)
    finally:
        for process in reversed(processes):
            if process.poll() is None:
                process.terminate()
        for process in reversed(processes):
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()


if __name__ == "__main__":
    main()
