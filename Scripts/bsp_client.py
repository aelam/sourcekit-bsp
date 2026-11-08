#!/usr/bin/env python3
"""Send BSP requests over stdio and verify debug sessions over DAP."""

import argparse
import contextlib
import json
import os
from pathlib import Path
import queue
import socket
import subprocess
import sys
import threading
import time
from urllib.parse import urlparse


class Connection:
    def __init__(self, reader, writer, timeout=300, verbose=False):
        self.reader = reader
        self.writer = writer
        self.timeout = timeout
        self.verbose = verbose
        self.messages = queue.Queue()
        self.sequence = 0
        self.events = []
        self.dap_responses = {}
        self.closed = threading.Event()
        threading.Thread(target=self.read, daemon=True).start()

    def read(self):
        try:
            while True:
                headers = {}
                while True:
                    line = self.reader.readline()
                    if not line:
                        raise EOFError("Connection closed")
                    if line == b"\r\n":
                        break
                    key, value = line.decode().split(":", 1)
                    headers[key.lower()] = value.strip()
                size = int(headers["content-length"])
                data = bytearray()
                while len(data) < size:
                    chunk = self.reader.read(size - len(data))
                    if not chunk:
                        raise EOFError("Incomplete message")
                    data.extend(chunk)
                self.messages.put(json.loads(data))
        except Exception as error:
            self.closed.set()
            self.messages.put(error)

    def send(self, message):
        if self.closed.is_set():
            raise EOFError("Connection closed")
        if self.verbose:
            print("SEND", json.dumps(message), file=sys.stderr, flush=True)
        data = json.dumps(message).encode()
        self.writer.write(f"Content-Length: {len(data)}\r\n\r\n".encode() + data)
        self.writer.flush()

    def response(self, key, value, timeout=None):
        if key == "request_seq" and value in self.dap_responses:
            return self.dap_responses.pop(value)
        timeout = self.timeout if timeout is None else timeout
        deadline = time.monotonic() + timeout
        while True:
            try:
                item = self.messages.get(timeout=max(0, deadline - time.monotonic()))
            except queue.Empty as error:
                raise TimeoutError(f"No response for {key}={value} within {timeout}s") from error
            if isinstance(item, Exception):
                raise item
            if self.verbose:
                print("RECV", json.dumps(item), file=sys.stderr, flush=True)
            if item.get(key) == value:
                return item
            if "event" in item:
                self.events.append(item)
            if item.get("type") == "response" and "request_seq" in item:
                if not item.get("success"):
                    raise RuntimeError(json.dumps(item, indent=2))
                self.dap_responses[item["request_seq"]] = item
            for line in item.get("params", {}).get("message", "").splitlines():
                if "error:" in line or "**" in line:
                    print(line, file=sys.stderr, flush=True)

    def bsp(self, method, params, timeout=None):
        self.sequence += 1
        print("BSP", method, file=sys.stderr, flush=True)
        self.send({"jsonrpc": "2.0", "id": self.sequence, "method": method, "params": params})
        result = self.response("id", self.sequence, timeout=timeout)
        if "error" in result:
            raise RuntimeError(json.dumps(result, indent=2))
        return result.get("result")

    def begin_dap(self, command, arguments):
        self.sequence += 1
        self.send({"seq": self.sequence, "type": "request", "command": command, "arguments": arguments})
        return self.sequence

    def finish_dap(self, command, sequence):
        result = self.response("request_seq", sequence, timeout=60)
        print("DAP", command, "success=" + str(result.get("success")), file=sys.stderr, flush=True)
        if not result.get("success"):
            raise RuntimeError(json.dumps(result, indent=2))
        return result

    def dap(self, command, arguments):
        return self.finish_dap(command, self.begin_dap(command, arguments))

    def event(self, name):
        for index, item in enumerate(self.events):
            if item.get("event") == name:
                return self.events.pop(index)
        return self.response("event", name, timeout=60)


def verify_debug(result, breakpoint, verbose):
    endpoint = urlparse(result["uri"])
    if endpoint.scheme != "tcp":
        raise ValueError(f"Unsupported debug endpoint: {result['uri']}")
    with socket.create_connection((endpoint.hostname, endpoint.port), timeout=10) as client:
        client.settimeout(None)
        with client.makefile("rb") as reader, client.makefile("wb") as writer:
            dap = Connection(reader, writer, verbose=verbose)
            try:
                dap.dap("initialize", {
                    "adapterID": "lldb", "pathFormat": "path",
                    "linesStartAt1": True, "columnsStartAt1": True
                })
                data = result.get("data") or {}
                arguments = {k: v for k, v in data.items() if k in ("program", "pid", "args", "env", "cwd")}
                arguments["stopOnEntry"] = True
                command = data.get("request", "launch")
                startup = dap.begin_dap(command, arguments)
                dap.event("initialized")
                if breakpoint:
                    source, line = breakpoint.rsplit(":", 1)
                    dap.dap("setBreakpoints", {
                        "source": {"path": str(Path(source).absolute())},
                        "breakpoints": [{"line": int(line)}]
                    })
                else:
                    dap.dap("setFunctionBreakpoints", {"breakpoints": [{"name": "main"}]})
                dap.dap("configurationDone", {})
                dap.finish_dap(command, startup)
                stopped = dap.event("stopped")["body"]
                if stopped.get("reason") != "breakpoint":
                    dap.dap("continue", {"threadId": stopped["threadId"]})
                    stopped = dap.event("stopped")["body"]
                if stopped.get("reason") != "breakpoint":
                    raise RuntimeError(f"Expected a breakpoint stop: {stopped}")
                threads = dap.dap("threads", {})["body"]["threads"]
                frames = dap.dap("stackTrace", {"threadId": stopped["threadId"], "levels": 10})["body"]["stackFrames"]
                if not threads or not frames:
                    raise RuntimeError("The debug session returned no threads or stack frames")
                print(json.dumps({"breakpoint": stopped, "threads": threads, "stackFrames": frames}, indent=2))
            finally:
                if not dap.closed.is_set():
                    with contextlib.suppress(Exception):
                        dap.dap("disconnect", {"terminateDebuggee": True})
                with contextlib.suppress(OSError):
                    client.shutdown(socket.SHUT_RDWR)


