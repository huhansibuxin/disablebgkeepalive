#!/usr/bin/env python3
import sys, os, io, lzma, tarfile, re

DEB = sys.argv[1] if len(sys.argv) > 1 else r"_artifacts/roothide/com.huhansibuxin.disablebgkeepalive_1.1.0-1_iphoneos-arm64e.deb"

# --- 1. parse ar archive (deb) ---
with open(DEB, "rb") as f:
    data = f.read()
assert data[:8] == b"!<arch>\n", "not a deb/ar archive"
off = 8
members = {}
while off < len(data):
    if data[off:off+1] == b"\n":
        off += 1
        continue
    hdr = data[off:off+60]
    name = hdr[0:16].decode().strip()
    size = int(hdr[48:58].decode().strip())
    body = data[off+60:off+60+size]
    members[name] = body
    off += 60 + size
    if size % 2 == 1:
        off += 1
print("== ar members ==", list(members.keys()))

# --- 2. find control + data ---
control_raw = None
dylib_bytes = None
for n, body in members.items():
    if n == "control.tar.xz" or n == "control.tar.gz":
        # decompress control
        if n.endswith(".xz"):
            raw = lzma.decompress(body)
        else:
            import gzip; raw = gzip.decompress(body)
        tf = tarfile.open(fileobj=io.BytesIO(raw))
        for m in tf.getmembers():
            if m.name.endswith("control"):
                control_raw = tf.extractfile(m).read().decode("utf-8", "replace")
    elif n.startswith("data.tar"):
        if n.endswith(".xz"):
            raw = lzma.decompress(body)
        elif n.endswith(".gz"):
            import gzip; raw = gzip.decompress(body)
        else:
            raw = body
        tf = tarfile.open(fileobj=io.BytesIO(raw))
        for m in tf.getmembers():
            if m.name.endswith(".dylib"):
                dylib_bytes = tf.extractfile(m).read()
                print("== dylib path ==", m.name, "size", len(dylib_bytes))

# --- 3. control checks ---
print("\n== DEBIAN/control ==")
print(control_raw)
assert "Package: com.huhansibuxin.disablebgkeepalive" in control_raw, "PACKAGE NAME MISMATCH"
assert "Name: DisableBgKeepalive" in control_raw, "NAME MISMATCH"
assert "Version: 1.0.1" in control_raw, "VERSION MISMATCH"
print("control OK: package/name/version match")

# --- 4. dylib method-name string checks ---
methods = [
    b"beginBackgroundTaskWithExpirationHandler:",
    b"beginBackgroundTaskWithName:expirationHandler:",
    b"setMinimumBackgroundFetchInterval:",
    b"setKeepAliveTimeout:handler:",
    b"submitTaskRequest:error:",
    b"setDesiredPushTypes:",
    b"startUpdatingLocation",
    b"startUpdatingHeading",
    b"startMonitoringSignificantLocationChanges",
    b"initWithDelegate:queue:options:",
    b"backgroundSessionConfigurationWithIdentifier:",
    b"enableBackgroundDeliveryForType:frequency:withCompletion:",
    b"didReceiveRemoteNotification:fetchCompletionHandler:",
]
print("\n== dylib hook method-name probe ==")
missing = []
for m in methods:
    present = m in dylib_bytes
    print(("  [OK] " if present else "  [MISSING] ") + m.decode())
    if not present:
        missing.append(m)
if missing:
    print("\nFAIL: some hooks not found in dylib:", [x.decode() for x in missing])
    sys.exit(2)
print("\nALL HOOKS PRESENT in dylib -> verification PASSED")
