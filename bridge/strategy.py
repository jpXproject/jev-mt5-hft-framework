"""
Jev-MT5 Strategy Thresholds & Action Composer
Owner: jpXCode Pro
"""

class StrategyConfig:
    # Tunable thresholds for the 7 Battery Judgments
    MIN_CONFIDENCE = 0.70
    MAX_SPREAD_BPS = 25.0
    MAX_TOXIC_FLOW = "medium"  # 'high' triggers PULL_QUOTES
    DEFAULT_LOT_SCALING = 1.0


def compose_action(battery: dict, snapshot: dict) -> dict:
    """
    Turns the 7 Battery answers into actionable decisions for MT5.
    Returns: action (BUY, SELL, HOLD, PULL_QUOTES, STAND_DOWN)
    """
    regime = battery.get("regime", "chaotic")
    direction = battery.get("direction", "neutral").upper()
    toxic = battery.get("toxic_flow", "low")
    stress = battery.get("liquidity_stress", "normal")
    confidence = float(battery.get("confidence", 0.0))

    # Safety checks
    if toxic == "high" or stress == "severe":
        return {
            "action": "STAND_DOWN",
            "reason": f"Market stress ({stress}) or toxic flow ({toxic})",
            "lot_scale": 0.0,
            "direction": "NEUTRAL"
        }

    if confidence < StrategyConfig.MIN_CONFIDENCE:
        return {
            "action": "HOLD",
            "reason": f"Confidence {confidence:.2f} below threshold {StrategyConfig.MIN_CONFIDENCE}",
            "lot_scale": 0.5,
            "direction": "NEUTRAL"
        }

    if direction in ["UP", "BUY"]:
        return {
            "action": "BUY",
            "reason": f"Regime {regime} with positive momentum",
            "lot_scale": 1.0,
            "direction": "UP"
        }
    elif direction in ["DOWN", "SELL"]:
        return {
            "action": "SELL",
            "reason": f"Regime {regime} with negative momentum",
            "lot_scale": 1.0,
            "direction": "DOWN"
        }

    return {
        "action": "HOLD",
        "reason": "Neutral market bias",
        "lot_scale": 0.0,
        "direction": "NEUTRAL"
    }
