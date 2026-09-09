"""将本仓库四个库内联为单文件，不联网、不引入第三方构建依赖。"""
import hashlib
import pathlib
import sys

root = pathlib.Path(__file__).resolve().parents[1]
destination = pathlib.Path(sys.argv[1])
destination.mkdir(parents=True, exist_ok=True)
source = (root / "vps-init.sh").read_text(encoding="utf-8")
for name in ("core", "modules", "access", "ui"):
    library = (root / "lib" / f"{name}.sh").read_text(encoding="utf-8")
    source = source.replace(f'source "$BASE/lib/{name}.sh"', library)
payload = source.encode("utf-8")
(destination / "vps-init.sh").write_bytes(payload)
(destination / "SHA256SUMS").write_text(
    f"{hashlib.sha256(payload).hexdigest()}  vps-init.sh\n", encoding="ascii"
)
print(f"单文件发行包：{len(payload):,} 字节 → {destination}")
