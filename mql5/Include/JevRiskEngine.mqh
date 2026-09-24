//+------------------------------------------------------------------+
//|                                                JevRiskEngine.mqh |
//|                                    Copyright 2026, jpXCode Pro   |
//|                    9 Hard Risk Veto Limits (Core Execution Gate) |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, jpXCode Pro"
#property link      "https://jpxcode.pages.dev"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>

enum ENUM_VETO_REASON
{
   VETO_NONE = 0,
   VETO_MAX_DRAWDOWN,
   VETO_DAILY_LOSS,
   VETO_MAX_LOT,
   VETO_EXCESSIVE_SPREAD,
   VETO_LOW_MARGIN_LEVEL,
   VETO_TICK_DEADLINE_EXPIRED,
   VETO_SLIPPAGE_EXCEEDED,
   VETO_MISSING_STOPLOSS,
   VETO_EMERGENCY_FLATTEN
};

class CJevRiskEngine
{
private:
   double            m_max_drawdown_pct;
   double            m_max_daily_loss_usd;
   double            m_max_lot_cap;
   double            m_max_spread_pts;
   double            m_min_margin_level;
   int               m_max_latency_ms;
   double            m_initial_day_balance;
   datetime          m_last_day_stamp;
   CTrade            m_trade;

public:
   CJevRiskEngine(void) :
      m_max_drawdown_pct(3.0),
      m_max_daily_loss_usd(50.0),
      m_max_lot_cap(0.10),
      m_max_spread_pts(50.0),
      m_min_margin_level(200.0),
      m_max_latency_ms(800),
      m_initial_day_balance(0.0),
      m_last_day_stamp(0)
   {
   }

   void Init(double max_dd_pct, double max_daily_usd, double max_lot, double max_spread, double min_margin, int max_latency)
   {
      m_max_drawdown_pct   = max_dd_pct;
      m_max_daily_loss_usd = max_daily_usd;
      m_max_lot_cap        = max_lot;
      m_max_spread_pts     = max_spread;
      m_min_margin_level   = min_margin;
      m_max_latency_ms     = max_latency;
      m_initial_day_balance= AccountInfoDouble(ACCOUNT_BALANCE);
      m_last_day_stamp     = TimeCurrent();
      m_trade.SetExpertMagicNumber(20260924);
   }

   void CheckDailyReset(void)
   {
      datetime now = TimeCurrent();
      MqlDateTime dt_now, dt_last;
      TimeToStruct(now, dt_now);
      TimeToStruct(m_last_day_stamp, dt_last);

      if(dt_now.day != dt_last.day)
      {
         m_initial_day_balance = AccountInfoDouble(ACCOUNT_BALANCE);
         m_last_day_stamp      = now;
         PrintFormat("[RISK_ENGINE] Daily balance reset to: $%.2f", m_initial_day_balance);
      }
   }

   ENUM_VETO_REASON EvaluateOrderVeto(const string symbol, const ENUM_ORDER_TYPE order_type, const double lots, const double sl_price, const int response_latency_ms)
   {
      CheckDailyReset();

      // 1. Tick / Network Deadline Veto
      if(response_latency_ms > m_max_latency_ms)
      {
         PrintFormat("[RISK VETO] Latency %d ms melebihi batas %d ms (HOLD_LATE)", response_latency_ms, m_max_latency_ms);
         return VETO_TICK_DEADLINE_EXPIRED;
      }

      // 2. Stop Loss Enforcement
      if(sl_price <= 0.0)
      {
         Print("[RISK VETO] Hard Stop Loss wajib terisi!");
         return VETO_MISSING_STOPLOSS;
      }

      // 3. Max Spread Check
      long spread_pts = SymbolInfoInteger(symbol, SYMBOL_SPREAD);
      if(spread_pts > (long)m_max_spread_pts)
      {
         PrintFormat("[RISK VETO] Spread %d pts > max %d pts", spread_pts, (long)m_max_spread_pts);
         return VETO_EXCESSIVE_SPREAD;
      }

      // 4. Margin Level Veto
      double margin_level = AccountInfoDouble(ACCOUNT_MARGIN_LEVEL);
      if(margin_level > 0.0 && margin_level < m_min_margin_level)
      {
         PrintFormat("[RISK VETO] Margin level %.1f%% < min %.1f%%", margin_level, m_min_margin_level);
         return VETO_LOW_MARGIN_LEVEL;
      }

      // 5. Max Lot Cap
      if(lots > m_max_lot_cap)
      {
         PrintFormat("[RISK VETO] Order lot %.2f melebihi cap %.2f", lots, m_max_lot_cap);
         return VETO_MAX_LOT;
      }

      // 6. Max Drawdown Percent
      double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
      double balance = AccountInfoDouble(ACCOUNT_BALANCE);
      double dd_pct  = (balance > 0.0) ? ((balance - equity) / balance * 100.0) : 0.0;
      if(dd_pct >= m_max_drawdown_pct)
      {
         PrintFormat("[RISK VETO] Floating DD %.2f%% >= Max %.2f%%", dd_pct, m_max_drawdown_pct);
         return VETO_MAX_DRAWDOWN;
      }

      // 7. Daily Loss Cap
      double daily_pl = equity - m_initial_day_balance;
      if(daily_pl <= -m_max_daily_loss_usd)
      {
         PrintFormat("[RISK VETO] Daily loss $%.2f <= Max -$%.2f", daily_pl, m_max_daily_loss_usd);
         return VETO_DAILY_LOSS;
      }

      return VETO_NONE;
   }

   bool FlattenAll(const string symbol)
   {
      PrintFormat("[RISK EMERGENCY] Flattening all positions for %s", symbol);
      bool all_closed = true;
      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         ulong ticket = PositionGetTicket(i);
         if(ticket > 0 && PositionGetString(POSITION_SYMBOL) == symbol)
         {
            if(!m_trade.PositionClose(ticket))
            {
               all_closed = false;
               PrintFormat("[RISK ERROR] Failed to close position #%d: %s", ticket, m_trade.ResultComment());
            }
         }
      }
      return all_closed;
   }
};
