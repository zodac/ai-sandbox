#!/usr/bin/env python3
"""ide-relay: what is selected in the host's IDE, for the Claude in the sandbox. Runs on the HOST.

The IDE plugin (IntelliJ's; VS Code's speaks the same protocol) tells Claude Code which file is open and
which lines are selected, over a websocket on the host's loopback, guarded by a token in ~/.claude/ide. The
sandbox gets neither the token nor a route to that port: a client that has both can also CALL the IDE (open
files, show diffs, reformat). Instead this script is the plugin's client. It listens to it and writes the
latest selection to <state directory>/state.json, which the sandbox mounts READ-ONLY, and
image/final/ide-bridge.mjs passes it to Claude in there. So it only ever goes one way: nothing here reads
anything the sandbox can write, and all it sends the IDE is the protocol's greeting and its ping replies.

Only files inside the project are passed on (symlinks resolved, so a link in the project to a file outside
it doesn't count): the sandbox has those already. Any other file clears the selection.

No dependencies: the websocket client is the small part of RFC 6455 this needs.

  ide-relay.py --check <project>                  prints the name of the IDE that has the project open
  ide-relay.py <project> <path in the sandbox> <state directory> <parent pid>
                                                  relays until the parent (sandbox.sh) is gone
"""
import base64
import json
import os
import shutil
import signal
import socket
import struct
import sys
import time

RETRY_SECONDS = 3  # between looks for the IDE, when it is closed or restarting
TICK_SECONDS = 1  # how often a quiet connection checks that the launcher is still there
MAX_MESSAGE = 16 * 1024 * 1024  # a larger selection is not worth relaying: the connection is dropped


def lock_files():
    """The IDEs' lock files, newest first: <port>.lock in ~/.claude/ide (and $CLAUDE_CONFIG_DIR/ide)."""
    dirs = [os.path.expanduser("~/.claude/ide")]
    if os.environ.get("CLAUDE_CONFIG_DIR"):
        dirs.append(os.path.join(os.environ["CLAUDE_CONFIG_DIR"], "ide"))
    found = []
    for directory in dirs:
        try:
            found += [(e.stat().st_mtime, e.path) for e in os.scandir(directory) if e.name.endswith(".lock")]
        except OSError:
            pass  # no such directory, or a lock file went as it was being read
    return [path for _, path in sorted(found, reverse=True)]


def alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except (OSError, OverflowError):
        pass
    return True


def find_ide(project):
    """(port, token, name) of the IDE that has the project, or a directory above it, open; else None."""
    best = None
    for path in lock_files():
        try:
            port = int(os.path.basename(path)[: -len(".lock")])
            with open(path, encoding="utf-8") as file:
                lock = json.load(file)
            folders = [os.path.realpath(folder) for folder in lock.get("workspaceFolders") or []]
            if lock.get("transport") != "ws" or lock.get("runningInWindows") or not alive(int(lock["pid"])):
                continue
        except (OSError, ValueError, KeyError, TypeError, AttributeError):
            continue
        for folder in folders:
            if os.path.commonpath([folder, project]) != folder:
                continue
            # The closest directory wins, then the IDE whose terminal this is, then the newest.
            rank = (len(folder), str(port) == os.environ.get("CLAUDE_CODE_SSE_PORT"))
            if best is None or rank > best[0]:
                best = (rank, (port, lock.get("authToken") or "", str(lock.get("ideName") or "IDE")))
    return best[1] if best else None


class WebSocket:
    def __init__(self, port, token):
        self.sock = socket.create_connection(("127.0.0.1", port), timeout=5)
        self.buffer = b""
        key = base64.b64encode(os.urandom(16)).decode()
        self.sock.sendall(
            (
                f"GET / HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Protocol: mcp\r\n"
                f"X-Claude-Code-Ide-Authorization: {token}\r\n\r\n"
            ).encode()
        )
        while b"\r\n\r\n" not in self.buffer:
            self._fill()
        head, self.buffer = self.buffer.split(b"\r\n\r\n", 1)
        if b" 101 " not in head.split(b"\r\n", 1)[0] + b" ":
            raise ConnectionError("the IDE refused the connection")
        self.sock.settimeout(TICK_SECONDS)

    def _fill(self):
        data = self.sock.recv(65536)
        if not data:
            raise ConnectionError("the IDE closed the connection")
        self.buffer += data

    def send(self, payload, opcode=1):
        mask = os.urandom(4)
        size = len(payload)
        if size < 126:
            head = struct.pack("!BB", 0x80 | opcode, 0x80 | size)
        elif size < 65536:
            head = struct.pack("!BBH", 0x80 | opcode, 0x80 | 126, size)
        else:
            head = struct.pack("!BBQ", 0x80 | opcode, 0x80 | 127, size)
        self.sock.sendall(head + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(payload)))

    def _frame(self):
        """One whole frame off the buffer, or None when it isn't all there yet."""
        data = self.buffer
        if len(data) < 2:
            return None
        size, at = data[1] & 0x7F, 2
        if size == 126:
            if len(data) < 4:
                return None
            size, at = struct.unpack("!H", data[2:4])[0], 4
        elif size == 127:
            if len(data) < 10:
                return None
            size, at = struct.unpack("!Q", data[2:10])[0], 10
        if size > MAX_MESSAGE:
            raise ConnectionError("a message too large to relay")
        if len(data) < at + size:
            return None
        self.buffer = data[at + size :]
        return data[0] & 0x80, data[0] & 0x0F, data[at : at + size]

    def messages(self):
        """Each text message; None about every TICK_SECONDS without one."""
        parts = b""
        while True:
            frame = self._frame()
            if frame is None:
                try:
                    self._fill()
                except socket.timeout:
                    yield None
                continue
            final, opcode, payload = frame
            if opcode == 8:
                raise ConnectionError("the IDE closed the connection")
            if opcode == 9:
                self.send(payload, opcode=10)
            elif opcode in (0, 1):
                parts += payload
                if len(parts) > MAX_MESSAGE:
                    raise ConnectionError("a message too large to relay")
                if final:
                    yield parts
                    parts = b""

    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass


