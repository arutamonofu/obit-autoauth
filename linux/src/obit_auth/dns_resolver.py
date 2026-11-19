"""Minimal RFC 1035 UDP DNS A-record resolver targeting specific Wi-Fi DNS servers."""

from __future__ import annotations

import ipaddress
import os
import random
import socket
import struct
from contextlib import contextmanager
from typing import Iterator, Sequence


def _encode_qname(hostname: str) -> bytes:
    parts = [p for p in hostname.strip(".").split(".") if p]
    return b"".join(bytes([len(p)]) + p.encode("ascii") for p in parts) + b"\x00"


def _skip_name(packet: bytes, offset: int) -> int:
    while offset < len(packet):
        length = packet[offset]
        if length == 0:
            return offset + 1
        if (length & 0xC0) == 0xC0:
            return offset + 2
        offset += 1 + length
    raise ValueError("Truncated DNS name")


def build_a_query(hostname: str, tx_id: int | None = None) -> tuple[int, bytes]:
    qid = tx_id if tx_id is not None else random.randint(0, 0xFFFF)
    header = struct.pack("!HHHHHH", qid, 0x0100, 1, 0, 0, 0)
    question = _encode_qname(hostname) + struct.pack("!HH", 1, 1)
    return qid, header + question


def parse_a_response(packet: bytes, expected_tx_id: int) -> list[str]:
    if len(packet) < 12:
        raise ValueError("DNS response too short")
    tx_id, flags, qdcount, ancount, _, _ = struct.unpack("!HHHHHH", packet[:12])
    if tx_id != expected_tx_id:
        raise ValueError("DNS transaction ID mismatch")
    if (flags & 0x0F) != 0:
        return []

    offset = 12
    for _ in range(qdcount):
        offset = _skip_name(packet, offset) + 4

    ips: list[str] = []
    for _ in range(ancount):
        if offset >= len(packet):
            break
        offset = _skip_name(packet, offset)
        if offset + 10 > len(packet):
            break
        rtype, rclass, _, rdlength = struct.unpack("!HHIH", packet[offset : offset + 10])
        offset += 10
        rdata = packet[offset : offset + rdlength]
        offset += rdlength
        if rtype == 1 and rclass == 1 and len(rdata) == 4:
            ips.append(socket.inet_ntoa(rdata))
    return ips


def resolve_a(hostname: str, dns_servers: Sequence[str], timeout: float = 2.0) -> list[str]:
    try:
        ipaddress.IPv4Address(hostname)
        return [hostname]
    except ipaddress.AddressValueError:
        pass

    for server in dns_servers:
        server = server.strip()
        if not server:
            continue
        tx_id, query = build_a_query(hostname)
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
            sock.settimeout(timeout)
            try:
                sock.sendto(query, (server, 53))
                data, _ = sock.recvfrom(4096)
                ips = parse_a_response(data, tx_id)
                if ips:
                    return ips
            except OSError:
                continue
    return []


@contextmanager
def scoped_dns_override(dns_servers: Sequence[str] | None = None, timeout: float = 2.0) -> Iterator[None]:
    """Force IPv4 resolution and optionally resolve via explicit Wi-Fi DNS servers."""
    orig_getaddrinfo = socket.getaddrinfo
    servers = [s for s in (dns_servers or ()) if s.strip()]
    cache: dict[str, str] = {}

    def custom_getaddrinfo(
        host: str | bytes | None,
        port: str | bytes | int | None,
        family: int = 0,
        type: int = 0,
        proto: int = 0,
        flags: int = 0,
    ):
        host_str = host.decode("ascii", errors="ignore") if isinstance(host, bytes) else (host or "")
        if servers and host_str and not host_str.startswith("["):
            resolved = cache.get(host_str)
            if not resolved:
                ips = resolve_a(host_str, servers, timeout=timeout)
                if ips:
                    resolved = ips[0]
                    cache[host_str] = resolved
            if resolved:
                return orig_getaddrinfo(resolved, port, socket.AF_INET, type, proto, flags)
        return orig_getaddrinfo(host, port, socket.AF_INET, type, proto, flags)

    socket.getaddrinfo = custom_getaddrinfo  # type: ignore[assignment]
    try:
        yield
    finally:
        socket.getaddrinfo = orig_getaddrinfo  # type: ignore[assignment]


def dns_servers_from_env() -> list[str]:
    raw = os.environ.get("OBIT_WIFI_DNS", "")
    return [s.strip() for s in raw.replace(",", " ").split() if s.strip()]
