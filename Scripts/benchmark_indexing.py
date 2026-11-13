#!/usr/bin/env python3
"""Measure BSP initialization, compiler options, and optional index preparation."""

import argparse
import json
from pathlib import Path
import subprocess
import threading
import time

from bsp_client import Connection


def sample_memory(pid, stop, result):
    while not stop.wait(0.5):
        try:
            output = subprocess.check_output(["ps", "-axo", "pid=,ppid=,rss="], text=True)
            rows = [tuple(map(int, row.split())) for row in output.splitlines()]
            descendants = {pid}
            while True:
                expanded = descendants | {child for child, parent, _ in rows if parent in descendants}
                if expanded == descendants:
                    break
                descendants = expanded
            rss = sum(memory for child, _, memory in rows if child in descendants)
            result["sampled_process_tree_peak_rss_kib"] = max(result.get("sampled_process_tree_peak_rss_kib", 0), rss)
        except (OSError, subprocess.CalledProcessError, ValueError):
            result["memory_sampling_unavailable"] = True
            return


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--server", required=True, type=Path)
    parser.add_argument("--project", required=True, type=Path)
    parser.add_argument("--target", required=True)
    parser.add_argument("--source", required=True, type=Path)
    parser.add_argument("--backend", choices=["xcodebuild", "swift-build"], required=True)
    parser.add_argument("--prepare", action="store_true", help="Build index inputs twice for the selected target")
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    report = {"backend": args.backend, "project": str(args.project.resolve()), "measurements": []}
    command = [str(args.server.resolve())]
    if args.backend == "swift-build":
        command.append("--enable-build-target-prepare")
    stop = threading.Event()
    stderr_path = args.output.with_suffix(".stderr.log")
    with stderr_path.open("w") as stderr:
        process = subprocess.Popen(command, cwd=args.project.resolve(),
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=stderr)
        sampler = threading.Thread(target=sample_memory, args=(process.pid, stop, report), daemon=True)
        sampler.start()
        connection = Connection(process.stdout, process.stdin, timeout=600)

        def request(method, params, label=None):
            start = time.monotonic()
            result = connection.bsp(method, params)
            report["measurements"].append({"operation": label or method, "seconds": time.monotonic() - start})
            return result

        try:
            result = request("build/initialize", {
                "displayName": "indexing-benchmark", "version": "1", "bspVersion": "2.2.0",
                "rootUri": args.project.resolve().as_uri(), "capabilities": {"languageIds": ["swift", "objective-c"]},
            })
            report["index_paths"] = {key: result.get("data", {}).get(key) for key in ["indexStorePath", "indexDatabasePath"]}
            connection.send({"jsonrpc": "2.0", "method": "build/initialized", "params": {}})
            targets = request("workspace/buildTargets", {})["targets"]
            selected = [target for target in targets if args.target in (target.get("displayName"), target["id"]["uri"])]
            if len(selected) != 1:
                raise ValueError(f"Expected one matching target, found {len(selected)}")
            target = selected[0]["id"]
            report["target"] = target
            report["target_count"] = len(targets)
            options = {"target": target, "textDocument": {"uri": args.source.resolve().as_uri()}, "language": "swift"}
            for attempt in range(3):
                result = request("textDocument/sourceKitOptions", options, f"compiler_options_{attempt + 1}")
                if not result or not result.get("compilerArguments"):
                    raise ValueError("The server returned no compiler arguments")
                report["compiler_arguments"] = result["compilerArguments"]
            if args.prepare:
                for attempt in range(2):
                    request("buildTarget/prepare", {"targets": [target]}, f"prepare_{attempt + 1}")
                result = request("textDocument/sourceKitOptions", options, "compiler_options_after_prepare")
                report["compiler_arguments_after_prepare"] = result["compilerArguments"]
            report["success"] = True
        except Exception as error:
            report["success"] = False
            report["error"] = str(error)
            raise
        finally:
            try:
                connection.bsp("build/shutdown", {}, timeout=10)
                connection.send({"jsonrpc": "2.0", "method": "build/exit", "params": {}})
                process.wait(timeout=10)
            except Exception:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
            stop.set()
            sampler.join(timeout=2)
            args.output.write_text(json.dumps(report, indent=2) + "\n")


if __name__ == "__main__":
    main()
