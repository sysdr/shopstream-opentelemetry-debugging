"""Steady background traffic in a thread: `rps` checkouts per second until stopped."""
import threading
import time

import shop


class Traffic:
    def __init__(self, rps=20, path_mix=None):
        self.rps, self.stop_flag = rps, threading.Event()
        self.sent = self.failed = 0
        self.lock = threading.Lock()
        self.threads = []

    def _worker(self, offset):
        i = offset
        while not self.stop_flag.is_set():
            t = time.perf_counter()
            try:
                status, _ = shop.checkout(f"SKU-{i % 20}", 1)
            except Exception:
                status = 0
            with self.lock:
                self.sent += 1
                self.failed += status != 200
            i += 4
            time.sleep(max(0.0, 4 / self.rps - (time.perf_counter() - t)))

    def start(self):
        for k in range(4):
            th = threading.Thread(target=self._worker, args=(k,), daemon=True)
            th.start()
            self.threads.append(th)
        return self

    def stop(self):
        self.stop_flag.set()
        for th in self.threads:
            th.join(timeout=10)
