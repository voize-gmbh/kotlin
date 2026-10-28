#!/usr/bin/env python3
"""Writes a build number into the soong_build_number symbol of an ELF executable.

Does what Soong's symbol_inject does for modules with use_version_lib: libbuildversion's
GetBuildNumber() returns that symbol's contents, and aapt2 reports it in `aapt2 version` and in the
tool fingerprint it stores in proto outputs.

usage: inject_build_number.py <elf> <build number>
"""
import struct
import sys

SYMBOL = b"soong_build_number"
SIZE = 128


def main(path, number):
    data = bytearray(open(path, "rb").read())
    if data[:4] != b"\x7fELF" or data[4] != 2 or data[5] != 1:
        sys.exit(f"{path}: not a little-endian ELF64 file")
    e_shoff, = struct.unpack_from("<Q", data, 0x28)
    e_shentsize, e_shnum = struct.unpack_from("<HH", data, 0x3A)

    def section(i):
        off = e_shoff + i * e_shentsize
        name, typ, flags, addr, offset, size, link, info, align, entsize = struct.unpack_from("<IIQQQQIIQQ", data, off)
        return dict(type=typ, addr=addr, offset=offset, size=size, link=link, entsize=entsize)

    sections = [section(i) for i in range(e_shnum)]
    SHT_SYMTAB = 2
    for symtab in (s for s in sections if s["type"] == SHT_SYMTAB):
        strtab = sections[symtab["link"]]
        for off in range(symtab["offset"], symtab["offset"] + symtab["size"], symtab["entsize"]):
            st_name, st_info, st_other, st_shndx, st_value, st_size = struct.unpack_from("<IBBHQQ", data, off)
            name_off = strtab["offset"] + st_name
            if data[name_off:name_off + len(SYMBOL) + 1] != SYMBOL + b"\0":
                continue
            target = sections[st_shndx]
            file_off = target["offset"] + (st_value - target["addr"])
            value = number.encode() + b"\0"
            if st_size != SIZE or len(value) > SIZE:
                sys.exit(f"{path}: unexpected {SYMBOL.decode()} size {st_size}")
            data[file_off:file_off + len(value)] = value
            open(path, "wb").write(data)
            return
    sys.exit(f"{path}: no {SYMBOL.decode()} symbol")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2])
