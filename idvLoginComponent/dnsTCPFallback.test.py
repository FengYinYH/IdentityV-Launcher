"""Offline wire-protocol tests; no production proxy, credentials or public DNS."""
import ast
import logging
from pathlib import Path
import socket
import struct
import threading
import time
import unittest
from types import SimpleNamespace

SOURCE = Path(__file__).with_name("dnsTCPFallback.py")
DOMAIN = "mgbsdk.matrix.netease.com"
QUERY = b"\x12\x34\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00" + b"".join(bytes([len(s)]) + s.encode() for s in DOMAIN.split(".")) + b"\0\0\1\0\1"
QUESTION = QUERY[12:]


def response(flags=0x8180, address=b"\xcb\x00\x71\x09", owner=b"\xc0\x0c", kind=1, cls=1):
    return QUERY[:2] + struct.pack("!5H", flags, 1, 1, 0, 0) + QUESTION + owner + struct.pack("!HHIH", kind, cls, 30, len(address)) + address


def load_original_namespace(result, force_supported=None):
    tree = ast.parse(SOURCE.read_text())
    # Only bypass executing the real frozen original for wire unit tests. The
    # separate PyInstaller probe imports the unmodified complete overlay.
    tree.body = [node for node in tree.body if not (
        isinstance(node, ast.Expr) and isinstance(node.value, ast.Call)
        and isinstance(node.value.func, ast.Name)
        and node.value.func.id == "_idv_load_original")]
    if force_supported is not None:
        for node in tree.body:
            if isinstance(node, ast.Assign) and any(isinstance(target, ast.Name) and target.id == "_idv_supported_binary" for target in node.targets):
                node.value = ast.copy_location(ast.Constant(force_supported), node.value)
    exec(compile(tree, str(SOURCE), "exec"), result)
    if force_supported is None:
        assert not result["_idv_supported_binary"]  # Test interpreter is not the official asset.
    return result


def namespace():
    original = lambda domain: "original:" + domain
    result = load_original_namespace(dict(
        _query_upstream_parallel=original, _build_dns_query=lambda domain: QUERY,
        UPSTREAM_DNS_SERVERS=["127.0.0.1"], logger=logging.getLogger("test")), force_supported=True)
    assert result["_idv_original_query"] is original
    assert result["_query_upstream_parallel"] is result["_idv_query_upstream_parallel"]
    return result


