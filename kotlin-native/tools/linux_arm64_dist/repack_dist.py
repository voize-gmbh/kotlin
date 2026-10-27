#!/usr/bin/env python3
"""
Archive helpers for repack_with_official_stdlib.sh.

  platform-diff <official-linux.tar.gz> <official-macos.tar.gz> <target>...
      Compares the regular files of klib/platform/<target> in two official distributions.
      Exits 0 if they are byte-identical, 3 if they differ, and prints the differing files grouped by name.
  repack <original.tar.gz> <root> <out.tar.gz> <changed-prefix>...
      Packs <root>/<top-level dir> into <out.tar.gz> in the entry order of <original.tar.gz>. Only paths under a
      changed prefix may be added or removed. Entries keep their original modes and are written with the header
      layout and reproducible attributes of Gradle's archives (mtime 86400, uid/gid 0, no user or group names,
      GNU long-name entries), so unchanged entries are byte-identical. The gzip header has no name and mtime 0.
  verify <original.tar.gz> <new.tar.gz> <official-linux.tar.gz> <changed-prefix>...
      Checks that <new.tar.gz> differs from <original.tar.gz> only under the changed prefixes, has the same set of
      cache directories, and has the same klib/common as the official distribution.
  listing <archive.tar.gz> <sub-path>
      Prints "sha256  path" for the regular files under <top-level dir>/<sub-path>.

Prefixes and sub-paths are relative to the top-level directory of an archive, e.g. "klib/common".
"""

import gzip
import hashlib
import os
import stat
import sys
import tarfile

ENTRY_MTIME = 86400


def strip_top(name):
    parts = name.rstrip("/").split("/", 1)
    return parts[1] if len(parts) > 1 else ""


def under(path, prefixes):
    return any(path == p or path.startswith(p + "/") for p in prefixes)


def read_archive(path):
    """Returns (top-level dir, [(path without top-level dir, TarInfo, sha256 or None)]) in archive order."""
    entries = []
    top = None
    with tarfile.open(path, "r:gz") as archive:
        for member in archive:
            top = top or member.name.rstrip("/").split("/", 1)[0]
            digest = hashlib.sha256(archive.extractfile(member).read()).hexdigest() if member.isfile() else None
            entries.append((strip_top(member.name), member, digest))
    return top, entries


def regular_files(entries, sub=""):
    return {p: d for p, m, d in entries if m.isfile() and (not sub or under(p, [sub]))}


def platform_diff(official_linux, official_macos, targets):
    _, linux = read_archive(official_linux)
    _, macos = read_archive(official_macos)
    identical = True
    for target in targets:
        sub = f"klib/platform/{target}"
        a, b = regular_files(linux, sub), regular_files(macos, sub)
        differing = sorted(p for p in set(a) | set(b) if a.get(p) != b.get(p))
        by_name = {}
        for p in differing:
            name = p.rsplit("/", 1)[-1]
            by_name[name] = by_name.get(name, 0) + 1
        print(f"{target}: {len(a)} files, {len(differing)} differ {by_name if by_name else ''}".rstrip())
        identical &= not differing
    return 0 if identical else 3


def repack(original, root, out, changed):
    top, entries = read_archive(original)
    original_paths = [p for p, _, _ in entries]
    modes = {p: m.mode for p, m, _ in entries}
    top_dir = os.path.join(root, top)

    present = {"": True}
    for dirpath, dirnames, filenames in os.walk(top_dir):
        dirnames.sort()
        rel = os.path.relpath(dirpath, top_dir)
        rel = "" if rel == "." else rel
        present[rel] = True
        for f in filenames:
            present[os.path.join(rel, f) if rel else f] = False

    order = [p for p in original_paths if p in present]
    for p in original_paths:
        if p not in present and not under(p, changed):
            sys.exit(f"repack: {p} disappeared outside the changed prefixes")

    added = sorted(p for p in present if p not in modes and p != "")
    for p in added:
        if not under(p, changed):
            if present[p]:
                continue  # a directory that the original archive only implied
            sys.exit(f"repack: {p} appeared outside the changed prefixes")
        parent = p.rsplit("/", 1)[0] if "/" in p else ""
        insert_at = None
        for i in range(len(order) - 1, -1, -1):
            if order[i] == parent or order[i].startswith(parent + "/"):
                insert_at = i + 1
                break
        order.insert(len(order) if insert_at is None else insert_at, p)

    with open(out, "wb") as raw, gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0, compresslevel=6) as gz:
        for p in order:
            full = os.path.join(top_dir, p) if p else top_dir
            is_dir = present[p]
            if p in modes:
                mode = modes[p]
            else:
                permissions = 0o755 if is_dir or os.stat(full).st_mode & stat.S_IXUSR else 0o644
                mode = (stat.S_IFDIR if is_dir else stat.S_IFREG) | permissions
            name = (f"{top}/{p}/" if p and is_dir else (f"{top}/" if not p else f"{top}/{p}")).encode()
            if is_dir:
                write_entry(gz, name, mode, b"5", b"")
            else:
                with open(full, "rb") as f:
                    write_entry(gz, name, mode, b"0", f.read())
        gz.write(bytes(1024))
    print(f"repack: {out}: {len(order)} entries, {len([p for p in added if under(p, changed)])} new under changed prefixes")


