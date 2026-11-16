"""Write load that proves whether a failover lost acknowledged writes.

Each worker keeps one persistent connection, like a pooled application client, and
records every write the server acknowledged. Once the load stops, every acknowledged
key is read back from the write endpoint and from each Kvrocks pod.

The last line printed is a JSON report; the end-to-end harness asserts on it.
"""

from __future__ import annotations

import argparse
import json
import os
import signal
import threading
import time
from collections.abc import Iterator, Sequence
from dataclasses import dataclass, field
from typing import Protocol

import redis
from redis.backoff import NoBackoff
from redis.retry import Retry

SOCKET_TIMEOUT_SECONDS = 2.0
PAUSE_AFTER_ERROR_SECONDS = 0.05
VERIFY_BATCH_SIZE = 500
VERIFY_RETRY_SECONDS = 2.0
TLS_DIR = "/tls"


class KeyReader(Protocol):
    """The part of a Redis client the verification needs."""

    def mget(self, keys: Sequence[str]) -> Sequence[object | None]:
        """Returns the value of each key, or None when it does not exist."""
        ...


@dataclass
class WorkerLog:
    """What one worker observed while writing."""

    acked_keys: list[str] = field(default_factory=list)
    ack_times: list[float] = field(default_factory=list)
    errors: dict[str, int] = field(default_factory=dict)


def tls_options(check_hostname: bool) -> dict[str, object]:
    """TLS settings of a client, from KVROCKS_TLS and the certificates mounted on /tls.

    Applications check the name of the write endpoint against the server certificate, so the
    load does too. The certificate does not cover the pods: reading them back skips that check.
    """
    if os.environ.get("KVROCKS_TLS") != "1":
        return {}
    return {
        "ssl": True,
        "ssl_ca_certs": f"{TLS_DIR}/ca.crt",
        "ssl_certfile": f"{TLS_DIR}/tls.crt",
        "ssl_keyfile": f"{TLS_DIR}/tls.key",
        "ssl_cert_reqs": "required",
        "ssl_check_hostname": check_hostname,
    }


def connect(host: str, port: int, password: str | None, check_hostname: bool = True) -> redis.Redis:
    """Opens a client with short timeouts, so an outage shows up as errors.

    redis-py retries a failed command three times by default. Retries are turned off: every
    failure is counted, and a write that failed is never sent again.
    """
    return redis.Redis(
        host=host,
        port=port,
        password=password,
        socket_timeout=SOCKET_TIMEOUT_SECONDS,
        socket_connect_timeout=SOCKET_TIMEOUT_SECONDS,
        retry=Retry(NoBackoff(), 0),
        decode_responses=True,
        **tls_options(check_hostname),  # type: ignore[arg-type]
    )


def write_until(
    stop: threading.Event, client: redis.Redis, key_prefix: str, log: WorkerLog
) -> None:
    """Writes new keys until told to stop, recording only acknowledged writes.

    A failed write is never retried under the same key: whether the server applied
    it is unknown, so it must not count as acknowledged.
    """
    sequence = 0
    while not stop.is_set():
        sequence += 1
        key = f"{key_prefix}:{sequence}"
        try:
            client.set(key, sequence)
        except redis.RedisError as error:
            kind = type(error).__name__
            log.errors[kind] = log.errors.get(kind, 0) + 1
            time.sleep(PAUSE_AFTER_ERROR_SECONDS)
            continue
        log.acked_keys.append(key)
        log.ack_times.append(time.monotonic())


def longest_write_gap(ack_times: Sequence[float], started: float, ended: float) -> float:
    """Returns the longest stretch without any acknowledged write, in seconds."""
    points = [started, *sorted(ack_times), ended]
    return max(later - earlier for earlier, later in zip(points, points[1:], strict=False))


def batches(keys: Sequence[str], size: int) -> Iterator[Sequence[str]]:
    """Yields the keys in chunks of at most `size`."""
    for start in range(0, len(keys), size):
        yield keys[start : start + size]


