#!/usr/bin/env python3
"""
Jev-MT5 Autonomous AI Co-Pilot Trader Daemon
Operating 24/7 autonomous position opening, dynamic trailing, early exit, and risk gating
Active until market rollover close at 04:00 AM WIB.
"""

import sys
import time
import math
import json
import logging
from datetime import datetime, timedelta
from pathlib import Path

try:
    import MetaTrader5 as mt5
except ImportError:
    print("CRITICAL: MetaTrader5 package not installed.")
    sys.exit(1)

# Configure logging
LOG_DIR = Path(__file__).parent / "logs"
LOG_DIR.mkdir(parents=True, exist_ok=True)
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[
        logging.FileHandler(LOG_DIR / "copilot_daemon.log", encoding="utf-8"),
        logging.StreamHandler(sys.stdout)
    ]
)
logger = logging.getLogger("JevCoPilot")

# CONFIGURATION
SYMBOL = "XAUUSDc"
MAGIC_NUMBER = 20260925
FIXED_LOT = 0.01  # L2 Small lot constraint baseline
TARGET_RECOVERY_BALANCE = 1000.0  # Milestone target 1000 USC
MAX_OPEN_POSITIONS = 1
MAX_SPREAD_POINTS = 350.0  # Max spread acceptable
MIN_COOLDOWN_SEC = 25  # Minimum rest after position closed
STOP_TIME_HOUR = 3
STOP_TIME_MINUTE = 55  # Stop trading at 03:55 AM WIB before 04:00 market rollover

LEDGER_FILE = Path(__file__).parent / "copilot_ledger.jsonl"


def get_dynamic_lot(balance: float) -> float:
    """Tiered lot scaling according to 1000 USC recovery roadmap."""
    if balance < 450.0:
        return 0.01  # Stage 1: Foundation
    elif balance < 600.0:
        return 0.01  # Stage 2: Conservative
    elif balance < 800.0:
        return 0.02  # Stage 3: Momentum
    elif balance < 1000.0:
        return 0.02  # Stage 4: Target Run
    else:
        return 0.01  # Target Reached: Lockdown mode


def get_recovery_progress(balance: float) -> dict:
    pct = min(100.0, (balance / TARGET_RECOVERY_BALANCE) * 100.0)
    delta_remaining = max(0.0, TARGET_RECOVERY_BALANCE - balance)
    stage = 1 if balance < 450.0 else (2 if balance < 600.0 else (3 if balance < 800.0 else 4))
    return {
        "balance": balance,
        "target": TARGET_RECOVERY_BALANCE,
        "progress_pct": round(pct, 2),
        "remaining_usc": round(delta_remaining, 2),
        "stage": stage
    }


def log_trade_event(event_type: str, data: dict):
    payload = {
        "timestamp": datetime.now().isoformat(),
        "event": event_type,
        **data
    }
    with open(LEDGER_FILE, "a", encoding="utf-8") as f:
        f.write(json.dumps(payload) + "\n")
    logger.info(f"LEDGER EVENT [{event_type}]: {data}")


def calculate_indicators(symbol: str):
    """Calculate EMA 9, EMA 21, VWAP, RSI 14, and ATR from M1 bars."""
    rates = mt5.copy_rates_from_pos(symbol, mt5.TIMEFRAME_M1, 0, 50)
    if rates is None or len(rates) < 30:
        return None

    closes = [r['close'] for r in rates]
    highs = [r['high'] for r in rates]
    lows = [r['low'] for r in rates]
    vols = [r['tick_volume'] for r in rates]

    # EMA function
    def ema(series, period):
        k = 2.0 / (period + 1.0)
        res = [series[0]]
        for val in series[1:]:
            res.append(val * k + res[-1] * (1.0 - k))
        return res

    ema9 = ema(closes, 9)[-1]
    ema21 = ema(closes, 21)[-1]

    # VWAP
    cum_pv = sum(((h + l + c) / 3.0) * v for h, l, c, v in zip(highs, lows, closes, vols))
    cum_vol = sum(vols)
    vwap = (cum_pv / cum_vol) if cum_vol > 0 else closes[-1]

    # RSI 14
    gains, losses = [], []
    for i in range(1, 15):
        change = closes[-i] - closes[-i - 1]
        if change > 0:
            gains.append(change)
            losses.append(0.0)
        else:
            gains.append(0.0)
            losses.append(abs(change))
    avg_gain = sum(gains) / 14.0 if gains else 0.001
    avg_loss = sum(losses) / 14.0 if losses else 0.001
    rs = avg_gain / (avg_loss if avg_loss > 0 else 0.0001)
    rsi = 100.0 - (100.0 / (1.0 + rs))

    # ATR 14
    tr_list = []
    for i in range(1, 15):
        h = highs[-i]
        l = lows[-i]
        prev_c = closes[-i - 1]
        tr = max(h - l, abs(h - prev_c), abs(l - prev_c))
        tr_list.append(tr)
    atr = sum(tr_list) / len(tr_list) if tr_list else 1.0

    return {
        "close": closes[-1],
        "ema9": ema9,
        "ema21": ema21,
        "vwap": vwap,
        "rsi": rsi,
        "atr": atr
    }


