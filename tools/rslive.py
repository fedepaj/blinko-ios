#!/usr/bin/env python3
"""Remote session client for the RSLog iOS app (Settings > Debug > Remote session).

Connect over USB (recommended, no Wi-Fi needed):
    pymobiledevice3 usbmux forward 7777 7777 &     # then host = 127.0.0.1
or over Wi-Fi with the address shown in the app's Settings.

  rslive.py [--host H] [--port P] get                      current settings + camera
  rslive.py stats                                          one stats sample
  rslive.py watch [--seconds N]                            live stats + messages
  rslive.py set KEY VALUE                                  fps exposure iso lensPosition zoom minContrast multiSource axis camera note
  rslive.py reset                                          clear messages / receiver
  rslive.py messages                                       messages decoded so far
  rslive.py frame OUT.png [--step 2]                       grab one frame (BGRA, columns subsampled)
  rslive.py record [--seconds 2] [--note TEXT] [--out DIR] record on the phone and pull the .rsrec

Library use: `with RSLive() as s: s.record(2, "R4 rgb", out_dir)`.
Wire format: u32 big-endian length | u8 kind (0 JSON, 1 binary) | payload.
"""
import argparse, json, os, socket, struct, sys, time


class RSLive:
    def __init__(self, host="127.0.0.1", port=7777, timeout=30.0):
        self.sock = socket.create_connection((host, port), timeout=timeout)
        self.sock.settimeout(timeout)

    def __enter__(self): return self
    def __exit__(self, *a): self.close()
    def close(self): self.sock.close()

    def send(self, obj):
        payload = json.dumps(obj).encode()
        self.sock.sendall(struct.pack(">IB", len(payload), 0) + payload)

    def _read(self, n):
        buf = bytearray()
        while len(buf) < n:
            chunk = self.sock.recv(min(1 << 20, n - len(buf)))
            if not chunk: raise ConnectionError("connection closed")
            buf += chunk
        return bytes(buf)

    def recv(self):
        """(kind, payload): kind 0 -> dict, kind 1 -> bytes."""
        length, kind = struct.unpack(">IB", self._read(5))
        payload = self._read(length)
        return kind, (json.loads(payload) if kind == 0 else payload)

    def wait(self, types, timeout=30.0, on_other=None):
        """Next JSON message whose type is in `types` (stats broadcasts are skipped unless asked for)."""
        end = time.time() + timeout
        while time.time() < end:
            kind, msg = self.recv()
            if kind == 0 and msg.get("type") in types: return msg
            if kind == 0 and msg.get("type") == "error": raise RuntimeError(msg.get("msg"))
            if on_other: on_other(kind, msg)
        raise TimeoutError(f"no {types} within {timeout}s")

    # ---- commands
    def get(self): self.send({"cmd": "get"}); return self.wait({"settings"})["settings"]
    def set(self, key, value): self.send({"cmd": "set", "key": key, "value": value}); return self.wait({"settings"})["settings"]
    def stats(self): self.send({"cmd": "stats"}); return self.wait({"stats"})
    def reset(self): self.send({"cmd": "reset"}); return self.wait({"ok"})
    def messages(self): self.send({"cmd": "messages"}); return self.wait({"messages"})["messages"]

    def frame(self, step=2):
        """(header dict, bytes) — BGRA rows, header w/h already subsampled."""
        self.send({"cmd": "frame", "step": step})
        hdr = self.wait({"frame"}); kind, data = self.recv()
        assert kind == 1 and len(data) == hdr["w"] * hdr["h"] * 4
        return hdr, data

    def record(self, seconds=2.0, note="", out_dir=".", keep=True, progress=None):
        """Record on the phone, pull the .rsrec into out_dir, return its path."""
        self.send({"cmd": "record", "seconds": seconds, "note": note, "send": True, "keep": keep})
        self.wait({"recording"})                                  # started
        done = self.wait({"recording"}, timeout=seconds + 30, on_other=progress)
        hdr = self.wait({"file"}, timeout=120, on_other=progress)
        kind, data = self.recv()
        assert kind == 1 and len(data) == hdr["size"]
        os.makedirs(out_dir, exist_ok=True)
        path = os.path.join(out_dir, hdr["name"])
        with open(path, "wb") as f: f.write(data)
        return path, done.get("summary", "")


def frame_to_png(hdr, data, out):
    import numpy as np
    from PIL import Image
    a = np.frombuffer(data, np.uint8).reshape(hdr["h"], hdr["w"], 4)
    Image.fromarray(a[:, :, [2, 1, 0]]).save(out)


def fmt_stats(s):
    tr = " ".join(f"#{t['id']}({int(t['x']*100)},{int(t['y']*100)} {t['mode']} {t['packets']}p)" for t in s.get("tracks", []))
    return (f"fps={s['fps']:.0f} pkt/s={s['pkt_per_s']:.1f} rpc={s['rows_per_chip']:.1f} mode={s['mode']} pilots={s['pilots']} "
            f"pkts={s['packets']} msgs={s['messages']} peak={s['peak']} sat={s['sat']:.3f} exp={s['exposure_us']:.0f}us iso={s['iso']:.0f} "
            f"still={int(s['still'])} {tr}")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--host", default="127.0.0.1"); ap.add_argument("--port", type=int, default=7777)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("get"); sub.add_parser("stats"); sub.add_parser("reset"); sub.add_parser("messages")
    w = sub.add_parser("watch"); w.add_argument("--seconds", type=float, default=10)
    st = sub.add_parser("set"); st.add_argument("key"); st.add_argument("value")
    fr = sub.add_parser("frame"); fr.add_argument("out"); fr.add_argument("--step", type=int, default=2)
    rc = sub.add_parser("record"); rc.add_argument("--seconds", type=float, default=2); rc.add_argument("--note", default="")
    rc.add_argument("--out", default="."); rc.add_argument("--no-keep", action="store_true")
    a = ap.parse_args()
    with RSLive(a.host, a.port) as s:
        if a.cmd == "get": print(json.dumps(s.get(), indent=1))
        elif a.cmd == "stats": print(fmt_stats(s.stats()))
        elif a.cmd == "reset": s.reset(); print("reset")
        elif a.cmd == "messages":
            for m in s.messages(): print(f"{time.strftime('%H:%M:%S', time.localtime(m['t']))} [{m['level_name']}] src{m['source']} slot{m['slot']} {m['text']}")
        elif a.cmd == "set":
            v = a.value
            try: v = json.loads(v)
            except ValueError: pass
            print(json.dumps(s.set(a.key, v), indent=1))
        elif a.cmd == "frame":
            hdr, data = s.frame(a.step); frame_to_png(hdr, data, a.out); print("saved", a.out, hdr["w"], "x", hdr["h"])
        elif a.cmd == "record":
            t0 = time.time()
            path, summary = s.record(a.seconds, a.note, a.out, keep=not a.no_keep)
            print(f"{path}  ({summary})  in {time.time() - t0:.1f}s")
        elif a.cmd == "watch":
            end = time.time() + a.seconds; last = 0
            while time.time() < end:
                kind, msg = s.recv()
                if kind != 0: continue
                if msg.get("type") == "stats" and time.time() - last > 1: last = time.time(); print(fmt_stats(msg))
                elif msg.get("type") == "message": print(f"  MSG [{msg.get('level_name')}] src{msg.get('source')} slot{msg.get('slot')} {msg.get('text')}")


if __name__ == "__main__":
    main()
