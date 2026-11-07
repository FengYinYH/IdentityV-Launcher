"""Version-gated IDV Login overlay; registration belongs to the native helper.

Load the original PyInstaller module through its path finder, bypassing the
upstream meta-path overlay. Execute in this module's namespace so original
classes/functions keep their globals and identity. Only the DNS query entry
point changes; no proxy, account, certificate or TLS implementation is copied.
"""
import importlib.machinery as _idv_machinery


def _idv_load_original(namespace):
    spec = _idv_machinery.PathFinder.find_spec("mitm_proxy")
    if (spec is None or spec.loader is None
            or type(spec.loader).__name__ != "PyiFrozenLoader"
            or type(spec.loader).__module__ != "pyimod02_importers"):
        raise ImportError("IDV DNS adaptation requires the original PyInstaller module")
    code = spec.loader.get_code("mitm_proxy")
    if code is None:
        raise ImportError("Original mitm_proxy code is unavailable")
    exec(code, namespace)


_idv_load_original(globals())

# Imports use private names to avoid changing original module globals.
import os as _idv_os
import sys as _idv_sys


def _idv_load_dependencies():
    # A future frozen bundle may omit adapter-only stdlib modules. Load them
    # only after its exact supported identity and original API are established.
    global _idv_ipaddress, _idv_socket, _idv_struct, _idv_time, _idv_Executor
    import ipaddress as _idv_ipaddress
    import socket as _idv_socket
    import struct as _idv_struct
    import time as _idv_time
    from concurrent.futures import ThreadPoolExecutor as _idv_Executor

def _idv_binary_matches():
    # Upstream can update/restart itself without returning through our helper.
    # A stale overlay must then delegate to the new original module unchanged.
    try:
        import hashlib as _idv_hashlib
        with open(_idv_sys.executable, "rb") as binary:
            if _idv_os.fstat(binary.fileno()).st_size != 199215712:
                return False
            digest = _idv_hashlib.sha256()
            for chunk in iter(lambda: binary.read(1048576), b""):
                digest.update(chunk)
            return digest.hexdigest() == "dcfef8ddd66fae454d30c296dbdc42496a862ed38cd533e0b4b8032b5db9cac5"
    except (OSError, ImportError):
        return False


_idv_supported_binary = _idv_binary_matches()
_IDV_DNS_TIMEOUT = 2.0
_IDV_DNS_DOMAINS = frozenset(("service.mkey.163.com", "sdk-os.mpsdk.easebar.com", "mgbsdk.matrix.netease.com"))
_idv_original_query = globals().get("_query_upstream_parallel")


def _idv_name(packet, offset, seen=None):
    """Read a bounded DNS name, including compression, and its wire end."""
    seen = set() if seen is None else set(seen)
    labels, end = [], None
    while True:
        if offset >= len(packet) or offset in seen or len(seen) > 128:
            raise ValueError("Invalid DNS name")
        seen.add(offset)
        size = packet[offset]
        offset += 1
        if size & 0xC0 == 0xC0:
            if offset >= len(packet):
                raise ValueError("Incomplete DNS pointer")
            pointer = ((size & 0x3F) << 8) | packet[offset]
            suffix, _ = _idv_name(packet, pointer, seen)
            labels.append(suffix)
            end = offset + 1
            break
        if size & 0xC0 or offset + size > len(packet):
            raise ValueError("Invalid DNS label")
        if size == 0:
            end = offset
            break
        labels.append(packet[offset:offset + size].decode("ascii").lower())
        offset += size
    name = ".".join(labels)
    if len(name) > 253:
        raise ValueError("DNS name too long")
    return name, end