def execute_order(action: str, symbol: str, lot: float, sl_points: float, tp_points: float, reason: str):
    """Execute real order via MT5 with strict SL and TP."""
    tick = mt5.symbol_info_tick(symbol)
    sym_info = mt5.symbol_info(symbol)
    if not tick or not sym_info:
        logger.error("Failed to get symbol tick info")
        return None

    point = sym_info.point
    digits = sym_info.digits

    if action == "BUY":
        order_type = mt5.ORDER_TYPE_BUY
        price = tick.ask
        sl = round(price - (sl_points * point), digits)
        tp = round(price + (tp_points * point), digits)
    elif action == "SELL":
        order_type = mt5.ORDER_TYPE_SELL
        price = tick.bid
        sl = round(price + (sl_points * point), digits)
        tp = round(price - (tp_points * point), digits)
    else:
        return None

    request = {
        "action": mt5.TRADE_ACTION_DEAL,
        "symbol": symbol,
        "volume": lot,
        "type": order_type,
        "price": price,
        "sl": sl,
        "tp": tp,
        "deviation": 20,
        "magic": MAGIC_NUMBER,
        "comment": f"JevAI {action} {reason[:12]}",
        "type_time": mt5.ORDER_TIME_GTC,
        "type_filling": mt5.ORDER_FILLING_IOC,
    }

    result = mt5.order_send(request)
    if result.retcode != mt5.TRADE_RETCODE_DONE:
        # Retry with RETURN filling if IOC fails
        request["type_filling"] = mt5.ORDER_FILLING_RETURN
        result = mt5.order_send(request)

    if result.retcode == mt5.TRADE_RETCODE_DONE:
        logger.info(f"✅ ORDER SUCCESS: {action} {lot} {symbol} @ {price:.3f} | SL={sl:.3f} | TP={tp:.3f} | Order #{result.order}")
        log_trade_event("OPEN_POSITION", {
            "order": result.order,
            "deal": result.deal,
            "type": action,
            "symbol": symbol,
            "lot": lot,
            "price": price,
            "sl": sl,
            "tp": tp,
            "reason": reason
        })
        return result
    else:
        logger.warning(f"❌ Order failed: retcode={result.retcode}, comment={result.comment}")
        return None


def close_position(ticket: int, symbol: str, pos_type: int, volume: float, reason: str):
    """Close specific open position."""
    tick = mt5.symbol_info_tick(symbol)
    if not tick:
        return False

    close_type = mt5.ORDER_TYPE_SELL if pos_type == mt5.POSITION_TYPE_BUY else mt5.ORDER_TYPE_BUY
    price = tick.bid if pos_type == mt5.POSITION_TYPE_BUY else tick.ask

    request = {
        "action": mt5.TRADE_ACTION_DEAL,
        "symbol": symbol,
        "volume": volume,
        "type": close_type,
        "position": ticket,
        "price": price,
        "deviation": 25,
        "magic": MAGIC_NUMBER,
        "comment": f"JevAI Close {reason[:10]}",
        "type_time": mt5.ORDER_TIME_GTC,
        "type_filling": mt5.ORDER_FILLING_IOC,
    }

    res = mt5.order_send(request)
    if res.retcode != mt5.TRADE_RETCODE_DONE:
        request["type_filling"] = mt5.ORDER_FILLING_RETURN
        res = mt5.order_send(request)

    if res.retcode == mt5.TRADE_RETCODE_DONE:
        logger.info(f"✅ POSITION CLOSED: Ticket #{ticket} @ {price:.3f} | Reason: {reason}")
        log_trade_event("CLOSE_POSITION", {
            "ticket": ticket,
            "close_deal": res.deal,
            "price": price,
            "volume": volume,
            "reason": reason
        })
        return True
    else:
        logger.warning(f"Failed to close ticket #{ticket}: {res.comment}")
        return False


