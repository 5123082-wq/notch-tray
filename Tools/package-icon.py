"""Package PNGs produced by MakeIcon.swift into a modern macOS ICNS file."""
from pathlib import Path
import struct
import sys

source, output = map(Path, sys.argv[1:3])
pairs = [
    ('icp4', 'icon_16x16.png'), ('icp5', 'icon_32x32.png'),
    ('icp6', 'icon_32x32@2x.png'), ('ic07', 'icon_128x128.png'),
    ('ic08', 'icon_256x256.png'), ('ic09', 'icon_512x512.png'),
    ('ic10', 'icon_512x512@2x.png'),
]
chunks = []
for kind, name in pairs:
    data = (source / name).read_bytes()
    chunks.append(kind.encode() + struct.pack('>I', len(data) + 8) + data)
payload = b''.join(chunks)
output.write_bytes(b'icns' + struct.pack('>I', len(payload) + 8) + payload)
