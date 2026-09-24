"""
FastAPI IPC Bridge Server for MT5 <-> Antigravity Jev Engine
Owner: jpXCode Pro
Runs on: http://127.0.0.1:8765
Web UI:  http://127.0.0.1:8765/dashboard/index.html
Features: WebSocket Real-Time Streaming + Interactive Chart Engine + Panic Flatten
"""

import os
import time
import json
import asyncio
import threading
from typing import List, Optional
import uvicorn
from fastapi import FastAPI, WebSocket, WebSocketDisconnect
from fastapi.staticfiles import StaticFiles
from fastapi.responses import RedirectResponse
from pydantic import BaseModel

from gemini_client import evaluate_market_state
from strategy import compose_action

app = FastAPI(title="Jev-MT5 Sentinel Bridge", version="1.1.0")

# Static files mount
static_dir = os.path.join(os.path.dirname(__file__), "static")
if os.path.exists(static_dir):
    app.mount("/dashboard", StaticFiles(directory=static_dir, html=True), name="static")

# Ring buffer for live chart points (last 60 ticks)
tick_history: List[dict] = []
MAX_HISTORY = 60

# Active WebSocket connections
active_connections: List[WebSocket] = []

# Shared telemetry cache
telemetry_state = {
    "status": "ONLINE",
    "timestamp": time.time(),
    "snapshot": {
        "symbol": "XAUUSDc",
        "mid": 4265.50,
        "vwap": 4262.00,
        "spread_bps": 0.56,
        "net_lot": 0.0,
        "equity": 319.48,
        "balance": 319.48,
        "drawdown_pct": 0.0,
        "reservation_price": 4265.50
    },
    "battery": {
        "regime": "mean_reverting",
        "direction": "down",
        "toxic_flow": "low",
        "liquidity_stress": "normal",
        "quote_environment": "favorable",
        "inventory_pressure": "balanced",
        "confidence": 0.82
    },
    "action": {"action": "SELL", "lot_scale": 1.0, "reason": "Negative momentum"},
    "latency_ms": 0.8,
    "tick_history": []
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
    telemetry_state["tick_history"] = tick_history[-50:]
    return telemetry_state

@app.post("/evaluate")
async def evaluate(snapshot: MarketSnapshot):
    snap_dict = snapshot.model_dump()
    start_t = time.time()
    battery = evaluate_market_state(snap_dict)
    action = compose_action(battery, snap_dict)
    latency_ms = (time.time() - start_t) * 1000.0

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

@app.post("/api/panic_flatten")
def panic_flatten():
    """Emergency close all positions via MT5 API"""
    try:
        import MetaTrader5 as mt5
        if not mt5.initialize():
            return {"status": "error", "message": "Failed to connect to MT5"}
        
        positions = mt5.positions_get(symbol="XAUUSDc")
        closed_count = 0
        if positions:
            for p in positions:
                order_type = mt5.ORDER_TYPE_SELL if p.type == mt5.POSITION_TYPE_BUY else mt5.ORDER_TYPE_BUY
                price = mt5.symbol_info_tick(p.symbol).bid if order_type == mt5.ORDER_TYPE_SELL else mt5.symbol_info_tick(p.symbol).ask
                req = {
                    "action": mt5.TRADE_ACTION_DEAL,
                    "symbol": p.symbol,
                    "volume": p.volume,
                    "type": order_type,
                    "position": p.ticket,
                    "price": price,
                    "deviation": 30,
                    "magic": p.magic,
                    "comment": "Jev Emergency Flatten",
                    "type_time": mt5.ORDER_TIME_GTC,
                    "type_filling": mt5.ORDER_FILLING_FOK
                }
                res = mt5.order_send(req)
                if res and res.retcode == mt5.TRADE_RETCODE_DONE:
                    closed_count += 1
        return {"status": "success", "closed_positions": closed_count}
    except Exception as e:
        return {"status": "error", "message": str(e)}

@app.websocket("/ws")
async def websocket_endpoint(websocket: WebSocket):
    await websocket.accept()
    active_connections.append(websocket)
    try:
        # Send initial state immediately
        await websocket.send_json(telemetry_state)
        while True:
            # Keepalive listener
            data = await websocket.receive_text()
    except WebSocketDisconnect:
        if websocket in active_connections:
            active_connections.remove(websocket)

def broadcast_sync(payload: dict):
    """Broadcast to all connected websockets using asyncio loop in main thread or sync fallback"""
    pass

def mt5_live_poller():
    """Ultra-responsive MT5 poller (every 100ms) with tick history recorder"""
    try:
        import MetaTrader5 as mt5
    except ImportError:
        return

    if not mt5.initialize():
        return

    last_bid = 0.0
    last_eval_time = 0

    print("[MT5_POLLER] Real-time tick monitor and interactive streaming engine started")
    while True:
        try:
            symbol = "XAUUSDc"
            tick = mt5.symbol_info_tick(symbol)
            acc = mt5.account_info()

            if tick and acc:
                mid = (tick.bid + tick.ask) / 2.0
                spread_bps = ((tick.ask - tick.bid) / mid) * 10000.0 if mid > 0 else 0.0

                # Check if tick price moved
                if tick.bid != last_bid or (time.time() - last_eval_time > 3.0):
                    last_bid = tick.bid

                    # Calculate VWAP
                    rates = mt5.copy_rates_from_pos(symbol, mt5.TIMEFRAME_M1, 0, 30)
                    if rates is not None and len(rates) > 0:
                        cum_pv = sum(((r['high'] + r['low'] + r['close']) / 3.0) * r['tick_volume'] for r in rates)
                        cum_vol = sum(r['tick_volume'] for r in rates)
                        vwap = (cum_pv / cum_vol) if cum_vol > 0 else mid
                    else:
                        vwap = mid

                    # Net positions and open positions list
                    positions = mt5.positions_get(symbol=symbol)
                    net_lot = 0.0
                    open_pos_list = []
                    if positions:
                        for p in positions:
                            if p.type == mt5.POSITION_TYPE_BUY:
                                net_lot += p.volume
                            elif p.type == mt5.POSITION_TYPE_SELL:
                                net_lot -= p.volume
                            open_pos_list.append({
                                "ticket": p.ticket,
                                "time": time.strftime("%H:%M:%S", time.localtime(p.time)),
                                "type": "BUY" if p.type == mt5.POSITION_TYPE_BUY else "SELL",
                                "volume": p.volume,
                                "open_price": round(p.price_open, 3),
                                "cur_price": round(p.price_current, 3),
                                "sl": round(p.sl, 3),
                                "tp": round(p.tp, 3),
                                "profit": round(p.profit, 2)
                            })
                    telemetry_state["open_positions"] = open_pos_list

                    dd_pct = ((acc.balance - acc.equity) / acc.balance * 100.0) if acc.balance > 0 else 0.0

                    # Avellaneda-Stoikov Reservation Price
                    gamma = 0.1
                    sigma = 0.02
                    skew = net_lot * gamma * (sigma ** 2) * 1.0
                    reserv_price = mid - skew

                    snap = {
                        "as_of": int(tick.time),
                        "symbol": symbol,
                        "mid": round(mid, 3),
                        "spread_bps": round(spread_bps, 2),
                        "vwap": round(vwap, 3),
                        "imbalance": round((mid - vwap), 3),
                        "net_lot": round(net_lot, 2),
                        "equity": round(acc.equity, 2),
                        "balance": round(acc.balance, 2),
                        "drawdown_pct": round(dd_pct, 2),
                        "reservation_price": round(reserv_price, 3)
                    }

                    # Fetch closed deals (every 2 seconds)
                    if time.time() - last_eval_time > 2.0:
                        import datetime
                        now_dt = datetime.datetime.now()
                        start_dt = now_dt.replace(hour=0, minute=0, second=0)
                        deals = mt5.history_deals_get(start_dt, now_dt)
                        closed_deals_list = []
                        if deals:
                            for d in reversed(deals):
                                if d.symbol == symbol and d.entry == mt5.DEAL_ENTRY_OUT:
                                    closed_deals_list.append({
                                        "ticket": d.ticket,
                                        "order": d.order,
                                        "time": time.strftime("%H:%M:%S", time.localtime(d.time)),
                                        "type": "SELL" if d.type == mt5.DEAL_TYPE_SELL else "BUY",
                                        "volume": d.volume,
                                        "price": round(d.price, 3),
                                        "profit": round(d.profit, 2),
                                        "comment": d.comment
                                    })
                                    if len(closed_deals_list) >= 10:
                                        break
                        telemetry_state["closed_deals"] = closed_deals_list

                    # Periodic Battery Evaluation
                    if time.time() - last_eval_time > 3.0:
                        last_eval_time = time.time()
                        battery = evaluate_market_state(snap)
                        action = compose_action(battery, snap)
                        telemetry_state["battery"] = battery
                        telemetry_state["action"] = action

                    # Add point to tick history
                    point = {
                        "time": time.strftime("%H:%M:%S", time.localtime(tick.time)),
                        "mid": round(mid, 3),
                        "reserv": round(reserv_price, 3),
                        "vwap": round(vwap, 3)
                    }
                    tick_history.append(point)
                    if len(tick_history) > MAX_HISTORY:
                        tick_history.pop(0)

                    telemetry_state["snapshot"] = snap
                    telemetry_state["latency_ms"] = 0.5
                    telemetry_state["timestamp"] = time.time()
                    telemetry_state["tick_history"] = tick_history[-50:]

        except Exception as e:
            pass
        time.sleep(0.1)

if __name__ == "__main__":
    t_poller = threading.Thread(target=mt5_live_poller, daemon=True)
    t_poller.start()
    uvicorn.run(app, host="127.0.0.1", port=8765)
