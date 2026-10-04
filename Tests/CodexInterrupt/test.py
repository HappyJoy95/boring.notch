import json
import os
from pathlib import Path
import socket
import struct
import subprocess
import tempfile
import threading

root = Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix="notch-stop-") as folder:
    binary = str(Path(folder) / "test")
    subprocess.run(["swiftc", str(root / "BoringNotchXPCHelper/CodexDesktopInstructionSender.swift"), str(root / "Tests/CodexInterrupt/main.swift"), "-o", binary], check=True)
    ipc = Path(folder) / "ipc"
    ipc.mkdir()
    path = str(ipc / "ipc.sock")
    server = socket.socket(socket.AF_UNIX)
    server.bind(path)
    os.chmod(path, 0o600)
    server.listen(1)
    server.settimeout(10)
    requests = []
    errors = []
    def run_server():
        try:
            conn, _ = server.accept()
            conn.settimeout(10)
            with conn:
                def read_exact(n):
                    result = b""
                    while len(result) < n:
                        chunk = conn.recv(n - len(result))
                        assert chunk
                        result += chunk
                    return result
                for index in range(3):
                    size = struct.unpack("<I", read_exact(4))[0]
                    request = json.loads(read_exact(size))
                    requests.append(request)
                    response = {"requestId": request["requestId"], "handledByClientId": "owner", "result": {"ok": True}}
                    if index == 0:
                        response["result"] = {"clientId": "test-client"}
                    payload = json.dumps(response).encode()
                    conn.sendall(struct.pack("<I", len(payload)) + payload)
        except Exception as error:
            errors.append(error)
    worker = threading.Thread(target=run_server)
    worker.start()
    result = subprocess.run([binary], env={**os.environ, "CODEX_HOME": folder}, capture_output=True, text=True, timeout=15)
    worker.join(12)
    server.close()
    assert not worker.is_alive() and not errors, errors
    assert result.returncode == 0, result.stderr
    assert [r["method"] for r in requests] == ["initialize", "thread-owner-discovery", "thread-follower-interrupt-turn"]
    stop = requests[-1]
    assert stop["version"] == 3
    assert stop["targetClientId"] == "owner"
    assert stop["params"] == {"conversationId": "test-conversation", "mode": "user-stop"}
    print("PASS: mock IPC routes user-stop to the correct conversation owner using version 3")