def count_missing(reader: KeyReader, keys: Sequence[str]) -> int:
    """Counts the keys the server no longer has."""
    missing = 0
    for batch in batches(keys, VERIFY_BATCH_SIZE):
        missing += sum(value is None for value in reader.mget(batch))
    return missing


def count_missing_when_reachable(
    reader: KeyReader, keys: Sequence[str], timeout_seconds: float, expected_missing: int | None
) -> int | None:
    """Counts missing keys, retrying while the server is unreachable or catching up.

    Args:
        reader: Client of the server to check.
        keys: Keys that were acknowledged.
        timeout_seconds: How long to keep retrying.
        expected_missing: For a replica, how many keys the master itself lost: the
            replica is still catching up while it misses more than that. None for
            the master, whose first answer is final.

    Returns:
        The number of missing keys, or None if the server never answered.
    """
    deadline = time.monotonic() + timeout_seconds
    missing: int | None = None
    while True:
        try:
            missing = count_missing(reader, keys)
        except redis.RedisError:
            missing = None
        catching_up = expected_missing is not None and (missing or 0) > expected_missing
        if (missing is not None and not catching_up) or time.monotonic() >= deadline:
            return missing
        time.sleep(VERIFY_RETRY_SECONDS)


def parse_args() -> argparse.Namespace:
    """Parses the command line."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", required=True, help="write endpoint")
    parser.add_argument("--port", type=int, default=6379)
    parser.add_argument("--workers", type=int, default=4)
    parser.add_argument(
        "--max-duration-seconds", type=float, default=600.0, help="SIGTERM stops the load earlier"
    )
    parser.add_argument("--settle-seconds", type=float, default=30.0)
    parser.add_argument("--verify-timeout-seconds", type=float, default=120.0)
    parser.add_argument("--key-prefix", default="load")
    parser.add_argument("--pod-host", action="append", default=[], help="Kvrocks pod to verify")
    return parser.parse_args()


def main() -> None:
    """Runs the load, verifies it, and prints the JSON report."""
    args = parse_args()
    password = os.environ.get("KVROCKS_PASSWORD") or None

    # The harness sends SIGTERM once the failure under test is over.
    stop = threading.Event()
    signal.signal(signal.SIGTERM, lambda _signum, _frame: stop.set())

    logs = [WorkerLog() for _ in range(args.workers)]
    started = time.monotonic()
    threads = [
        threading.Thread(
            target=write_until,
            args=(stop, connect(args.host, args.port, password), f"{args.key_prefix}:{index}", log),
        )
        for index, log in enumerate(logs)
    ]
    for thread in threads:
        thread.start()
    stop.wait(args.max_duration_seconds)
    stop.set()
    for thread in threads:
        thread.join()
    ended = time.monotonic()

    # Gives the cluster time to finish a failover before reading the keys back.
    time.sleep(args.settle_seconds)

    acked_keys = [key for log in logs for key in log.acked_keys]
    errors: dict[str, int] = {}
    for log in logs:
        for kind, count in log.errors.items():
            errors[kind] = errors.get(kind, 0) + count

    lost = count_missing_when_reachable(
        connect(args.host, args.port, password),
        acked_keys,
        args.verify_timeout_seconds,
        expected_missing=None,
    )
    missing_by_pod = {
        host: count_missing_when_reachable(
            connect(host, args.port, password, check_hostname=False),
            acked_keys,
            args.verify_timeout_seconds,
            expected_missing=lost or 0,
        )
        for host in args.pod_host
    }

    report = {
        "acked": len(acked_keys),
        "lost": lost,
        "missing_by_pod": missing_by_pod,
        "errors": errors,
        "duration_seconds": round(ended - started, 2),
        "longest_write_gap_seconds": round(
            longest_write_gap([t for log in logs for t in log.ack_times], started, ended), 2
        ),
    }
    print(json.dumps(report))


if __name__ == "__main__":
    main()
