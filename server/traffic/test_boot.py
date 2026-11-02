"""Test boot recovery without starting services or modifying the firewall."""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


class BootRecoveryTests(unittest.TestCase):
    """Exercise service startup and firewall refusal using isolated stubs."""

    def setUp(self):
        """Create a temporary application and fake systemd commands."""
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.app = self.root / "app"
        self.app.mkdir()
        self.bin = self.root / "bin"
        self.bin.mkdir()
        shutil.copy(Path(__file__).with_name("start-at-boot.sh"), self.app)
        systemctl = self.bin / "systemctl"
        systemctl.write_text('#!/bin/bash\ncase "$3" in ufw.service|xray.service) exit 0;; *) test -e "$STUB_STATE/$3";; esac\n')
        systemctl.chmod(0o755)
        (self.app / "gate_setup.py").write_text('import pathlib, sys\npathlib.Path(sys.argv[-1]).write_text("synthetic")\n')
        (self.app / "gate.py").write_text('import os\nasync def firewall_ready(value):\n return value == "synthetic" and not os.environ.get("FAIL_FIREWALL")\n')
        for script, unit in (("start-preview.sh", "clash-traffic-preview.service"), ("start-original-shadow.sh", "clash-traffic-original.service"), ("start-gate.sh", "clash-traffic-gate.service")):
            (self.app / script).write_text(f'#!/bin/bash\necho {unit} >> "$STUB_STATE/started"\ntouch "$STUB_STATE/{unit}"\n')
        self.env = dict(os.environ, PATH=f"{self.bin}:{os.environ['PATH']}", STUB_STATE=str(self.root), TRAFFIC_GATE_BOOT_RUNTIME_DIR=str(self.root))

    def run_boot(self):
        """Run the boot script against the isolated stubs."""
        return subprocess.run(["bash", str(self.app / "start-at-boot.sh")], env=self.env, capture_output=True, text=True)

    def test_starts_once_and_reuses_verified_gate(self):
        """Start all three services once, including on a retry."""
        self.assertEqual(self.run_boot().returncode, 0)
        self.assertEqual(self.run_boot().returncode, 0)
        self.assertEqual(len((self.root / "started").read_text().splitlines()), 3)

    def test_firewall_failure_does_not_start_services(self):
        """Refuse to start a listener when firewall verification fails."""
        self.env["FAIL_FIREWALL"] = "1"
        self.assertNotEqual(self.run_boot().returncode, 0)
        self.assertFalse((self.root / "started").exists())
