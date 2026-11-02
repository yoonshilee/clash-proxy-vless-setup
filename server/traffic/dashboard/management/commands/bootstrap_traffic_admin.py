"""Create a dashboard administrator and store its initial password privately."""

import os
from pathlib import Path
import secrets
import stat

from django.contrib.auth import get_user_model
from django.core.management.base import BaseCommand, CommandError
from django.db import transaction

ADMIN_USERNAME = "admin"
PASSWORD_PREFIX = "password: "


class Command(BaseCommand):
    """Create one administrator without writing credentials to the journal."""

    def add_arguments(self, parser):
        """Require the root-owned destination for the initial credentials.

        Args:
            parser: Django command-line argument parser.
        """
        parser.add_argument("--credentials", required=True, type=Path)

    def handle(self, *args, **options):
        """Initialize the user without replacing an existing administrator.

        Args:
            *args: Positional command arguments.
            **options: Parsed command options.
        """
        path = options["credentials"]
        users = get_user_model().objects
        password = None
        if path.exists() or path.is_symlink():
            info = path.lstat()
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or stat.S_IMODE(info.st_mode) & 0o077:
                raise CommandError("The credentials file must be private and owned by the current user.")
            lines = path.read_text().splitlines()
            if len(lines) != 2 or lines[0] != f"username: {ADMIN_USERNAME}" or not lines[1].startswith(PASSWORD_PREFIX):
                raise CommandError("The existing credentials file is invalid.")
            password = lines[1].removeprefix(PASSWORD_PREFIX)
        user = users.filter(username=ADMIN_USERNAME).first()
        if user:
            if not password or not user.check_password(password):
                raise CommandError("The existing administrator password does not match the credentials file.")
            self.stdout.write("The existing administrator was preserved.")
            return
        if password is None:
            password = secrets.token_urlsafe(24)
            fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(fd, "w") as stream:
                stream.write(f"username: {ADMIN_USERNAME}\n{PASSWORD_PREFIX}{password}\n")
                stream.flush()
                os.fsync(stream.fileno())
        if not password:
            raise CommandError("The initial password is empty.")
        with transaction.atomic():
            users.create_user(username=ADMIN_USERNAME, password=password)
        self.stdout.write("Initial administrator created; credentials are stored in the specified private file.")
