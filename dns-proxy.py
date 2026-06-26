#!/usr/bin/env python3
"""
dns-proxy.py — Local DNS proxy for nullexit gateway.

Listens on UDP port 53, receives DNS queries, forwards them over TCP
to AdGuard at 127.0.0.1:5354 (the Docker port mapping), and returns
the response via UDP. Handles the DNS-over-TCP wire format (2-byte
length prefix) correctly — unlike socat which just forwards raw bytes.
"""

import socket
import struct
import sys
import os
import threading

LISTEN_ADDR = "127.0.0.1"
LISTEN_PORT = 53
TARGET_HOST = "127.0.0.1"
TARGET_PORT = 5354


def handle_query(data: bytes, client_addr: tuple, sock: socket.socket) -> None:
    """Forward a single DNS query over TCP and send the response back via UDP."""
    try:
        tcp = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        tcp.settimeout(5)
        tcp.connect((TARGET_HOST, TARGET_PORT))

        # DNS over TCP: prepend 2-byte length (big-endian)
        tcp.sendall(struct.pack("!H", len(data)) + data)

        # Read the 2-byte response length
        raw_len = tcp.recv(2)
        if len(raw_len) < 2:
            tcp.close()
            return
        resp_len = struct.unpack("!H", raw_len)[0]

        # Read the full response
        response = b""
        while len(response) < resp_len:
            chunk = tcp.recv(resp_len - len(response))
            if not chunk:
                break
            response += chunk

        tcp.close()

        # Send the response back over UDP (strip TCP length prefix)
        if response:
            sock.sendto(response, client_addr)
    except Exception:
        # Silently drop failed queries (malformed, timeout, etc.)
        pass


def main() -> None:
    # Create UDP socket
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)

    try:
        sock.bind((LISTEN_ADDR, LISTEN_PORT))
    except PermissionError:
        print(f"dns-proxy: ERROR — need root to bind port {LISTEN_PORT}", flush=True)
        sys.exit(1)
    except OSError as e:
        print(f"dns-proxy: ERROR — {e}", flush=True)
        sys.exit(1)

    print(f"dns-proxy: listening on UDP {LISTEN_ADDR}:{LISTEN_PORT} → TCP {TARGET_HOST}:{TARGET_PORT}", flush=True)

    while True:
        try:
            data, client_addr = sock.recvfrom(512)  # max DNS UDP size
            # Spawn a thread for each query to handle them concurrently.
            # This prevents queueing and timeouts during DNS bursts (e.g., opening many tabs).
            threading.Thread(target=handle_query, args=(data, client_addr, sock), daemon=True).start()
        except KeyboardInterrupt:
            break
        except Exception:
            pass

    sock.close()


if __name__ == "__main__":
    main()
