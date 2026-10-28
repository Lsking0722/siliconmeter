# Packs Resources/AppIcon-1024.png (64 px and up) and Resources/AppIcon-small.png (16 and
# 32 px) into Resources/AppIcon.icns as PNG-backed entries. Needs Pillow.
#   python3 scripts/pack_icns.py Resources
import io, os, struct, sys
from PIL import Image

root = sys.argv[1] if len(sys.argv) > 1 else "Resources"
big = Image.open(os.path.join(root, "AppIcon-1024.png")).convert("RGBA")
small = Image.open(os.path.join(root, "AppIcon-small.png")).convert("RGBA")
entries = [("icp4", 16), ("icp5", 32), ("ic11", 32), ("icp6", 64), ("ic12", 64),
           ("ic07", 128), ("ic08", 256), ("ic13", 256), ("ic09", 512), ("ic14", 512), ("ic10", 1024)]
body = b""
for kind, px in entries:
    src = small if px <= 32 else big
    buf = io.BytesIO()
    src.resize((px, px), Image.LANCZOS).save(buf, "PNG", optimize=True)
    data = buf.getvalue()
    body += kind.encode() + struct.pack(">I", len(data) + 8) + data
with open(os.path.join(root, "AppIcon.icns"), "wb") as f:
    f.write(b"icns" + struct.pack(">I", len(body) + 8) + body)
print("wrote", os.path.join(root, "AppIcon.icns"))
