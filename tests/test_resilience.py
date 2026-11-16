import random
import unittest

from app.resilience import CircuitBreaker, backoff


class Clock:
    def __init__(self):
        self.t = 0.0

    def __call__(self):
        return self.t


class BreakerTest(unittest.TestCase):
    def test_opens_after_threshold_and_fails_fast(self):
        b = CircuitBreaker(3, 5.0, clock=Clock())
        for _ in range(3):
            self.assertTrue(b.allow())
            b.record_failure()
        self.assertEqual(b.state, "open")
        self.assertFalse(b.allow())
        self.assertEqual(b.opens, 1)

    def test_half_open_lets_one_trial_through(self):
        c = Clock()
        b = CircuitBreaker(1, 5.0, clock=c)
        b.allow(); b.record_failure()
        c.t = 5.1
        self.assertTrue(b.allow())
        self.assertFalse(b.allow())  # only one trial at a time
        b.record_success()
        self.assertEqual(b.state, "closed")

    def test_failed_trial_reopens(self):
        c = Clock()
        b = CircuitBreaker(1, 5.0, clock=c)
        b.allow(); b.record_failure()
        c.t = 6
        b.allow(); b.record_failure()
        self.assertEqual(b.state, "open")
        self.assertEqual(b.opens, 2)

    def test_backoff_is_jittered_and_capped(self):
        rng = random.Random(1)
        waits = [backoff(5, base=0.05, cap=0.5, rng=rng) for _ in range(200)]
        self.assertTrue(all(0 <= w <= 0.5 for w in waits))
        self.assertGreater(len(set(round(w, 4) for w in waits)), 150)