class Relay:
    def __init__(self, project, sandbox_path, state_dir, parent):
        self.project, self.sandbox_path = project, sandbox_path
        self.state_dir, self.parent = state_dir, parent
        self.selection, self.mention, self.mentions = None, None, 0
        self.write()

    def write(self):
        """Replace state.json in one step, so the sandbox never reads half of one."""
        target = os.path.join(self.state_dir, "state.json")
        with open(target + ".tmp", "w", encoding="utf-8") as file:
            json.dump({"selection": self.selection, "mention": self.mention, "mentions": self.mentions}, file)
        os.replace(target + ".tmp", target)

    def in_sandbox(self, path):
        """The file's path in the sandbox, or None when it isn't in the project."""
        if not isinstance(path, str) or not os.path.isabs(path):
            return None
        real = os.path.realpath(path)
        if os.path.commonpath([real, self.project]) != self.project or real == self.project:
            return None
        return os.path.join(self.sandbox_path, os.path.relpath(real, self.project))

    def select(self, params):
        path = self.in_sandbox(params.get("filePath"))
        selection = None
        if path is not None:
            selection = {"selection": params.get("selection"), "text": params.get("text") or "", "filePath": path}
        if selection != self.selection:
            self.selection = selection
            self.write()

    def mentioned(self, params):
        path = self.in_sandbox(params.get("filePath"))
        if path is None:
            return
        self.mentions += 1
        self.mention = {**params, "filePath": path}
        self.write()

    def check_parent(self):
        if os.getppid() != self.parent:  # sandbox.sh was killed before its teardown could stop this
            raise SystemExit(0)

    def session(self, port, token):
        ws = WebSocket(port, token)

        def send(**message):
            ws.send(json.dumps({"jsonrpc": "2.0", **message}).encode())

        try:
            send(
                id=1,
                method="initialize",
                params={
                    "protocolVersion": "2024-11-05",
                    "capabilities": {},
                    "clientInfo": {"name": "ai-sandbox-ide-relay", "version": "1.0.0"},
                },
            )
            for raw in ws.messages():
                self.check_parent()
                if raw is None:
                    continue
                message = json.loads(raw)
                method, params = message.get("method"), message.get("params") or {}
                if message.get("id") == 1 and "result" in message:
                    send(method="notifications/initialized")
                    # The pid is the launcher's, as it is what runs in the IDE's terminal tab: the plugin uses
                    # it to find that tab (to focus it, and to hand it the Escape key).
                    send(method="ide_connected", params={"pid": self.parent})
                elif method == "selection_changed":
                    self.select(params)
                elif method == "at_mentioned":
                    self.mentioned(params)
                elif method == "ping":
                    send(id=message["id"], result={})
        finally:
            ws.close()

    def run(self):
        while True:
            self.check_parent()
            ide = find_ide(self.project)
            if ide is not None:
                try:
                    self.session(ide[0], ide[1])
                except (OSError, ValueError, KeyError, TypeError, AttributeError):
                    pass  # the IDE closed, restarted, or sent what this doesn't understand: look again
                self.select({})
            time.sleep(RETRY_SECONDS)


def main():
    if len(sys.argv) == 3 and sys.argv[1] == "--check":
        ide = find_ide(os.path.realpath(sys.argv[2]))
        if ide is None:
            raise SystemExit(1)
        print("".join(char for char in ide[2] if char.isprintable())[:80])
        return
    if len(sys.argv) != 5:
        raise SystemExit(__doc__)
    project, sandbox_path, state_dir, parent = sys.argv[1:]
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    signal.signal(signal.SIGHUP, lambda *_: sys.exit(0))
    signal.signal(signal.SIGINT, signal.SIG_IGN)  # a Ctrl+C in the terminal is for the sandbox
    try:
        Relay(os.path.realpath(project), sandbox_path, state_dir, int(parent)).run()
    finally:
        shutil.rmtree(state_dir, ignore_errors=True)


if __name__ == "__main__":
    main()
