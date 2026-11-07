#!/usr/bin/env python3
import argparse
import io
import threading
import time
import unittest
from unittest.mock import patch
import numpy as np
import falcon_ics as ics


class Resilience(unittest.TestCase):
    def server(self):
        return ics.Helper(argparse.Namespace(settings='/nonexistent', mock=True, game_port=47811, parent_pid=0))

    def test_profiles_and_saved_boolean(self):
        self.assertEqual(ics.transport({}), (100, 80, 100))
        self.assertEqual(ics.transport(ics.parse_godot_cfg('[ics]\nresilient_audio=false\n')), (30, 25, 40))

    def test_buffer_bounds_rebuffer_and_drift(self):
        r = ics.Ring(target=4800)
        self.assertIsNone(r.read())
        for _ in range(150):
            r.write(np.zeros(480))
        self.assertLessEqual(r.fill(), r.cap)
        self.assertGreater(r.overruns, 0)
        for _ in range(200):
            r.read()
        self.assertGreater(r.underruns, 0)
        self.assertFalse(r.primed)
        self.assertIsNone(r.read())
        r.write(np.zeros(4800))
        self.assertEqual(len(r.read()), 480)

    def test_slow_scan_does_not_block_tick_or_config(self):
        s = self.server()
        entered, release = threading.Event(), threading.Event()
        def scan():
            entered.set()
            release.wait(2)
        s.rescan = scan
        s.control_thread = threading.Thread(target=s.control_loop)
        s.control_thread.start()
        try:
            self.assertTrue(entered.wait(1))
            start = time.monotonic()
            for _ in range(10):
                s.tick()
            s.apply_cfg({'resilient_audio': False})
            self.assertLess(time.monotonic() - start, .5)
            self.assertFalse(s.cfg['resilient_audio'])
            self.assertTrue(s.control_event.is_set())
            self.assertNotIn('latency_ms', s.status())
        finally:
            s.running = False
            release.set()
            s.control_event.set()
            s.control_thread.join(3)
            s.sock.close()
        self.assertFalse(s.control_thread.is_alive())

    def test_live_mode_rebuilds_fake_streams(self):
        s = self.server()
        s.args.mock = False
        dev = {"source": "@fake-mic", "sink": "@fake-out"}
        class Stream:
            def __init__(self, device, ring, name, latency_ms, **kwargs):
                self.ring, self.latency_ms = ring, latency_ms
                self.write_started, self.stalls = 0, 0
            def start(self): pass
            def close(self): pass
            def stream_state(self): return "fake"
        s.rescan = lambda: s._attach("pilot", dev)
        with patch.object(ics, 'Capture', Stream), patch.object(ics, 'Playback', Stream):
            s._attach("pilot", dev)
            self.assertEqual(s.out_rings['pilot'].target, 4800)
            self.assertEqual(s.plays['pilot'].latency_ms, 100)
            s.control_thread = threading.Thread(target=s.control_loop)
            s.control_thread.start()
            try:
                s.apply_cfg({'resilient_audio': False})
                limit = time.monotonic() + 2
                while time.monotonic() < limit and s.out_rings['pilot'].target != 1440:
                    time.sleep(.01)
                self.assertEqual(s.out_rings['pilot'].target, 1440)
                self.assertEqual(s.plays['pilot'].latency_ms, 40)
                self.assertEqual(s.caps['game'].latency_ms, 25)
                self.assertFalse(s.transport_mode)
            finally:
                s.running = False
                s.control_event.set()
                s.control_thread.join(3)
                s.sock.close()

    def test_stderr_tail_bounded(self):
        class Proc:
            stderr = io.BytesIO(b'x' * 10000)
        class Owner:
            err = ''
        owner = Owner()
        ics.drain_errors(Proc(), owner)
        for _ in range(50):
            if owner.err:
                break
            time.sleep(.01)
        self.assertLessEqual(len(owner.err), 512)
        self.assertTrue(owner.err)


if __name__ == '__main__':
    unittest.main()
