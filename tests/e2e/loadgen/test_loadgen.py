"""Unit tests of the load generator's bookkeeping."""

from collections.abc import Sequence

import pytest
import redis

import loadgen


class FakeServer:
    """Stands in for a Redis client: knows some keys, may be down for a while."""

    def __init__(self, known_keys: set[str], failures_before_answering: int = 0) -> None:
        self.known_keys = known_keys
        self.failures_left = failures_before_answering

    def mget(self, keys: Sequence[str]) -> list[object | None]:
        if self.failures_left > 0:
            self.failures_left -= 1
            raise redis.ConnectionError("down")
        return ["1" if key in self.known_keys else None for key in keys]


def test_longest_write_gap_finds_the_outage_between_acks() -> None:
    # Arrange
    ack_times = [1.0, 2.0, 9.5, 10.0]

    # Act
    gap = loadgen.longest_write_gap(ack_times, started=0.0, ended=10.5)

    # Assert
    assert gap == 7.5


def test_longest_write_gap_without_any_ack_is_the_whole_run() -> None:
    # Act
    gap = loadgen.longest_write_gap([], started=3.0, ended=13.0)

    # Assert
    assert gap == 10.0


def test_count_missing_spans_several_batches() -> None:
    # Arrange
    keys = [f"k:{index}" for index in range(loadgen.VERIFY_BATCH_SIZE + 10)]
    server = FakeServer(known_keys=set(keys[:-3]))

    # Act
    missing = loadgen.count_missing(server, keys)

    # Assert
    assert missing == 3


def test_count_missing_when_reachable_retries_while_the_server_is_down(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # Arrange
    monkeypatch.setattr(loadgen, "VERIFY_RETRY_SECONDS", 0.0)
    server = FakeServer(known_keys={"a"}, failures_before_answering=2)

    # Act
    missing = loadgen.count_missing_when_reachable(
        server, ["a", "b"], timeout_seconds=5.0, expected_missing=None
    )

    # Assert
    assert missing == 1


def test_count_missing_when_reachable_reports_a_server_that_never_answers(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # Arrange
    monkeypatch.setattr(loadgen, "VERIFY_RETRY_SECONDS", 0.0)
    server = FakeServer(known_keys=set(), failures_before_answering=10**6)

    # Act
    missing = loadgen.count_missing_when_reachable(
        server, ["a"], timeout_seconds=0.0, expected_missing=None
    )

    # Assert
    assert missing is None


def test_a_replica_missing_only_what_the_master_lost_is_not_waited_for(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # Arrange
    monkeypatch.setattr(loadgen, "VERIFY_RETRY_SECONDS", 0.0)
    replica = FakeServer(known_keys={"a"})

    # Act: a long timeout would make this test hang if the replica were waited for.
    missing = loadgen.count_missing_when_reachable(
        replica, ["a", "lost-by-the-master"], timeout_seconds=3600.0, expected_missing=1
    )

    # Assert
    assert missing == 1


def test_a_replica_still_catching_up_is_waited_for_until_the_timeout(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # Arrange
    monkeypatch.setattr(loadgen, "VERIFY_RETRY_SECONDS", 0.0)
    replica = FakeServer(known_keys=set())

    # Act
    missing = loadgen.count_missing_when_reachable(
        replica, ["a", "b"], timeout_seconds=0.0, expected_missing=0
    )

    # Assert
    assert missing == 2


def test_no_tls_options_without_kvrocks_tls(monkeypatch: pytest.MonkeyPatch) -> None:
    # Arrange
    monkeypatch.delenv("KVROCKS_TLS", raising=False)

    # Act
    options = loadgen.tls_options(check_hostname=True)

    # Assert
    assert options == {}


def test_tls_options_present_the_mounted_client_certificate(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # Arrange
    monkeypatch.setenv("KVROCKS_TLS", "1")

    # Act
    options = loadgen.tls_options(check_hostname=False)

    # Assert
    assert options["ssl"] is True
    assert options["ssl_certfile"] == "/tls/tls.crt"
    assert options["ssl_check_hostname"] is False