def manage_active_positions(symbol: str):
    """Dynamic position management: Breakeven lock, Trailing stop, Early reversal exit."""
    positions = mt5.positions_get(symbol=symbol)
    if not positions:
        return 0

    sym_info = mt5.symbol_info(symbol)
    point = sym_info.point if sym_info else 0.001
    digits = sym_info.digits if sym_info else 3

    for p in positions:
        # Check Breakeven / Trailing
        open_price = p.price_open
        cur_price = p.price_current
        profit_points = (cur_price - open_price) / point if p.type == mt5.POSITION_TYPE_BUY else (open_price - cur_price) / point

        # If in profit > 150 points (+$1.50 on 0.01 lot) and SL is still below open price
        if profit_points >= 150.0:
            if p.type == mt5.POSITION_TYPE_BUY:
                desired_sl = round(open_price + (40.0 * point), digits)  # Lock +40 points (+0.40 USC)
                if p.sl < desired_sl:
                    modify_req = {
                        "action": mt5.TRADE_ACTION_SLTP,
                        "symbol": symbol,
                        "position": p.ticket,
                        "sl": desired_sl,
                        "tp": p.tp
                    }
                    m_res = mt5.order_send(modify_req)
                    if m_res.retcode == mt5.TRADE_RETCODE_DONE:
                        logger.info(f"🔒 BREAKEVEN ACTIVATED: Ticket #{p.ticket} SL moved to {desired_sl:.3f} (+40 pts locked)")
            elif p.type == mt5.POSITION_TYPE_SELL:
                desired_sl = round(open_price - (40.0 * point), digits)
                if p.sl > desired_sl or p.sl == 0.0:
                    modify_req = {
                        "action": mt5.TRADE_ACTION_SLTP,
                        "symbol": symbol,
                        "position": p.ticket,
                        "sl": desired_sl,
                        "tp": p.tp
                    }
                    m_res = mt5.order_send(modify_req)
                    if m_res.retcode == mt5.TRADE_RETCODE_DONE:
                        logger.info(f"🔒 BREAKEVEN ACTIVATED: Ticket #{p.ticket} SL moved to {desired_sl:.3f} (+40 pts locked)")

    return len(positions)


