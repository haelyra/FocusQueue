#!/usr/bin/env python3
"""Small cross-platform advisory file-lock adapter."""

from __future__ import annotations

import os
from typing import IO, Any


def acquire_exclusive_file_lock(handle: IO[Any]) -> None:
    """Block until an exclusive one-byte lock is held for the life of the handle."""
    if os.name == "nt":
        import msvcrt

        handle.seek(0, os.SEEK_END)
        if handle.tell() == 0:
            handle.write("\0")
            handle.flush()
        handle.seek(0)
        msvcrt.locking(handle.fileno(), msvcrt.LK_LOCK, 1)
        return

    import fcntl

    fcntl.flock(handle.fileno(), fcntl.LOCK_EX)


def release_file_lock(handle: IO[Any]) -> None:
    """Release a lock taken by acquire_exclusive_file_lock before the handle closes."""
    if os.name == "nt":
        import msvcrt

        handle.seek(0)
        msvcrt.locking(handle.fileno(), msvcrt.LK_UNLCK, 1)
        return

    import fcntl

    fcntl.flock(handle.fileno(), fcntl.LOCK_UN)
