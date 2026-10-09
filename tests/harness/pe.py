"""Minimal reader for PE images (Windows .exe/.dll), read only: link timestamp, sections, bytes at an RVA."""
import struct


class PE:
    def __init__(self, path):
        with open(path, "rb") as f:
            self.data = f.read()
        d = self.data
        if d[:2] != b"MZ":
            raise ValueError("not a PE file: " + path)
        off = struct.unpack_from("<I", d, 0x3C)[0]
        if d[off:off + 4] != b"PE\0\0":
            raise ValueError("no PE signature: " + path)
        self.machine, nsec, self.timestamp, _, _, opt_size, _ = struct.unpack_from("<HHIIIHH", d, off + 4)
        sec = off + 24 + opt_size
        self.sections = []
        for i in range(nsec):
            name, vsize, va, rawsize, rawptr = struct.unpack_from("<8sIIII", d, sec + 40 * i)
            self.sections.append((name.rstrip(b"\0").decode("ascii", "replace"), va, vsize, rawptr, rawsize))

    def section(self, name):
        for s in self.sections:
            if s[0] == name:
                return s
        return None

    def section_of(self, rva):
        for s in self.sections:
            if s[1] <= rva < s[1] + max(s[2], s[4]):
                return s
        return None

    def read(self, rva, n):
        s = self.section_of(rva)
        if s is None:
            raise ValueError("RVA %#x outside every section" % rva)
        start = s[3] + (rva - s[1])
        return self.data[start:start + n]

    def in_text(self, rva):
        s = self.section(".text")
        return s is not None and s[1] <= rva < s[1] + s[2]
