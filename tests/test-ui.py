"""Linux PTY 菜单测试：仅启动菜单并选择只读页面/退出，不修改系统。"""
import errno
import os
import pathlib
import pty
import select
import subprocess
import time

ROOT = pathlib.Path(__file__).resolve().parents[1]


def menu_session(no_color=False):
    master, slave = pty.openpty()
    env = dict(os.environ, TERM="xterm-256color")
    env.pop("NO_COLOR", None)
    if no_color:
        env["NO_COLOR"] = "1"
    process = subprocess.Popen(
        ["bash", str(ROOT / "vps-init.sh"), "menu"],
        stdin=slave, stdout=slave, stderr=slave, env=env, close_fds=True,
    )
    os.close(slave)
    output = bytearray()
    stage = 0
    deadline = time.monotonic() + 20
    try:
        while time.monotonic() < deadline:
            if select.select([master], [], [], 0.2)[0]:
                try:
                    chunk = os.read(master, 65536)
                except OSError as error:
                    if error.errno == errno.EIO:
                        break
                    raise
                if not chunk:
                    break
                output.extend(chunk)
            text = output.decode("utf-8", errors="replace")
            if stage == 0 and "选择操作 [0]" in text:
                os.write(master, b"5\n")
                stage = 1
            elif stage == 1 and "按回车返回菜单" in text:
                os.write(master, b"\n0\n")
                stage = 2
            if process.poll() is not None:
                break
        assert process.wait(timeout=3) == 0
        assert stage == 2
        text = output.decode("utf-8")
        assert "BBRv3 需要内核实现" in text
        assert "一键优化" in text
        assert (b"\x1b[" in output) != no_color
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()
        os.close(master)


menu_session()
menu_session(no_color=True)
print("PASS: 真实 PTY 菜单、网络只读页面、返回与退出、ANSI/NO_COLOR。")
