#!/usr/bin/env python3
# SOURCE: inbox_flock.py
# AUTHOR: STARFLEET
# STARDATE: 2026.110
# STATUS: primitive fleet-pilot

import fcntl
import os
from contextlib import contextmanager


@contextmanager
def exclusive_lock(path):
    """flock exclusif non-blocking. Raise BlockingIOError si deja pris."""
    fd = os.open(path, os.O_CREAT | os.O_RDWR, 0o644)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        yield fd
        fcntl.flock(fd, fcntl.LOCK_UN)
    finally:
        os.close(fd)
