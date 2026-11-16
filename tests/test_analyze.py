import sys
import unittest

sys.path.insert(0, "tools")
import analyze


def span(sid, svc, kind, dur, parent=None):
    s = {"spanID": sid, "processID": svc, "duration": dur * 1000, "tags": [{"key": "span.kind", "value": kind}]}
    if parent:
        s["references"] = [{"spanID": parent}]
    return s


TRACE = {"processes": {"c": {"serviceName": "checkout"}, "p": {"serviceName": "payments"}},
         "spans": [span("1", "c", "server", 320), span("2", "c", "client", 310, "1"), span("3", "p", "server", 305, "2")]}


class AnalyzeTest(unittest.TestCase):
    def test_self_time_subtracts_downstream_calls(self):
        st = analyze.self_times(TRACE)
        self.assertAlmostEqual(st["checkout"], 10.0)
        self.assertAlmostEqual(st["payments"], 305.0)

    def test_slowest_service(self):
        t = analyze.p99_by_service([TRACE, TRACE])
        self.assertEqual(analyze.slowest(t), "payments")

    def test_percentile(self):
        self.assertEqual(analyze.pct(list(range(1, 101)), 99), 99)
        self.assertEqual(analyze.pct([], 99), 0.0)