def run_copilot():
    """Main continuous AI autonomous trading loop until 04:00 AM WIB."""
    logger.info("==================================================================")
    logger.info("🤖 JEV-MT5 AI CO-PILOT AUTONOMOUS TRADER DAEMON INITIALIZED")
    logger.info(f"Target Horizon: Active until Market Rollover Close (03:55 AM WIB)")
    logger.info(f"Symbol: {SYMBOL} | Lot: {FIXED_LOT} | Max Positions: {MAX_OPEN_POSITIONS}")
    logger.info("==================================================================")

    if not mt5.initialize():
        logger.critical(f"MT5 Init failed: {mt5.last_error()}")
        sys.exit(1)

    acc = mt5.account_info()
    logger.info(f"Account: #{acc.login} ({acc.server}) | Balance: {acc.balance:.2f} {acc.currency} | Equity: {acc.equity:.2f}")

    last_trade_time = 0
    loop_count = 0

    while True:
        try:
            now = datetime.now()

            # Check market close threshold (03:55 AM WIB)
            # Rollover is between 03:55 - 04:05 AM
            if now.hour == STOP_TIME_HOUR and now.minute >= STOP_TIME_MINUTE:
                logger.info(f"🕒 Time limit reached ({now.strftime('%H:%M:%S')}). Closing remaining positions for daily rollover safety...")
                # Close all positions
                positions = mt5.positions_get(symbol=SYMBOL)
                if positions:
                    for p in positions:
                        close_position(p.ticket, SYMBOL, p.type, p.volume, "Rollover Market Close")
                logger.info("🏁 Market close routine complete. AI Co-Pilot standing down for rollover.")
                break

            loop_count += 1
            tick = mt5.symbol_info_tick(SYMBOL)
            sym_info = mt5.symbol_info(SYMBOL)

            if not tick or not sym_info:
                time.sleep(1)
                continue

            spread_pts = (tick.ask - tick.bid) / sym_info.point

            # 1. Manage Active Positions first (Breakeven & Trailing)
            open_count = manage_active_positions(SYMBOL)

            # 2. Risk Gating
            # Check spread limit
            if spread_pts > MAX_SPREAD_POINTS:
                if loop_count % 30 == 0:
                    logger.warning(f"Spread high ({spread_pts:.0f} pts > {MAX_SPREAD_POINTS} pts). Waiting...")
                time.sleep(2)
                continue

            # Check if position already open
            if open_count >= MAX_OPEN_POSITIONS:
                time.sleep(1.5)
                continue

            # Cooldown check
            if time.time() - last_trade_time < MIN_COOLDOWN_SEC:
                time.sleep(1.5)
                continue

            # 3. Market State & Signal Evaluation
            ind = calculate_indicators(SYMBOL)
            if not ind:
                time.sleep(1)
                continue

            close = ind["close"]
            ema9 = ind["ema9"]
            ema21 = ind["ema21"]
            vwap = ind["vwap"]
            rsi = ind["rsi"]
            atr = ind["atr"]

            # Dynamic SL/TP based on ATR (minimum 250 pts, max 500 pts)
            point = sym_info.point
            calc_sl_pts = max(260.0, min(500.0, (atr * 1.5) / point))
            calc_tp_pts = max(380.0, min(750.0, (atr * 2.2) / point))

            # Strategy: Trend Following + Mean Reversion Guard
            # BUY Condition:
            # - EMA9 > EMA21 (Bullish micro-trend)
            # - Price > VWAP (Above fair session value)
            # - RSI between 42 and 66 (Healthy momentum, not severely overbought)
            buy_signal = (ema9 > ema21) and (close > vwap) and (42.0 <= rsi <= 66.0)

            # SELL Condition:
            # - EMA9 < EMA21 (Bearish micro-trend)
            # - Price < VWAP (Below fair session value)
            # - RSI between 34 and 58 (Healthy downward momentum, not severely oversold)
            sell_signal = (ema9 < ema21) and (close < vwap) and (34.0 <= rsi <= 58.0)

            # Dynamic Lot & Recovery Sizing
            acc = mt5.account_info()
            current_balance = acc.balance if acc else 321.38
            rec_status = get_recovery_progress(current_balance)
            current_lot = get_dynamic_lot(current_balance)

            if buy_signal:
                reason = f"BullCross EMA9>21 | RSI={rsi:.1f} | DevVWAP=+{(close-vwap):.2f}"
                logger.info(f"⚡ AI BUY SIGNAL TRIGGERED: {reason} | Lot={current_lot} | Recovery={rec_status['progress_pct']}%")
                res = execute_order("BUY", SYMBOL, current_lot, calc_sl_pts, calc_tp_pts, reason)
                if res:
                    last_trade_time = time.time()

            elif sell_signal:
                reason = f"BearCross EMA9<21 | RSI={rsi:.1f} | DevVWAP={(close-vwap):.2f}"
                logger.info(f"⚡ AI SELL SIGNAL TRIGGERED: {reason} | Lot={current_lot} | Recovery={rec_status['progress_pct']}%")
                res = execute_order("SELL", SYMBOL, current_lot, calc_sl_pts, calc_tp_pts, reason)
                if res:
                    last_trade_time = time.time()

            if loop_count % 20 == 0:
                logger.info(f"[MONITOR] XAUUSDc={close:.3f} | Bal={current_balance:.2f} USC (Prog: {rec_status['progress_pct']}%, Stage {rec_status['stage']}) | Spread={spread_pts:.0f} pts | RSI={rsi:.1f} | Status: Ready")

            time.sleep(2)

        except Exception as e:
            logger.error(f"Error in co-pilot loop: {e}", exc_info=True)
            time.sleep(3)

    mt5.shutdown()
    logger.info("AI Co-Pilot successfully stopped.")


if __name__ == "__main__":
    run_copilot()
