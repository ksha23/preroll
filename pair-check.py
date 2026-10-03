#!/usr/bin/env python3
"""Check that both speakers of each AirPlay stereo pair advertise the same features.

On macOS 27.0.1, a HomePod stereo pair whose two speakers disagree on feature
bit 96 plays only one side from a Mac. See "macOS 27" in NOTES.md.

    ./pair-check.py [seconds to browse, default 4]
"""
import base64
import re
import subprocess
import sys
import time

BIT = 96


def browse(seconds):
    p = subprocess.Popen(["dns-sd", "-Z", "_airplay._tcp", "local"],
                         stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    time.sleep(seconds)
    p.terminate()
    out, _ = p.communicate()
    return out.decode("utf-8", "replace")


def unescape(name):
    # dns-sd writes non-alphanumeric bytes as \DDD decimal escapes
    raw = re.sub(rb"\\(\d{3})", lambda m: bytes([int(m.group(1))]), name.encode())
    return raw.decode("utf-8", "replace")


def speakers(text):
    found = {}
    for line in text.splitlines():
        if "._airplay._tcp" not in line or " TXT " not in line.replace("\t", " "):
            continue
        name = unescape(line.split("._airplay._tcp")[0].strip())
        found[name] = dict(re.findall(r'"(\w+)=([^"]*)"', line))
    return found


def features(fex):
    raw = base64.b64decode(fex + "=" * (-len(fex) % 4))
    return int.from_bytes(raw, "little")


def main():
    seconds = float(sys.argv[1]) if len(sys.argv) > 1 else 4
    pairs = {}
    for name, txt in speakers(browse(seconds)).items():
        if "tsid" in txt and "fex" in txt:
            pairs.setdefault(txt["tsid"], []).append((name, txt))
    if not pairs:
        print("No stereo pairs found.")
        return

    for members in pairs.values():
        print(members[0][1].get("gpn", "Stereo pair"))
        bits = {}
        for name, txt in sorted(members):
            bits[name] = features(txt["fex"])
            has = "yes" if bits[name] >> BIT & 1 else "no"
            print(f"  {name:28} {txt.get('model', '?'):18} bit {BIT}: {has}")
        values = list(bits.values())
        if len(values) < 2:
            print("  Only one speaker answered. Run again, or browse longer.")
        elif len({v >> BIT & 1 for v in values}) > 1:
            print("  MISMATCH: expect only one side to play from a macOS 27 Mac.")
            print("  Restart both speakers, then run this again.")
        else:
            diff = values[0] ^ values[1]
            other = [i for i in range(diff.bit_length()) if diff >> i & 1]
            print(f"  OK: both speakers agree on bit {BIT}.")
            if other:
                print(f"  (They differ on other bits, not known to matter: {other})")


if __name__ == "__main__":
    main()
