import json
import subprocess
import threading
from queue import Queue, Empty
from typing import Any


class DockerTransport:
    """Manages a persistent SBCL container, communicating via JSON-line over stdio."""

    def __init__(
        self,
        image: str = "sbcl-multitool:latest",
        workdir: str | None = None,
        network: str = "bridge",
        memory: str = "512m",
        cpus: float = 1.0,
        swank_port: int = 4005,
    ):
        self.image = image
        self.workdir = workdir
        self.network = network
        self.memory = memory
        self.cpus = cpus
        self.swank_port = swank_port
        self._proc: subprocess.Popen[str] | None = None
        self._lock = threading.Lock()
        self._responses: dict[str, Queue] = {}
        self._reader_thread: threading.Thread | None = None

    def start(self) -> None:
        cmd = [
            "docker", "run", "-i", "--rm",
            "--network", self.network,
            "--memory", self.memory,
            f"--cpus={self.cpus}",
            "-p", f"{self.swank_port}:4005",
        ]
        if self.workdir:
            cmd += ["-v", f"{self.workdir}:/work", "-w", "/work"]
        cmd.append(self.image)

        self._proc = subprocess.Popen(
            cmd,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            bufsize=1,
        )
        self._reader_thread = threading.Thread(
            target=self._read_loop, daemon=True
        )
        self._reader_thread.start()

    def _read_loop(self) -> None:
        assert self._proc is not None
        assert self._proc.stdout is not None
        for line in self._proc.stdout:
            line = line.strip()
            if not line:
                continue
            try:
                msg = json.loads(line)
                rid = msg.get("id")
                if rid and rid in self._responses:
                    self._responses[rid].put(msg)
            except json.JSONDecodeError:
                pass

    def call(self, method: str, params: dict[str, Any] | None = None, timeout: float = 120) -> dict:
        import uuid
        rid = str(uuid.uuid4())
        q: Queue = Queue()
        self._responses[rid] = q

        request = {"id": rid, "method": method, "params": params or {}}
        line = json.dumps(request) + "\n"
        with self._lock:
            assert self._proc is not None
            assert self._proc.stdin is not None
            self._proc.stdin.write(line)
            self._proc.stdin.flush()

        try:
            return q.get(timeout=timeout)
        except Empty:
            return {"id": rid, "ok": False, "error": "timeout"}
        finally:
            del self._responses[rid]

    def stop(self) -> None:
        if self._proc and self._proc.stdin:
            self._proc.stdin.close()
            self._proc.terminate()
            self._proc.wait(timeout=5)
            self._proc = None

    def reset(self) -> None:
        """Kill and restart the container for a fresh SBCL image."""
        self.stop()
        self.start()
