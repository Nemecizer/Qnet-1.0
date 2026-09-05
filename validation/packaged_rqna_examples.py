#!/usr/bin/env python3
"""Run every document marked infinite-buffer through the packaged GUI exporter and RQNA."""
import json
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent
app = root / "Qnet.app/Contents/MacOS/Qnet"
solver = root / "Qnet.app/Contents/Resources/bin/infinite/BNArqna/bna_rqna"
cases = sorted(
    path for path in (root / "input/examples").glob("*.bnet")
    if json.loads(path.read_text()).get("infiniteBuffers") is True
)
if not cases:
    raise SystemExit("No infinite-buffer example documents found")
with tempfile.TemporaryDirectory(prefix="qnet-packaged-rqna-") as temporary:
    for index, case in enumerate(cases):
        destination = Path(temporary) / str(index)
        subprocess.run(
            [str(app), "--export-cmp", str(case), str(destination)],
            capture_output=True, text=True, timeout=30, check=True,
        )
        data = destination / "qna.qna"
        if not data.is_file():
            raise SystemExit(f"The GUI exporter did not produce RQNA input: {case.name}")
        result = subprocess.run(
            [str(solver), str(data), "-c"],
            capture_output=True, text=True, timeout=30, check=True,
        )
        if "E[Q_" not in result.stdout:
            raise SystemExit(f"RQNA returned no population measures: {case.name}")
        print("PASS", case.name)
print(f"Packaged RQNA and production GUI exporter: {len(cases)} examples passed.")
