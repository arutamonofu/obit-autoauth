"""Unit tests for the minimal UDP DNS A-record resolver."""

import socket
import struct
import unittest

from obit_auth.dns_resolver import build_a_query, parse_a_response


class TestDnsResolver(unittest.TestCase):
    def test_build_and_parse_a_response(self) -> None:
        tx_id, query = build_a_query("hspot.wifi.access5.obit.ru", tx_id=0x1234)
        self.assertEqual(tx_id, 0x1234)
        question = query[12:]

        # Build a valid DNS response with 1 A record (192.0.2.55)
        resp_header = struct.pack("!HHHHHH", tx_id, 0x8180, 1, 1, 0, 0)
        answer = (
            b"\xc0\x0c"  # pointer to qname at offset 12
            + struct.pack("!HHIH", 1, 1, 60, 4)
            + socket.inet_aton("192.0.2.55")
        )
        ips = parse_a_response(resp_header + question + answer, expected_tx_id=tx_id)
        self.assertEqual(ips, ["192.0.2.55"])

    def test_parse_nxdomain_returns_empty(self) -> None:
        tx_id, query = build_a_query("missing.example", tx_id=0x5678)
        resp_header = struct.pack("!HHHHHH", tx_id, 0x8183, 1, 0, 0, 0)
        self.assertEqual(parse_a_response(resp_header + query[12:], expected_tx_id=tx_id), [])

    def test_tx_id_mismatch_raises(self) -> None:
        _, query = build_a_query("example.com", tx_id=0x1111)
        resp_header = struct.pack("!HHHHHH", 0x2222, 0x8180, 1, 0, 0, 0)
        with self.assertRaises(ValueError):
            parse_a_response(resp_header + query[12:], expected_tx_id=0x1111)


if __name__ == "__main__":
    unittest.main()
