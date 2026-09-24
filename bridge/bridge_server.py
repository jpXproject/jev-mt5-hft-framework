"""
FastAPI IPC Bridge Server for MT5 <-> Antigravity Jev Engine
Owner: jpXCode Pro
Runs on: http://127.0.0.1:8765
Web UI:  http://127.0.0.1:8765/dashboard/index.html
"""

import os
import time
import uvicorn
from fastapi import FastAPI
from fastapi.staticfiles import StaticFiles
from fastapi.responses import RedirectResponse
from pydantic import BaseModel
from typing import Optional

from gemini_client import evaluate_market_state
from strategy import compose_action

app = FastAPI(title="Jev-MT5 Sentinel Bridge", version="1.0.0")

# Static files mount
static_dir = os.path.join(os.path.dirname(__file__), "static")
if os.path.exists(static_dir):
    app.mount("/dashboard", StaticFiles(directory=static_dir, html=True), name="static")

# Shared telemetry cache
telemetry_state = {
    "status": "ONLINE",
    "timestamp": time.time(),
    "snapshot": {
        "symbol": "BTCUSD",
        "mid": 85820.50,
        "vwap": 85810.00,
        "spread_bps": 3.2,
        "net_lot": 0.02,
        "drawdown_pct": 0.40
    },
    "battery": {
        "regime": "mean_reverting",
        "direction": "up",
        "toxic_flow": "low",
        "liquidity_stress": "normal",
        "quote_environment": "favorable",
        "inventory_pressure": "balanced",
        "confidence": 0.86
    },
    "action": {"action": "BUY", "lot_scale": 1.0},
    "latency_ms": 240.0
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
    telemetry_state["latency_ms"] = latency_ms
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

if __name__ == "__main__":
    uvicorn.run(app, host="127.0.0.1", port=8765)