def _idv_answer(packet, query):
    """Accept a complete matching A/IN answer (or its CNAME chain) only."""
    try:
        if len(packet) < 12 or packet[:2] != query[:2]:
            return None
        _, flags, questions, answers, _, _ = _idv_struct.unpack("!6H", packet[:12])
        if not flags & 0x8000 or flags & 0x7A0F or questions != 1:
            return None  # QR required; reject opcode, truncation and RCODE.
        expected, query_end = _idv_name(query, 12)
        name, pos = _idv_name(packet, 12)
        if name != expected or packet[pos:pos + 4] != query[query_end:query_end + 4]:
            return None
        pos += 4
        aliases, addresses = {}, []
        for _ in range(answers):
            owner, pos = _idv_name(packet, pos)
            kind, cls, _, size = _idv_struct.unpack("!HHIH", packet[pos:pos + 10])
            pos += 10
            end = pos + size
            if end > len(packet):
                return None
            if cls == 1 and kind == 5:
                alias, alias_end = _idv_name(packet, pos)
                if alias_end != end:
                    return None
                aliases[owner] = alias
            elif cls == 1 and kind == 1 and size == 4:
                ip = _idv_ipaddress.IPv4Address(packet[pos:end])
                if not (ip.is_loopback or ip.is_unspecified or ip.is_multicast or ip.is_link_local or int(ip) == 0xFFFFFFFF):
                    addresses.append((owner, str(ip)))
            pos = end
        accepted = {expected}
        for _ in range(len(aliases)):
            target = aliases.get(name)
            if target is None or target in accepted:
                break
            accepted.add(target)
            name = target
        return next((ip for owner, ip in addresses if owner in accepted), None)
    except (ValueError, UnicodeError, IndexError, _idv_struct.error):
        return None


def _idv_read_exact(sock, count, deadline):
    result = bytearray()
    while len(result) < count:
        remaining = deadline - _idv_time.monotonic()
        if remaining <= 0:
            raise TimeoutError("DNS TCP response deadline")
        sock.settimeout(remaining)
        part = sock.recv(count - len(result))
        if not part:
            raise OSError("Incomplete DNS TCP response")
        result.extend(part)
    return bytes(result)


def _idv_query_one(server, query):
    try:
        with _idv_socket.socket(_idv_socket.AF_INET, _idv_socket.SOCK_DGRAM) as sock:
            sock.settimeout(_IDV_DNS_TIMEOUT)
            # Connected UDP also rejects responses from another source endpoint.
            sock.connect((server, 53))
            sock.send(query)
            ip = _idv_answer(sock.recv(65535), query)
            if ip:
                return ip
    except OSError:
        pass
    try:
        deadline = _idv_time.monotonic() + _IDV_DNS_TIMEOUT
        with _idv_socket.socket(_idv_socket.AF_INET, _idv_socket.SOCK_STREAM) as sock:
            sock.settimeout(_IDV_DNS_TIMEOUT)
            sock.connect((server, 53))
            sock.settimeout(max(0.001, deadline - _idv_time.monotonic()))
            sock.sendall(_idv_struct.pack("!H", len(query)) + query)
            size = _idv_struct.unpack("!H", _idv_read_exact(sock, 2, deadline))[0]
            if size < 12:
                return None
            return _idv_answer(_idv_read_exact(sock, size, deadline), query)
    except OSError:
        return None


def _idv_query_upstream_parallel(domain):
    if not _idv_supported_binary or domain not in _IDV_DNS_DOMAINS:
        return _idv_original_query(domain)
    query = _build_dns_query(domain)
    servers = tuple(UPSTREAM_DNS_SERVERS)
    if not servers:
        return None
    from concurrent.futures import as_completed
    # Every worker has bounded UDP and absolute TCP deadlines. No outer timeout
    # can escape into resolve_domain_ip on total DNS failure.
    with _idv_Executor(max_workers=len(servers)) as executor:
        futures = [executor.submit(_idv_query_one, server, query) for server in servers]
        for future in as_completed(futures):
            ip = future.result()
            if ip:
                return ip
    return None


# Unknown upstream versions may remove/rename every DNS/logging entry point.
# Leave their original namespace entries intact unless both identity and the
# exact capabilities required by this adapter have been established.
_idv_capabilities = (
    callable(_idv_original_query)
    and callable(globals().get("_build_dns_query"))
    and isinstance(globals().get("UPSTREAM_DNS_SERVERS"), (list, tuple))
    and bool(globals().get("UPSTREAM_DNS_SERVERS"))
)
if _idv_supported_binary and _idv_capabilities:
    _idv_load_dependencies()
    _query_upstream_parallel = _idv_query_upstream_parallel
    _idv_log_info = getattr(globals().get("logger"), "info", None)
    if callable(_idv_log_info):
        _idv_log_info("IDV launcher DNS TCP fallback active (official 6.3.3)")
