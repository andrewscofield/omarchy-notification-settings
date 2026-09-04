#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Descriptor-relative, hardened storage manager for Omarchy Notifications Settings.
Enforces verified private directory descriptors, no-follow bounded reads, exclusive
temp files, atomic replacement, and descriptor-relative operations.
"""

import sys
import os
import stat
import re
import select
import time

MAX_JSON_BYTES = 32768
MAX_IMG_BYTES = 5242880
MAX_ACTIVE_ENTRIES = 50
MAX_SWEEP_ENTRIES = 100
MAX_HISTORY_ENTRIES = 100

RE_JSON_FILE = re.compile(r"^([0-9]+-[0-9]+\.json|notifications\.json)$")
RE_ACTIVE_FILE = re.compile(r"^[0-9]+-[0-9]+\.json$")
RE_STEM = re.compile(r"^[0-9]+-[0-9]+$")
RE_IMG_STEM = re.compile(r"^[0-9]+-[0-9]+(-[a-zA-Z0-9_]+)?$")



def safe_open_dir(path, create=False):
    """Open and verify a private directory descriptor without following symlinks."""
    if not path or ".." in path:
        return None
    real_path = os.path.abspath(path)
    if not os.path.exists(real_path):
        if create:
            old_umask = os.umask(0o077)
            try:
                os.makedirs(real_path, mode=0o700, exist_ok=True)
            finally:
                os.umask(old_umask)
        else:
            return None

    try:
        dfd = os.open(real_path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
        st = os.fstat(dfd)
        if not stat.S_ISDIR(st.st_mode) or st.st_uid != os.getuid():
            os.close(dfd)
            return None
        if (st.st_mode & 0o777) != 0o700:
            os.fchmod(dfd, 0o700)
        return dfd
    except OSError:
        return None


def read_stdin_bounded(max_bytes=MAX_JSON_BYTES, timeout_sec=2.0):
    """Read bounded payload from stdin without blocking indefinitely."""
    chunks = []
    total = 0
    start = time.monotonic()
    while total < max_bytes:
        remaining_time = max(0.1, timeout_sec - (time.monotonic() - start))
        r, _, _ = select.select([sys.stdin], [], [], remaining_time)
        if not r:
            break
        chunk = sys.stdin.buffer.read1(min(4096, max_bytes - total)) if hasattr(sys.stdin.buffer, "read1") else sys.stdin.buffer.read(min(4096, max_bytes - total))
        if not chunk:
            break
        chunks.append(chunk)
        total += len(chunk)
        # Check if complete JSON reached
        combined = b"".join(chunks)
        if combined.endswith(b"\n") and combined.strip().startswith(b"{") and combined.strip().endswith(b"}"):
            return combined
        if time.monotonic() - start >= timeout_sec:
            break
    return b"".join(chunks)


def cmd_ensure_dirs(base_dir):
    if not base_dir:
        sys.exit(1)
    for sub in ["", "notifications", "notifications/history", "notifications/images"]:
        target = os.path.join(base_dir, sub) if sub else base_dir
        dfd = safe_open_dir(target, create=True)
        if dfd is None:
            sys.stderr.write(f"Security error: failed to verify directory descriptor for {target}\n")
            sys.exit(1)
        os.close(dfd)


def cmd_write_json(dir_path, name):
    if not RE_JSON_FILE.match(name):
        sys.stderr.write(f"Security error: invalid filename {name}\n")
        sys.exit(1)

    dfd = safe_open_dir(dir_path, create=True)
    if dfd is None:
        sys.stderr.write(f"Security error: cannot open directory {dir_path}\n")
        sys.exit(1)

    # Read bounded content from stdin
    data = read_stdin_bounded(MAX_JSON_BYTES)
    if not data:
        os.close(dfd)
        sys.exit(1)

    tmp_name = f".tmp.{os.urandom(8).hex()}"
    try:
        tmp_fd = os.open(tmp_name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600, dir_fd=dfd)
        os.write(tmp_fd, data[:MAX_JSON_BYTES])
        os.close(tmp_fd)
        # Atomic descriptor-relative replacement (renameat)
        os.replace(tmp_name, name, src_dir_fd=dfd, dst_dir_fd=dfd)
    except Exception as e:
        try:
            os.unlink(tmp_name, dir_fd=dfd)
        except OSError:
            pass
        os.close(dfd)
        sys.stderr.write(f"Write error: {e}\n")
        sys.exit(1)
    os.close(dfd)


def cmd_read_active(dir_path):
    dfd = safe_open_dir(dir_path, create=False)
    if dfd is None:
        return

    try:
        entries = [e for e in os.listdir(dfd) if RE_ACTIVE_FILE.match(e)]
    except OSError:
        os.close(dfd)
        return

    # Sort descending by timestamp and enforce hard cardinality limit
    entries.sort(reverse=True)
    entries = entries[:MAX_ACTIVE_ENTRIES]

    for e in entries:
        try:
            fd = os.open(e, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=dfd)
            st = os.fstat(fd)
            if stat.S_ISREG(st.st_mode):
                data = os.read(fd, MAX_JSON_BYTES)
                sys.stdout.buffer.write(data)
                sys.stdout.buffer.write(b"\n")
            os.close(fd)
        except OSError:
            continue

    os.close(dfd)


def cmd_read_history(dir_path, limit_str):
    dfd = safe_open_dir(dir_path, create=False)
    if dfd is None:
        return

    try:
        limit = min(int(limit_str), MAX_HISTORY_ENTRIES)
    except (ValueError, TypeError):
        limit = 50

    try:
        entries = [e for e in os.listdir(dfd) if RE_ACTIVE_FILE.match(e)]
    except OSError:
        os.close(dfd)
        return

    entries.sort(reverse=True)
    entries = entries[:limit]

    for e in entries:
        try:
            fd = os.open(e, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=dfd)
            st = os.fstat(fd)
            if stat.S_ISREG(st.st_mode):
                data = os.read(fd, MAX_JSON_BYTES)
                sys.stdout.buffer.write(data)
                sys.stdout.buffer.write(b"\n")
            os.close(fd)
        except OSError:
            continue

    os.close(dfd)


def cmd_archive(src_dir, dst_dir, name, limit_str, imgs_dir):
    if not RE_ACTIVE_FILE.match(name):
        sys.exit(1)

    try:
        limit = min(int(limit_str), MAX_HISTORY_ENTRIES)
    except (ValueError, TypeError):
        limit = 50

    src_dfd = safe_open_dir(src_dir, create=False)
    dst_dfd = safe_open_dir(dst_dir, create=True)
    if src_dfd is None or dst_dfd is None:
        if src_dfd is not None:
            os.close(src_dfd)
        if dst_dfd is not None:
            os.close(dst_dfd)
        sys.exit(1)

    try:
        # Atomic move across verified directories using descriptor-relative replace
        os.replace(name, name, src_dir_fd=src_dfd, dst_dir_fd=dst_dfd)
    except OSError:
        pass
    os.close(src_dfd)

    # Trim history directory beyond limit
    imgs_dfd = safe_open_dir(imgs_dir, create=False)
    try:
        hist_entries = [e for e in os.listdir(dst_dfd) if RE_ACTIVE_FILE.match(e)]
        hist_entries.sort(reverse=True)
        if len(hist_entries) > limit:
            for stale in hist_entries[limit:limit + MAX_SWEEP_ENTRIES]:
                try:
                    os.unlink(stale, dir_fd=dst_dfd)
                except OSError:
                    pass
                if imgs_dfd is not None:
                    stale_stem = stale.rsplit(".json", 1)[0]
                    if RE_STEM.match(stale_stem):
                        try:
                            for img in os.listdir(imgs_dfd):
                                if img.startswith(f"{stale_stem}-"):
                                    try:
                                        os.unlink(img, dir_fd=imgs_dfd)
                                    except OSError:
                                        pass
                        except OSError:
                            pass
    finally:
        os.close(dst_dfd)
        if imgs_dfd is not None:
            os.close(imgs_dfd)


def cmd_delete(popup_dir, imgs_dir, stem):
    if not RE_STEM.match(stem):
        sys.exit(1)

    popup_dfd = safe_open_dir(popup_dir, create=False)
    if popup_dfd is not None:
        try:
            os.unlink(f"{stem}.json", dir_fd=popup_dfd)
        except OSError:
            pass
        os.close(popup_dfd)

    imgs_dfd = safe_open_dir(imgs_dir, create=False)
    if imgs_dfd is not None:
        try:
            for img in os.listdir(imgs_dfd):
                if img.startswith(f"{stem}-"):
                    try:
                        os.unlink(img, dir_fd=imgs_dfd)
                    except OSError:
                        pass
        except OSError:
            pass
        os.close(imgs_dfd)


def is_safe_image_path(path):
    if not path or ".." in path:
        return False
    try:
        real = os.path.realpath(path)
    except Exception:
        return False
    home = os.path.expanduser("~")
    blocked = [
        os.path.join(home, ".ssh"),
        os.path.join(home, ".gnupg"),
        os.path.join(home, ".local/share/keyrings"),
        os.path.join(home, ".bash_history"),
        os.path.join(home, ".zsh_history"),
        "/etc",
        "/proc",
        "/sys",
        "/dev"
    ]
    for b in blocked:
        if real == b or real.startswith(b + os.sep):
            return False
    return True


def cmd_copy_image(src, imgs_dir, stem):
    if not RE_IMG_STEM.match(stem) or not is_safe_image_path(src):
        sys.exit(0)

    try:
        src_fd = os.open(src, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | getattr(os, "O_NONBLOCK", 0))
        st = os.fstat(src_fd)
        if not stat.S_ISREG(st.st_mode) or st.st_size > MAX_IMG_BYTES:
            os.close(src_fd)
            sys.exit(0)
    except OSError:
        sys.exit(0)


    imgs_dfd = safe_open_dir(imgs_dir, create=True)
    if imgs_dfd is None:
        os.close(src_fd)
        sys.exit(0)

    tmp_name = f".tmp.{os.urandom(8).hex()}"
    try:
        tmp_fd = os.open(tmp_name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600, dir_fd=imgs_dfd)
        copied = 0
        while copied < MAX_IMG_BYTES:
            chunk = os.read(src_fd, 65536)
            if not chunk:
                break
            os.write(tmp_fd, chunk)
            copied += len(chunk)
        os.close(tmp_fd)
        os.close(src_fd)
        os.replace(tmp_name, stem, src_dir_fd=imgs_dfd, dst_dir_fd=imgs_dfd)
    except Exception:
        try:
            os.unlink(tmp_name, dir_fd=imgs_dfd)
        except OSError:
            pass
    finally:
        os.close(imgs_dfd)


def cmd_sweep_images(imgs_dir, popup_dir, hist_dir):
    imgs_dfd = safe_open_dir(imgs_dir, create=False)
    if imgs_dfd is None:
        return
    popup_dfd = safe_open_dir(popup_dir, create=False)
    hist_dfd = safe_open_dir(hist_dir, create=False)

    try:
        entries = os.listdir(imgs_dfd)
    except OSError:
        entries = []

    # Enforce cardinality limit on sweep
    for img in entries[:MAX_SWEEP_ENTRIES]:
        if img.startswith(".tmp."):
            try:
                os.unlink(img, dir_fd=imgs_dfd)
            except OSError:
                pass
            continue

        # Stem format: timestamp-id-role
        parts = img.split("-")
        if len(parts) >= 2:
            base_stem = f"{parts[0]}-{parts[1]}"
            target_json = f"{base_stem}.json"
            exists = False
            if popup_dfd is not None:
                try:
                    os.stat(target_json, dir_fd=popup_dfd)
                    exists = True
                except OSError:
                    pass
            if not exists and hist_dfd is not None:
                try:
                    os.stat(target_json, dir_fd=hist_dfd)
                    exists = True
                except OSError:
                    pass
            if not exists:
                try:
                    os.unlink(img, dir_fd=imgs_dfd)
                except OSError:
                    pass

    os.close(imgs_dfd)
    if popup_dfd is not None:
        os.close(popup_dfd)
    if hist_dfd is not None:
        os.close(hist_dfd)


def cmd_clear_history(hist_dir, imgs_dir, popup_dir):
    hist_dfd = safe_open_dir(hist_dir, create=False)
    if hist_dfd is not None:
        try:
            entries = [e for e in os.listdir(hist_dfd) if RE_ACTIVE_FILE.match(e)]
            for e in entries[:MAX_SWEEP_ENTRIES]:
                try:
                    os.unlink(e, dir_fd=hist_dfd)
                except OSError:
                    pass
        except OSError:
            pass
        os.close(hist_dfd)

    cmd_sweep_images(imgs_dir, popup_dir, hist_dir)


def main():
    if len(sys.argv) < 2:
        sys.exit(1)
    sub = sys.argv[1]

    if sub == "ensure-dirs":
        cmd_ensure_dirs(sys.argv[2] if len(sys.argv) > 2 else "")
    elif sub == "write-json":
        cmd_write_json(sys.argv[2], sys.argv[3])
    elif sub == "read-active":
        cmd_read_active(sys.argv[2])
    elif sub == "read-history":
        cmd_read_history(sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else "50")
    elif sub == "archive":
        cmd_archive(sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5], sys.argv[6])
    elif sub == "delete":
        cmd_delete(sys.argv[2], sys.argv[3], sys.argv[4])
    elif sub == "copy-image":
        cmd_copy_image(sys.argv[2], sys.argv[3], sys.argv[4])
    elif sub == "sweep-images":
        cmd_sweep_images(sys.argv[2], sys.argv[3], sys.argv[4])
    elif sub == "clear-history":
        cmd_clear_history(sys.argv[2], sys.argv[3], sys.argv[4])
    else:
        sys.stderr.write(f"Unknown storage command: {sub}\n")
        sys.exit(1)


if __name__ == "__main__":
    main()
