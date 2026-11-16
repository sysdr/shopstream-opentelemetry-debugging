"""Day 5: the three tools that stop a slow dependency from taking everything down with it.

timeout   - never wait longer than the caller is willing to wait
retry     - try again a little later, with exponential backoff and full jitter, a bounded number of times
breaker   - after N consecutive failures stop calling for a while and fail fast; then let one trial through
"""
import random
import threading
import time


class CircuitOpen(Exception):
    pass


class CircuitBreaker:
    def __init__(self, failure_threshold=5, reset_timeout=5.0, clock=time.monotonic):
        self.failure_threshold, self.reset_timeout, self.clock = failure_threshold, reset_timeout, clock
        self.state, self.failures, self.opened_at = "closed", 0, 0.0
        self.trial_in_flight = False
        self.lock = threading.Lock()
        self.opens = 0

    def allow(self):
        with self.lock:
            if self.state == "open":
                if self.clock() - self.opened_at < self.reset_timeout:
                    return False
                self.state = "half_open"
                self.trial_in_flight = False
            if self.state == "half_open":
                if self.trial_in_flight:
                    return False
                self.trial_in_flight = True
            return True

    def record_success(self):
        with self.lock:
            self.state, self.failures, self.trial_in_flight = "closed", 0, False

    def record_failure(self):
        with self.lock:
            self.failures += 1
            if self.state == "half_open" or self.failures >= self.failure_threshold:
                if self.state != "open":
                    self.opens += 1
                self.state, self.opened_at, self.trial_in_flight = "open", self.clock(), False


def backoff(attempt, base=0.05, cap=0.5, rng=random):
    """Full jitter: a random wait between 0 and min(cap, base * 2^attempt)."""
    return rng.uniform(0, min(cap, base * (2 ** attempt)))
