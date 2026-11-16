import json
import logging
import sys
import unittest

sys.path.insert(0, "tools")
from opentelemetry import trace
from opentelemetry.sdk.trace import TracerProvider

from app import telemetry
import shop


class LogFormatTest(unittest.TestCase):
    def test_log_line_carries_trace_and_span_id(self):
        trace.set_tracer_provider(TracerProvider())
        tracer = trace.get_tracer("test")
        rec = logging.LogRecord("shop", logging.INFO, __file__, 1, "order placed", None, None)
        rec.fields = {"order_id": "ORD-1"}
        with tracer.start_as_current_span("x") as span:
            doc = json.loads(telemetry.JsonFormatter().format(rec))
            self.assertEqual(doc["trace_id"], format(span.get_span_context().trace_id, "032x"))
        self.assertEqual(doc["order_id"], "ORD-1")
        self.assertEqual(doc["msg"], "order placed")

    def test_log_line_without_span_has_no_trace_id(self):
        rec = logging.LogRecord("shop", logging.INFO, __file__, 1, "hello", None, None)
        self.assertNotIn("trace_id", json.loads(telemetry.JsonFormatter().format(rec)))


class MetricParseTest(unittest.TestCase):
    def test_sums_matching_series(self):
        text = ('http_requests_total{route="/checkout",service="checkout",status="200"} 3.0\n'
                'http_requests_total{route="/checkout",service="checkout",status="502"} 1.0\n'
                'http_requests_total{route="/reserve",service="inventory",status="200"} 9.0\n')
        self.assertEqual(shop.metric_value(text, "http_requests_total", service="checkout"), 4.0)
        self.assertEqual(shop.metric_value(text, "http_requests_total", service="checkout", status="200"), 3.0)


if __name__ == "__main__":
    unittest.main()