class WireTests(unittest.TestCase):
    def setUp(self):
        self.ns = namespace()

    def test_response_validation(self):
        parse = self.ns["_idv_answer"]
        self.assertEqual(parse(response(), QUERY), "203.0.113.9")
        bad = [response()[1:], response()[:-1], response(flags=0x0180),
               response(flags=0x8380), response(flags=0x8183), response(flags=0x8980),
               response(cls=3), response(address=b"\x7f\0\0\1"),
               response(address=b"\0\0\0\0"), response(owner=b"\xc0\xff"),
               response(owner=b"\xc0"), response(owner=b"\xc0" + bytes([len(QUERY)])),
               response().replace(QUESTION, QUESTION.replace(b"mgbsdk", b"xgbsdk")),
               b"\xff\xff" + response()[2:]]
        for packet in bad:
            with self.subTest(packet=packet):
                self.assertIsNone(parse(packet, QUERY))

    def test_cname_chain_and_unrelated_answer(self):
        parse = self.ns["_idv_answer"]
        alias = b"\x04auth\x07example\0"
        cname = b"\xc0\x0c" + struct.pack("!HHIH", 5, 1, 30, len(alias)) + alias
        address = alias + struct.pack("!HHIH", 1, 1, 30, 4) + b"\xcb\0\x71\x09"
        packet = QUERY[:2] + struct.pack("!5H", 0x8180, 1, 2, 0, 0) + QUESTION + cname + address
        self.assertEqual(parse(packet, QUERY), "203.0.113.9")
        self.assertIsNone(parse(response(owner=alias), QUERY))

    def exercise(self, udp_reply=None, tcp_mode="fragmented"):
        tcp = socket.socket()
        tcp.bind(("127.0.0.1", 0))
        port = tcp.getsockname()[1]
        tcp.listen()
        tcp.settimeout(1)
        udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        udp.bind(("127.0.0.1", port))
        udp.settimeout(1)
        seen = []
        errors = []

        def udp_server():
            try:
                query, peer = udp.recvfrom(65535)
                seen.append("udp")
                self.assertEqual(query, QUERY)
                if udp_reply is not None:
                    udp.sendto(udp_reply, peer)
            except Exception as error:
                errors.append(error)
            finally:
                udp.close()

        def tcp_server():
            try:
                with tcp.accept()[0] as client:
                    seen.append("tcp")
                    client.settimeout(1)
                    data = bytearray()
                    while len(data) < len(QUERY) + 2:
                        data.extend(client.recv(len(QUERY) + 2 - len(data)))
                    self.assertEqual(bytes(data), struct.pack("!H", len(QUERY)) + QUERY)
                    packet = response()
                    wire = struct.pack("!H", len(packet)) + packet
                    if tcp_mode == "short":
                        client.sendall(wire[:-2])
                    elif tcp_mode == "bad":
                        client.sendall(b"\0\x01x")
                    else:
                        for byte in wire:
                            client.sendall(bytes([byte]))
                            if tcp_mode == "trickle":
                                time.sleep(0.02)
            except (BrokenPipeError, ConnectionResetError):
                pass  # Expected when the absolute read deadline expires.
            except socket.timeout:
                if udp_reply is None or self.ns["_idv_answer"](udp_reply, QUERY) is None:
                    errors.append(AssertionError("Expected TCP fallback was not attempted"))
            except Exception as error:
                errors.append(error)
            finally:
                tcp.close()

        threads = [threading.Thread(target=udp_server), threading.Thread(target=tcp_server)]
        for thread in threads:
            thread.start()
        real_socket = socket.socket

        class RedirectSocket:
            def __init__(self, *args):
                self.sock = real_socket(*args)
            def __enter__(self):
                return self
            def __exit__(self, *args):
                self.sock.close()
            def connect(self, endpoint):
                self.sock.connect((endpoint[0], port))
            def __getattr__(self, name):
                return getattr(self.sock, name)

        self.ns["_IDV_DNS_TIMEOUT"] = 0.12
        started = time.monotonic()
        self.ns["_idv_socket"] = SimpleNamespace(socket=RedirectSocket, AF_INET=socket.AF_INET,
                                                  SOCK_DGRAM=socket.SOCK_DGRAM, SOCK_STREAM=socket.SOCK_STREAM)
        answer = self.ns["_query_upstream_parallel"](DOMAIN)
        elapsed = time.monotonic() - started
        for thread in threads:
            thread.join(2)
            self.assertFalse(thread.is_alive())
        self.assertFalse(errors, errors)
        return answer, seen, elapsed

    def test_udp_success_avoids_tcp(self):
        answer, seen, _ = self.exercise(udp_reply=response())
        self.assertEqual(answer, "203.0.113.9")
        self.assertEqual(seen, ["udp"])

    def test_udp_timeout_tcp_fragmented_success(self):
        answer, seen, _ = self.exercise()
        self.assertEqual(answer, "203.0.113.9")
        self.assertEqual(seen, ["udp", "tcp"])

    def test_invalid_udp_falls_back(self):
        answer, seen, _ = self.exercise(udp_reply=response(flags=0x8380))
        self.assertEqual(answer, "203.0.113.9")
        self.assertEqual(seen, ["udp", "tcp"])

    def test_total_failure_returns_none(self):
        for mode in ["short", "bad", "trickle"]:
            answer, _, elapsed = self.exercise(tcp_mode=mode)
            self.assertIsNone(answer)
            self.assertLess(elapsed, 0.8)

    def test_unknown_module_without_dns_or_logger_loads_transparently(self):
        sentinel = object()
        for supported in (None, True):
            result = load_original_namespace({"future_module_state": sentinel}, force_supported=supported)
            self.assertIs(result["future_module_state"], sentinel)
            for name in ("_query_upstream_parallel", "logger", "_build_dns_query", "UPSTREAM_DNS_SERVERS", "_idv_ipaddress", "_idv_Executor"):
                self.assertNotIn(name, result)
            self.assertFalse(result["_idv_capabilities"])
        original = lambda domain: "future:" + domain
        result = load_original_namespace({"_query_upstream_parallel": original})
        self.assertIs(result["_query_upstream_parallel"], original)

    def test_changed_binary_delegates_even_managed_domain(self):
        self.ns["_idv_supported_binary"] = False
        self.assertEqual(self.ns["_query_upstream_parallel"](DOMAIN), "original:" + DOMAIN)

    def test_unmanaged_domains_delegate(self):
        self.assertEqual(self.ns["_query_upstream_parallel"]("other.example"), "original:other.example")


if __name__ == "__main__":
    unittest.main()