def request_params(connection, args):
    params = json.loads(args.params)
    if not isinstance(params, dict):
        raise ValueError("--params must be a JSON object")
    if args.target:
        targets = connection.bsp("workspace/buildTargets", {})["targets"]
        matches = [target for target in targets if args.target in (target.get("displayName"), target["id"]["uri"])]
        if len(matches) != 1:
            names = [target.get("displayName", target["id"]["uri"]) for target in targets]
            raise ValueError(f"Target must identify one target; available targets: {names}")
        key = "target" if args.method == "buildTarget/run" else "targets"
        params.setdefault(key, matches[0]["id"] if key == "target" else [matches[0]["id"]])
    if args.method in ("buildTarget/compile", "debugSession/start", "buildTarget/test", "buildTarget/run"):
        if not ("targets" in params or "target" in params):
            raise ValueError("Specify --target or provide target identifiers with --params")
        arguments = ["-configuration", args.configuration]
        if args.destination:
            arguments += ["-destination", args.destination]
        if args.derived_data:
            arguments += ["-derivedDataPath", str(Path(args.derived_data).absolute())]
        arguments += args.build_setting
        params.setdefault("arguments", arguments)
    return params


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--server", default=str(Path(__file__).resolve().parents[1] / ".build/debug/sourcekit-bsp"))
    parser.add_argument("--project", required=True, help="Project root directory")
    parser.add_argument("--method", default="workspace/buildTargets")
    parser.add_argument("--params", default="{}", help="JSON request parameters")
    parser.add_argument("--target", help="Target name or target URI")
    parser.add_argument("--destination", help="Xcode destination, such as id=SIMULATOR-UDID")
    parser.add_argument("--configuration", default="Debug")
    parser.add_argument("--build-setting", action="append", default=[])
    parser.add_argument("--derived-data")
    parser.add_argument("--developer-dir", help="Xcode Contents/Developer directory")
    parser.add_argument("--breakpoint", help="Source path and line, separated by a colon")
    parser.add_argument("--timeout", type=float, default=300)
    parser.add_argument("--verbose", action="store_true", help="Print all protocol messages")
    args = parser.parse_args()
    root = Path(args.project).resolve()
    server = str(Path(args.server).resolve())
    environment = os.environ.copy()
    if args.developer_dir:
        environment["DEVELOPER_DIR"] = str(Path(args.developer_dir).resolve())
    process = subprocess.Popen([server], cwd=root, env=environment, stdin=subprocess.PIPE, stdout=subprocess.PIPE)
    connection = Connection(process.stdout, process.stdin, timeout=args.timeout, verbose=args.verbose)
    initialized = False
    try:
        initialize_params = {
            "rootUri": root.as_uri(), "capabilities": {"languageIds": ["swift", "c", "cpp", "objective-c"]},
            "displayName": "bsp-client", "version": "1", "bspVersion": "2.2.0"
        }
        if args.method == "build/initialize":
            initialize_params.update(json.loads(args.params))
        result = connection.bsp("build/initialize", initialize_params)
        initialized = True
        connection.send({"jsonrpc": "2.0", "method": "build/initialized", "params": {}})
        if args.method != "build/initialize":
            result = connection.bsp(args.method, request_params(connection, args))
        print(json.dumps(result, indent=2), flush=True)
        if isinstance(result, dict) and result.get("statusCode", 1) != 1:
            raise RuntimeError(f"{args.method} failed: {result}")
        if args.method == "debugSession/start":
            verify_debug(result, args.breakpoint, args.verbose)
    finally:
        if initialized and args.method != "build/shutdown" and not connection.closed.is_set():
            with contextlib.suppress(Exception):
                connection.bsp("build/shutdown", {}, timeout=5)
        if not connection.closed.is_set():
            with contextlib.suppress(Exception):
                connection.send({"jsonrpc": "2.0", "method": "build/exit", "params": {}})
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(f"ERROR: {error}", file=sys.stderr)
        sys.exit(1)
