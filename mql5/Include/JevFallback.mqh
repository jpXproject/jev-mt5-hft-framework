//+------------------------------------------------------------------+
//|                                                  JevFallback.mqh |
//|                                    Copyright 2026, jpXCode Pro   |
//|               5-Rung Fallback Ladder State Machine for MT5       |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, jpXCode Pro"
#property link      "https://jpxcode.pages.dev"
#property version   "1.00"
#property strict

enum ENUM_FALLBACK_STATE
{
   FALLBACK_RUN = 0,        // Healthy, low latency, high AI confidence
   FALLBACK_REDUCE,         // Moderate confidence / stress -> lot reduced by 50%
   FALLBACK_HOLD_LATE,      // Latency exceeded tick budget -> withhold execution
   FALLBACK_RULES_ONLY,     // AI Gateway offline -> purely local rule fallback
   FALLBACK_KILL            // Hard risk breach -> flatten all, emergency stop
};

class CJevFallbackLadder
{
private:
   ENUM_FALLBACK_STATE m_current_state;
   int                 m_consecutive_timeouts;

public:
   CJevFallbackLadder(void) : m_current_state(FALLBACK_RUN), m_consecutive_timeouts(0) {}

   ENUM_FALLBACK_STATE Evaluate(bool is_risk_breach, bool is_late, bool is_ai_online, double confidence)
   {
      // Rung 5: Hard limit breach -> KILL
      if(is_risk_breach)
      {
         m_current_state = FALLBACK_KILL;
         return m_current_state;
      }

      // Rung 4: AI unreachable / offline -> RULES_ONLY
      if(!is_ai_online)
      {
         m_consecutive_timeouts++;
         m_current_state = FALLBACK_RULES_ONLY;
         return m_current_state;
      }

      // Rung 3: Late response -> HOLD_LATE
      if(is_late)
      {
         m_consecutive_timeouts++;
         m_current_state = FALLBACK_HOLD_LATE;
         return m_current_state;
      }

      // Reset timeout counter on good response
      m_consecutive_timeouts = 0;

      // Rung 2: Low confidence (< 0.70) -> REDUCE
      if(confidence < 0.70)
      {
         m_current_state = FALLBACK_REDUCE;
         return m_current_state;
      }

      // Rung 1: Healthy + High confidence -> RUN
      m_current_state = FALLBACK_RUN;
      return m_current_state;
   }

   string StateToString(void) const
   {
      switch(m_current_state)
      {
         case FALLBACK_RUN:        return "RUN (Optimal)";
         case FALLBACK_REDUCE:     return "REDUCE (50% Size)";
         case FALLBACK_HOLD_LATE:  return "HOLD_LATE (Withheld)";
         case FALLBACK_RULES_ONLY: return "RULES_ONLY (Deterministic)";
         case FALLBACK_KILL:       return "KILL (Emergency Flatten)";
         default:                  return "UNKNOWN";
      }
   }

   ENUM_FALLBACK_STATE GetCurrentState(void) const { return m_current_state; }
};
