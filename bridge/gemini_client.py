"""
Jev-MT5 Decision Client (Gemini 2.5/Flash / Fallback Mock Engine)
Owner: jpXCode Pro
"""

import os
import json
import time
import requests

BATTERY_PROMPT = """You are the high-speed probabilistic market judgment engine for a 24/7 algorithmic trading system.
Evaluate the following market snapshot:
{snapshot_json}

Answer the exact 7 questions in this JSON schema:
{{
  "regime": "trending" | "mean_reverting" | "chaotic",
  "direction": "up" | "down" | "neutral",
  "toxic_flow": "low" | "medium" | "high",
  "liquidity_stress": "normal" | "stressed" | "severe",
  "quote_environment": "favorable" | "hostile",
  "inventory_pressure": "balanced" | "leaning_long" | "leaning_short" | "extreme",
  "execution_health": "optimal" | "degrading",
  "confidence": 0.0 to 1.0
}}
Return ONLY valid JSON.
"""

def mock_evaluator(snapshot: dict) -> dict:
    """Deterministic local evaluator when cloud AI is offline or key not provided"""
    mid = snapshot.get("mid", 0.0)
    vwap = snapshot.get("vwap", mid)
    diff = mid - vwap

    if diff > 1.5:
        return {
            "regime": "mean_reverting",
            "direction": "down",
            "toxic_flow": "low",
            "liquidity_stress": "normal",
            "quote_environment": "favorable",
            "inventory_pressure": "balanced",
            "execution_health": "optimal",
            "confidence": 0.82
        }
    elif diff < -1.5:
        return {
            "regime": "mean_reverting",
            "direction": "up",
            "toxic_flow": "low",
            "liquidity_stress": "normal",
            "quote_environment": "favorable",
            "inventory_pressure": "balanced",
            "execution_health": "optimal",
            "confidence": 0.82
        }

    return {
        "regime": "chaotic",
        "direction": "neutral",
        "toxic_flow": "low",
        "liquidity_stress": "normal",
        "quote_environment": "favorable",
        "inventory_pressure": "balanced",
        "execution_health": "optimal",
        "confidence": 0.50
    }


def evaluate_market_state(snapshot: dict) -> dict:
    api_key = os.getenv("GEMINI_API_KEY", "")
    if not api_key:
        return mock_evaluator(snapshot)

    url = f"https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key={api_key}"
    payload = {
        "contents": [{
            "parts": [{"text": BATTERY_PROMPT.format(snapshot_json=json.dumps(snapshot))}]
        }],
        "generationConfig": {
            "response_mime_type": "application/json"
        }
    }

    try:
        start_t = time.time()
        res = requests.post(url, json=payload, timeout=2.0)
        latency = (time.time() - start_t) * 1000.0
        if res.status_code == 200:
            data = res.json()
            text = data["candidates"][0]["content"]["parts"][0]["text"]
            result = json.loads(text)
            result["_latency_ms"] = latency
            result["_source"] = "gemini-flash"
            return result
    except Exception:
        pass

    fallback = mock_evaluator(snapshot)
    fallback["_source"] = "local-rules-fallback"
    return fallback
