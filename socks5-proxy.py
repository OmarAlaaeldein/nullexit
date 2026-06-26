#!/usr/bin/env python3
"""socks5-proxy.py — Minimal RFC 1928 SOCKS5 proxy.

Binds to 0.0.0.0:1080 inside the warp container's network namespace.
Each outbound connection goes through the kernel routing table, which
we've configured (table 200 → tun0) to route through WARP.

This replaces Tailscale's built-in exit node functionality, because
Tailscale's Docker container handles forwarding in userspace, bypassing
the kernel routing stack and WARP's tun0 interface.

Usage:
    python3 socks5-proxy.py [--bind ADDRESS] [--port PORT]

Dependencies:
    Python 3 (built into macOS / available in alpine via apk)
"""

import argparse
import select
import socket
import struct
import sys
import threading

SOCKS_VERSION = 5

# SOCKS5 auth methods
NO_AUTH = 0
NO_ACCEPTABLE = 0xFF

# SOCKS5 commands
CONNECT = 1

# SOCKS5 address types
IPV4 = 1
DOMAIN = 3
IPV6 = 4

# SOCKS5 replies
SUCCESS = 0
FAILURE = 1
NOT_ALLOWED = 2
NET_UNREACHABLE = 3
HOST_UNREACHABLE = 4
CONN_REFUSED = 5
TTL_EXPIRED = 6
CMD_NOT_SUPPORTED = 7
ADDR_NOT_SUPPORTED = 8


def recv_exact(sock, n):
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise ConnectionError("Connection closed")
        buf += chunk
    return buf


def socks5_handshake(client):
    """Perform SOCKS5 handshake and return (address, port) to connect to."""
    # Read greeting: VER, NMETHODS, METHODS
    ver, nmethods = recv_exact(client, 2)
    if ver != SOCKS_VERSION:
        raise ValueError(f"Unsupported SOCKS version: {ver}")
    methods = recv_exact(client, nmethods)
    if NO_AUTH not in methods:
        client.send(struct.pack("BB", SOCKS_VERSION, NO_ACCEPTABLE))
        raise ValueError("No acceptable auth method")
    client.send(struct.pack("BB", SOCKS_VERSION, NO_AUTH))

    # Read request: VER, CMD, RSV, ATYP, DST.ADDR, DST.PORT
    ver, cmd, rsv, atyp = recv_exact(client, 4)
    if ver != SOCKS_VERSION:
        raise ValueError(f"Invalid version in request: {ver}")
    if cmd != CONNECT:
        client.send(struct.pack("BBBB", SOCKS_VERSION, CMD_NOT_SUPPORTED, 0, IPV4) + struct.pack("!I", 0) + struct.pack("!H", 0))
        raise ValueError(f"Unsupported command: {cmd}")

    if atyp == IPV4:
        addr = socket.inet_ntoa(recv_exact(client, 4))
    elif atyp == DOMAIN:
        domain_len = recv_exact(client, 1)[0]
        addr = recv_exact(client, domain_len).decode("ascii", errors="replace")
    elif atyp == IPV6:
        addr = socket.inet_ntop(socket.AF_INET6, recv_exact(client, 16))
    else:
        client.send(struct.pack("BBBB", SOCKS_VERSION, ADDR_NOT_SUPPORTED, 0, IPV4) + struct.pack("!I", 0) + struct.pack("!H", 0))
        raise ValueError(f"Unsupported address type: {atyp}")

    port = struct.unpack("!H", recv_exact(client, 2))[0]
    return addr, port


def send_success(client, bind_addr="0.0.0.0", bind_port=0):
    """Send SOCKS5 success response."""
    reply = struct.pack("BBBB", SOCKS_VERSION, SUCCESS, 0, IPV4)
    reply += socket.inet_aton(bind_addr)
    reply += struct.pack("!H", bind_port)
    client.send(reply)


def forward(src, dst, name):
    """Bidirectional copy between two sockets."""
    try:
        while True:
            try:
                r, _, _ = select.select([src, dst], [], [])
            except ValueError:
                # Socket was closed by the other thread (fileno became -1)
                break
            if src in r:
                try:
                    data = src.recv(65536)
                except (ConnectionError, OSError, ValueError):
                    break
                if not data:
                    break
                dst.sendall(data)
            if dst in r:
                try:
                    data = dst.recv(65536)
                except (ConnectionError, OSError, ValueError):
                    break
                if not data:
                    break
                src.sendall(data)
    except (ConnectionError, OSError):
        pass
    finally:
        try:
            src.close()
        except OSError:
            pass
        try:
            dst.close()
        except OSError:
            pass


def handle_client(client, addr):
    """Handle a single SOCKS5 client connection."""
    remote = None
    try:
        target_addr, target_port = socks5_handshake(client)
        print(f"[SOCKS5] Connect: {addr[0]}:{addr[1]} -> {target_addr}:{target_port}")

        remote = socket.create_connection((target_addr, target_port), timeout=30)
        send_success(client)
        print(f"[SOCKS5] Connected: {addr[0]}:{addr[1]} -> {target_addr}:{target_port}")

        # Bidirectional forwarding
        t1 = threading.Thread(target=forward, args=(client, remote, "C->R"), daemon=True)
        t2 = threading.Thread(target=forward, args=(remote, client, "R->C"), daemon=True)
        t1.start()
        t2.start()
        t1.join()
        t2.join()
    except Exception as e:
        print(f"[SOCKS5] Error ({addr[0]}:{addr[1]}): {e}", file=sys.stderr)
        try:
            client.close()
        except OSError:
            pass
        if remote:
            try:
                remote.close()
            except OSError:
                pass


def main():
    parser = argparse.ArgumentParser(description="Minimal SOCKS5 proxy")
    parser.add_argument("--bind", default="0.0.0.0", help="Address to bind to")
    parser.add_argument("--port", type=int, default=1080, help="Port to listen on")
    args = parser.parse_args()

    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind((args.bind, args.port))
    sock.listen(128)
    print(f"[SOCKS5] Listening on {args.bind}:{args.port}", flush=True)

    try:
        while True:
            client, addr = sock.accept()
            t = threading.Thread(target=handle_client, args=(client, addr), daemon=True)
            t.start()
    except KeyboardInterrupt:
        print("[SOCKS5] Shutting down...", flush=True)
    finally:
        sock.close()


if __name__ == "__main__":
    main()
