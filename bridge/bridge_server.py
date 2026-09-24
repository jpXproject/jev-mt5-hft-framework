"""
FastAPI IPC Bridge Server for MT5 <-> Antigravity Jev Engine
Owner: jpXCode Pro
Runs on: http://127.0.0.1:8765
Web UI:  http://127.0.0.1:8765/dashboard/index.html
Features: Dual-Transport (FastAPI REST WebRequest + MT5 Common Files IPC)
"""

import os
import time
import json
import threading
import uvicorn
from fastapi import FastAPI
from fastapi.staticfiles import StaticFiles
from fastapi.responses import RedirectResponse
from pydantic import BaseModel
from typing import Optional

from gemini_client import evaluate_market_state
from strategy import compose_action

app = FastAPI(title="Jev-MT5 Sentinel Bridge", version="1.0.0")

# MT5 Common Files IPC path
COMMON_DIR = r"C:\Users\XCODE\AppData\Roaming\MetaQuotes\Terminal\Common\Files"
SNAPSHOT_FILE = os.path.join(COMMON_DIR, "jev_snapshot.json")
RESPONSE_FILE = os.path.join(COMMON_DIR, "jev_response.json")

# Static files mount
static_dir = os.path.join(os.path.dirname(__file__), "static")
if os.path.exists(static_dir):
    app.mount("/dashboard", StaticFiles(directory=static_dir, html=True), name="static")

# Shared telemetry cache
telemetry_state = {
    "status": "ONLINE",
    "timestamp": time.time(),
    "snapshot": {
        "symbol": "XAUUSDc",
        "mid": 2650.50,
        "vwap": 2649.00,
        "spread_bps": 2.5,
        "net_lot": 0.0,
        "drawdown_pct": 0.0
    },
    "battery": {
        "regime": "mean_reverting",
        "direction": "neutral",
        "toxic_flow": "low",
        "liquidity_stress": "normal",
        "quote_environment": "favorable",
        "inventory_pressure": "balanced",
        "confidence": 0.85
    },
    "action": {"action": "HOLD", "lot_scale": 0.0},
    "latency_ms": 2.5
}

class MarketSnapshot(BaseModel):
    as_of: int
    symbol: str
    mid: float
    spread_bps: float
    vwap: float
    imbalance: float
    net_lot: float
    equity: float
    drawdown_pct: float

@app.get("/")
def root():
    return RedirectResponse(url="/dashboard/index.html")

@app.get("/health")
def health():
    return {"status": "ok", "timestamp": time.time()}

@app.get("/api/telemetry")
def get_telemetry():
    return telemetry_state

@app.post("/evaluate")
async def evaluate(snapshot: MarketSnapshot):
    snap_dict = snapshot.model_dump()
    start_t = time.time()
    battery = evaluate_market_state(snap_dict)
    action = compose_action(battery, snap_dict)
    latency_ms = (time.time() - start_t) * 1000.0

    # Update cache
    telemetry_state["snapshot"] = snap_dict
    telemetry_state["battery"] = battery
    telemetry_state["action"] = action
    telemetry_state["latency_ms"] = round(latency_ms, 2)
    telemetry_state["timestamp"] = time.time()

    return {
        "status": "success",
        "symbol": snapshot.symbol,
        "latency_ms": round(latency_ms, 2),
        "battery": battery,
        "action": action,
        "direction": battery.get("direction", "neutral").upper(),
        "regime": battery.get("regime", "chaotic"),
        "confidence": battery.get("confidence", 0.50)
    }

def ipc_file_watcher():
    """Background worker for MT5 Common Files IPC transport"""
    last_mtime = 0
    print(f"[IPC_WORKER] Listening on MT5 Common directory: {COMMON_DIR}")
    while True:
        try:
            if os.path.exists(SNAPSHOT_FILE):
                mtime = os.path.getmtime(SNAPSHOT_FILE)
                if mtime > last_mtime:
                    last_mtime = mtime
                    start_t = time.time()
                    with open(SNAPSHOT_FILE, "r", encoding="utf-8") as f:
                        data = json.load(f)
                    
                    battery = evaluate_market_state(data)
                    action = compose_action(battery, data)
                    latency_ms = (time.time() - start_t) * 1000.0

                    resp = {
                        "status": "success",
                        "symbol": data.get("symbol", ""),
                        "latency_ms": round(latency_ms, 2),
                        "battery": battery,
                        "action": action,
                        "direction": battery.get("direction", "neutral").upper(),
                        "regime": battery.get("regime", "chaotic"),
                        "confidence": battery.get("confidence", 0.50)
                    }

                    # Write response atomically
                    temp_file = RESPONSE_FILE + ".tmp"
                    with open(temp_file, "w", encoding="utf-8") as f:
                        json.dump(resp, f)
                    os.replace(temp_file, RESPONSE_FILE)

                    # Update telemetry state
                    telemetry_state["snapshot"] = data
                    telemetry_state["battery"] = battery
                    telemetry_state["action"] = action
                    telemetry_state["latency_ms"] = round(latency_ms, 2)
                    telemetry_state["timestamp"] = time.time()
                    print(f"[IPC_MT5] Snapshot processed for {data.get('symbol')} in {latency_ms:.2f}ms | Action: {action.get('action')}")
        except Exception as e:
            pass
        time.sleep(0.05)

if __name__ == "__main__":
    t = threading.Thread(target=ipc_file_watcher, daemon=True)
    t.start()
    uvicorn.run(app, host="127.0.0.1", port=8765)
