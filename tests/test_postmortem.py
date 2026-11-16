import sys
import unittest

sys.path.insert(0, "tools")
import incident


class PostmortemTest(unittest.TestCase):
    def test_timeline_and_numbers(self):
        ev = {"start": 1000.0, "first_error": 1004.0, "fire:InventoryPoolSaturated": 1016.0, "detected": 1016.0,
              "mitigated": 1036.0, "recovered": 1050.0}
        md, k = incident.markdown(ev, {"sent": 1000, "failed": 50},
                                  {"peak_error_ratio": 0.4, "peak_pool_in_use": 5, "trace_id": "abc", "acquire_ms": 1000})
        self.assertEqual((k["ttd"], k["ttm"], k["ttr"]), (16.0, 36.0, 50.0))
        lines = [l for l in md.splitlines() if l.startswith("| ") and "T+" in l]
        self.assertEqual([l.split("|")[2].strip() for l in lines], ["T+0 s", "T+4 s", "T+16 s", "T+36 s", "T+50 s"])
        self.assertIn("50 of 1000 checkouts failed (5.0%)", md)
