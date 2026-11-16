"""Closed-loop clients that browse (/catalog) and buy (/checkout), each with a 2 s timeout like a browser."""
import concurrent.futures as cf
import random
import threading
import time
import urllib.request

import shop


def run(seconds=20, clients=24, buy_share=0.3):
    stats = {"catalog": [0, 0, []], "checkout": [0, 0, []]}  # sent, ok, latencies
    lock = threading.Lock()
    end = time.time() + seconds

    def client(k):
        rng = random.Random(k)
        while time.time() < end:
            route = "checkout" if rng.random() < buy_share else "catalog"
            t = time.perf_counter()
            try:
                if route == "catalog":
                    with urllib.request.urlopen(shop.CHECKOUT + "/catalog", timeout=2) as r:
                        ok = r.status == 200
                else:
                    ok = shop.call("POST", shop.CHECKOUT + "/checkout", {"sku": "SKU-1", "qty": 1}, timeout=2)[0] == 200
            except Exception:
                ok = False
            ms = (time.perf_counter() - t) * 1000
            with lock:
                s = stats[route]
                s[0] += 1
                s[1] += ok
                s[2].append(ms)
            if not ok:
                time.sleep(0.05)

    with cf.ThreadPoolExecutor(clients) as ex:
        list(ex.map(client, range(clients)))
    return stats
