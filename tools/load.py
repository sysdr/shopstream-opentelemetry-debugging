"""A small load generator: N checkouts from C concurrent clients; returns client latencies (ms)."""
import concurrent.futures as cf
import time

import shop


def run(n=200, concurrency=8, sku_count=20):
    def one(i):
        t = time.perf_counter()
        status, _ = shop.checkout(f"SKU-{i % sku_count}", 1)
        return status, (time.perf_counter() - t) * 1000
    with cf.ThreadPoolExecutor(concurrency) as ex:
        res = list(ex.map(one, range(n)))
    return [ms for _, ms in res], sum(1 for s, _ in res if s != 200)
