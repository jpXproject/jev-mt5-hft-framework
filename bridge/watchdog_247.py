"""
24/7 Sentinel Watchdog & Process Supervisor
Owner: jpXCode Pro
Keeps bridge_server.py and MT5 terminal monitoring running permanently.
"""

import time
import subprocess
import requests
import sys
import os

BRIDGE_SCRIPT = os.path.join(os.path.dirname(__file__), "bridge_server.py")
HEALTH_URL = "http://127.0.0.1:8765/health"

def is_bridge_healthy():
    try:
        r = requests.get(HEALTH_URL, timeout=2.0)
        return r.status_code == 200
    except Exception:
        return False

def run_watchdog():
    print("[WATCHDOG_247] Sentinel Watchdog Daemon Active")
    process = None
    while True:
        try:
            if not is_bridge_healthy():
                print("[WATCHDOG_247] Bridge server unreachable. Starting bridge_server.py...")
                if process is not None:
                    try:
                        process.terminate()
                    except Exception:
                        pass
                process = subprocess.Popen([sys.executable, BRIDGE_SCRIPT], cwd=os.path.dirname(__file__))
                time.sleep(3.0)
            else:
                pass
        except Exception as e:
            print(f"[WATCHDOG_247] Error: {e}")
        time.sleep(5.0)

if __name__ == "__main__":
    run_watchdog()
