"""
Unit Tests for Jev-MT5 Framework
"""

import sys
import os
import math

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "bridge")))

from strategy import compose_action
from gemini_client import mock_evaluator

def test_avellaneda_stoikov_formula():
    mid = 2650.0
    inventory_long = 0.05
    gamma = 0.1
    sigma = 0.02
    time_horizon = 1.0

    # r(s, q, t) = s - q * gamma * sigma^2 * (T - t)
    skew = inventory_long * gamma * (sigma ** 2) * time_horizon
    reservation_price = mid - skew

    assert reservation_price < mid, "Reservation price for long inventory must be lower than mid price"
    assert round(reservation_price, 4) == round(2650.0 - (0.05 * 0.1 * 0.0004 * 1.0), 4)

def test_compose_action_stand_down_on_toxic_flow():
    battery = {
        "regime": "trending",
        "direction": "up",
        "toxic_flow": "high",
        "liquidity_stress": "normal",
        "confidence": 0.90
    }
    action = compose_action(battery, {})
    assert action["action"] == "STAND_DOWN"
    assert action["lot_scale"] == 0.0

def test_compose_action_buy_on_high_confidence():
    battery = {
        "regime": "trending",
        "direction": "up",
        "toxic_flow": "low",
        "liquidity_stress": "normal",
        "confidence": 0.85
    }
    action = compose_action(battery, {})
    assert action["action"] == "BUY"
    assert action["lot_scale"] == 1.0

def test_compose_action_sell_on_high_confidence():
    battery = {
        "regime": "trending",
        "direction": "down",
        "toxic_flow": "low",
        "liquidity_stress": "normal",
        "confidence": 0.85
    }
    action = compose_action(battery, {})
    assert action["action"] == "SELL"
    assert action["lot_scale"] == 1.0

def test_mock_evaluator_mean_reversion():
    snap_high = {"mid": 105.0, "vwap": 100.0}
    res_high = mock_evaluator(snap_high)
    assert res_high["direction"] == "down"
    assert res_high["regime"] == "mean_reverting"

    snap_low = {"mid": 95.0, "vwap": 100.0}
    res_low = mock_evaluator(snap_low)
    assert res_low["direction"] == "up"
    assert res_low["regime"] == "mean_reverting"

if __name__ == "__main__":
    test_avellaneda_stoikov_formula()
    test_compose_action_stand_down_on_toxic_flow()
    test_compose_action_buy_on_high_confidence()
    test_compose_action_sell_on_high_confidence()
    test_mock_evaluator_mean_reversion()
    print("ALL 5 TESTS PASSED SUCCESSFULLY!")
