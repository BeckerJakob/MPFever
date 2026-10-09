"""T1.2 / T1.3 - the link (mpfever_link.lua): the channels between a game, MPFever.exe and the native module.
One contract, two implementations: files (what 0.2.x always did) and memory (tests; the in-process link of Phase 3).
Every contract test runs against both."""
import os

import pytest

from harness import lua

pytestmark = pytest.mark.unit


@pytest.fixture(params=["files", "memory"])
def link(request, tmp_path):
    L = lua.new_runtime({"MPFEVER_DIR": str(tmp_path), "MPFEVER_NAME": "Hote", "MPFEVER_ROLE": "host"})
    C = lua.load_common(L)
    M = L.eval('ug_require("mpfever_link.lua")')
    k = M.files(C) if request.param == "files" else M.memory(C)

    class Link:
        kind = request.param
        lua = L
        impl = k
        offs = L.table()

        def append(self, name, text):
            return k.append(name, text)

        def read(self, name, key="k"):
            return list(k.readNew(name, self.offs, key).values())

        def raw(self, name):
            if self.kind == "files":
                p = os.path.join(str(tmp_path), name)
                return open(p, "rb").read().decode("utf-8") if os.path.exists(p) else None
            return k.streams[name]

        def replace(self, name, text):
            if self.kind == "files":
                open(os.path.join(str(tmp_path), name), "wb").write(text.encode("utf-8"))
            else:
                k.set(name, text)

    return Link()


def test_lines_in_order(link):
    link.append("in.log", "a\nb\n")
    link.append("in.log", "c\n")
    assert link.read("in.log") == ["a", "b", "c"]
    assert link.read("in.log") == []


def test_partial_line_waits_for_its_end(link):
    link.append("in.log", "first\nsec")
    assert link.read("in.log") == ["first"]
    link.append("in.log", "ond\n")
    assert link.read("in.log") == ["second"]


def test_crlf_and_empty_lines(link):
    link.append("in.log", "a\r\n\r\n\nb\n")
    assert link.read("in.log") == ["a", "b"]


def test_independent_positions(link):
    link.append("x.log", "1\n2\n")
    assert link.read("x.log", "one") == ["1", "2"]
    assert link.read("x.log", "two") == ["1", "2"]


def test_shorter_stream_is_read_from_its_start(link):
    link.append("in.log", "old line one\nold line two\n")
    assert len(link.read("in.log")) == 2
    link.replace("in.log", "new\n")          # the other side started the stream again
    assert link.read("in.log") == ["new"]


def test_missing_stream_reads_nothing(link):
    assert link.read("nothing.log") == []


def test_send_writes_one_protocol_line(link):
    assert link.impl.send("act", link.lua.eval('{ fn = "x", at = 18800 }'))
    raw = link.raw("out.log")
    assert raw.count("\n") == 1 and raw.startswith("act\tHote\t")


def test_native_control_lines(link):
    link.impl.nativeCtl("enable 1")
    link.impl.nativeCtl("release 3")
    assert link.raw("native_ctl.txt") == "enable 1\nrelease 3\n"


def test_utf8_survives(link):
    link.append("in.log", "Línea 1 – Bahnhof Süd 日本\n")
    assert link.read("in.log") == ["Línea 1 – Bahnhof Süd 日本"]


def test_split_lines_helper():
    L = lua.new_runtime({})
    M = L.eval('ug_require("mpfever_link.lua")')
    lines, last = M.splitLines("a\nb\nc", "\n", "\r")
    assert list(lines.values()) == ["a", "b"] and last == 4
