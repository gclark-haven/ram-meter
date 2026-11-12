"""Read guest counters and narrow job identity fields on the verified local pool."""

import concurrent.futures
import json
import os
from pathlib import Path
import re
import subprocess
import sys


DOCKER_PATHS = (
    "/usr/local/bin/docker",
    "/opt/homebrew/bin/docker",
    "/Applications/Docker.app/Contents/Resources/bin/docker",
)
GUEST_PROBE = r"""
import json, pathlib, sys

runner, repo = sys.argv[1:]
processes = {}
for path in pathlib.Path('/proc').iterdir():
    if not path.name.isdecimal():
        continue
    try:
        name = (path / 'comm').read_text().strip()
        fields = (path / 'stat').read_text().rsplit(')', 1)[1].split()
        processes[int(path.name)] = (name, int(fields[1]), int(fields[19]))
    except (OSError, ValueError, IndexError):
        continue

workers = [(pid, start) for pid, (name, _, start) in processes.items() if name == 'Runner.Worker']
if len(workers) != 1:
    print(json.dumps({'worker': None, 'identity': None, 'ambiguous': len(workers) > 1}))
    sys.exit()

worker, start = workers[0]
keys = {b'GITHUB_REPOSITORY', b'GITHUB_RUN_ID', b'GITHUB_RUN_ATTEMPT',
        b'GITHUB_WORKFLOW', b'RUNNER_NAME'}
matches = set()
for pid in processes:
    node, visited = pid, set()
    while node in processes and node not in visited:
        if node == worker:
            break
        visited.add(node)
        _, parent, born = processes[node]
        if parent not in processes or processes[parent][2] > born:
            break
        node = parent
    if node != worker or pid == worker:
        continue
    try:
        with open('/proc/' + str(pid) + '/environ', 'rb') as file:
            data = file.read(524288)
        fields = {key: value.decode() for field in data.split(bytes([0]))
                  for key, equals, value in [field.partition(b'=')] if equals and key in keys}
    except (OSError, UnicodeError):
        continue
    if fields.get(b'RUNNER_NAME') != runner or fields.get(b'GITHUB_REPOSITORY') != repo:
        continue
    run = fields.get(b'GITHUB_RUN_ID', '')
    attempt = fields.get(b'GITHUB_RUN_ATTEMPT', '')
    workflow = fields.get(b'GITHUB_WORKFLOW', '')
    if run.isascii() and run.isdecimal() and attempt.isascii() and attempt.isdecimal():
        matches.add((run, attempt, workflow[:120]))

identity = None
if len(matches) == 1:
    run, attempt, workflow = next(iter(matches))
    identity = dict(repository=repo, run=run, attempt=attempt, workflow=workflow or 'CI')
print(json.dumps(dict(worker=str(worker) + ':' + str(start), identity=identity,
                      ambiguous=len(matches) > 1)))
"""


def docker(executable, *args):
    return subprocess.check_output(
        [executable, "--context", "desktop-linux", *args],
        encoding="utf-8", stderr=subprocess.DEVNULL, timeout=6,
    )


def identity(executable, container):
    _, identifier, runner, repository = container
    try:
        return json.loads(docker(executable, "exec", identifier, "/usr/bin/python3", "-c",
                                 GUEST_PROBE, runner, repository))
    except (OSError, ValueError, subprocess.SubprocessError):
        return None


def memory_bytes(text):
    match = re.fullmatch(r"([0-9.]+)\s*([KMGT]?i?B)", text.split("/")[0].strip())
    if not match:
        raise ValueError("unrecognized memory")
    number, unit = match.groups()
    if unit == "B":
        return int(float(number))
    exponent = "KMGT".index(unit[0]) + 1
    return int(float(number) * (1024 if "i" in unit else 1000) ** exponent)


def configuration(path):
    with path.open("rb") as file:
        raw = file.read(16385)
    if len(raw) > 16384:
        raise ValueError("runner configuration exceeds 16 KiB")
    rows = json.loads(raw)["runners"]
    if not isinstance(rows, list) or not 1 <= len(rows) <= 16:
        raise ValueError("expected 1 to 16 runners")
    result = {}
    names = set()
    for row in rows:
        container, runner, repository = (row[key] for key in ("container", "runner", "repository"))
        if not all(isinstance(value, str) for value in (container, runner, repository)):
            raise ValueError("expected string identifiers")
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,127}", container):
            raise ValueError("invalid container name")
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_. -]{0,127}", runner):
            raise ValueError("invalid runner name")
        if not re.fullmatch(r"[A-Za-z0-9_.-]{1,100}/[A-Za-z0-9_.-]{1,100}", repository):
            raise ValueError("invalid repository")
        if container in result or runner in names:
            raise ValueError("duplicate runner or container")
        result[container] = (runner, repository)
        names.add(runner)
    return result


def collect(executable, containers):
    running = []
    for line in docker(executable, "ps", "--no-trunc", "--format", "{{.Names}} {{.ID}}").splitlines():
        name, _, identifier = line.partition(" ")
        if name in containers and re.fullmatch(r"[0-9a-f]{64}", identifier):
            running.append((name, identifier, *containers[name]))
    if not running:
        return []

    with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
        before = list(pool.map(lambda container: identity(executable, container), running))
        stats = docker(executable, "stats", "--no-stream", "--format", "{{json .}}",
                       *(identifier for _, identifier, _, _ in running))
        after = list(pool.map(lambda container: identity(executable, container), running))
    counters = {row["Name"]: row for row in map(json.loads, stats.splitlines())}

    output = []
    for (name, identifier, runner, _), first, last in zip(running, before, after):
        row = counters.get(name)
        if not row or not identifier.startswith(row["ID"]):
            continue
        try:
            cpu = float(row["CPUPerc"].removesuffix("%")) / 100
            memory = memory_bytes(row["MemUsage"])
        except (KeyError, ValueError):
            continue
        job = worker = None
        reusable = False
        if first and last and first["worker"] and first["worker"] == last["worker"]:
            worker = first["worker"]
            a, b = first["identity"], last["identity"]
            reusable = not first["ambiguous"] and not last["ambiguous"] and (not a or not b or a == b)
            if reusable:
                job = a or b
        idle = bool(first and last and not first["worker"] and not last["worker"]
                    and not first["ambiguous"] and not last["ambiguous"])
        output.append(dict(id=identifier, runner=runner, cpu=cpu, bytes=memory,
                           worker=worker, job=job, reusable=reusable, idle=idle))
    return output


if __name__ == "__main__":
    try:
        if len(sys.argv) != 2:
            sys.exit(64)
        config = configuration(Path(sys.argv[1]))
        docker_path = next((path for path in DOCKER_PATHS if os.access(path, os.X_OK)), None)
        if docker_path is None:
            sys.exit(1)
        print(json.dumps(collect(docker_path, config), allow_nan=False))
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError):
        sys.exit(1)