def tar_header(name, mode, size, entry_type, magic):
    """A tar header laid out like Gradle's archives (Apache Commons Compress TarArchiveOutputStream)."""
    def octal(value, length):
        return b"%0*o " % (length - 1, value)
    header = bytearray(512)
    header[0:100] = name[:100].ljust(100, b"\0")
    header[100:108] = octal(mode, 8)
    header[108:116] = octal(0, 8)
    header[116:124] = octal(0, 8)
    header[124:136] = octal(size, 12)
    header[136:148] = octal(ENTRY_MTIME, 12)
    header[148:156] = b" " * 8
    header[156:157] = entry_type
    header[257:265] = magic
    header[329:337] = octal(0, 8)
    header[337:345] = octal(0, 8)
    header[148:156] = b"%06o\0 " % sum(header)
    return bytes(header)


def pad(data):
    return data + bytes(-len(data) % 512)


def write_entry(out, name, mode, entry_type, data):
    if len(name) >= 100:
        long_name = name + b"\0"
        out.write(tar_header(b"././@LongLink", 0o100644, len(long_name), b"L", b"ustar  \0"))
        out.write(pad(long_name))
    out.write(tar_header(name, mode, len(data), entry_type, b"ustar\x0000"))
    out.write(pad(data))


def cache_dirs(entries):
    return sorted({"/".join(p.split("/")[:4]) for p, _, _ in entries if p.startswith("klib/cache/") and len(p.split("/")) >= 4})


def verify(original, new, official_linux, changed):
    _, old_entries = read_archive(original)
    _, new_entries = read_archive(new)
    _, official_entries = read_archive(official_linux)
    failures = []

    old_outside = {p: (m.isdir(), m.mode, d) for p, m, d in old_entries if not under(p, changed)}
    new_outside = {p: (m.isdir(), m.mode, d) for p, m, d in new_entries if not under(p, changed)}
    differing = sorted(p for p in set(old_outside) | set(new_outside) if old_outside.get(p) != new_outside.get(p))
    if differing:
        failures.append(f"{len(differing)} entries outside {changed} changed, e.g. {differing[:5]}")

    if cache_dirs(old_entries) != cache_dirs(new_entries):
        failures.append(f"cache directories changed: {cache_dirs(old_entries)} -> {cache_dirs(new_entries)}")

    common_new, common_official = regular_files(new_entries, "klib/common"), regular_files(official_entries, "klib/common")
    if common_new != common_official:
        bad = sorted(p for p in set(common_new) | set(common_official) if common_new.get(p) != common_official.get(p))
        failures.append(f"klib/common differs from the official distribution: {bad[:5]}")

    attributes = {(m.mtime, m.uid, m.gid, m.uname, m.gname) for _, m, _ in new_entries}
    if attributes != {(ENTRY_MTIME, 0, 0, "", "")}:
        failures.append(f"unexpected entry attributes: {attributes}")

    old_files, new_files = regular_files(old_entries), regular_files(new_entries)
    changed_files = sorted(p for p, d in new_files.items() if old_files.get(p) != d)
    print(f"verify: {new}: {len(new_entries)} entries (was {len(old_entries)}), {len(changed_files)} changed or new files,"
          f" cache directories {'unchanged' if cache_dirs(old_entries) == cache_dirs(new_entries) else 'CHANGED'},"
          f" klib/common {'== official' if common_new == common_official else '!= official'}")
    for f in failures:
        print(f"verify: FAILED: {f}")
    return 1 if failures else 0


def listing(archive, sub):
    _, entries = read_archive(archive)
    for p, d in sorted(regular_files(entries, sub).items()):
        print(f"{d}  {p}")


def main(argv):
    command, args = argv[1], argv[2:]
    if command == "platform-diff":
        return platform_diff(args[0], args[1], args[2:])
    if command == "repack":
        return repack(args[0], args[1], args[2], args[3:]) or 0
    if command == "verify":
        return verify(args[0], args[1], args[2], args[3:])
    if command == "listing":
        return listing(args[0], args[1]) or 0
    sys.exit(__doc__)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
