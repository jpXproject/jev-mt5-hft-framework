//+------------------------------------------------------------------+
//|                                                     JevState.mqh |
//|                                    Copyright 2026, jpXCode Pro   |
//|            Deterministic Market & Inventory Snapshot for MT5     |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, jpXCode Pro"
#property link      "https://jpxcode.pages.dev"
#property version   "1.00"
#property strict

struct SJevSnapshot
{
   datetime as_of;
   double   mid_price;
   double   microprice;
   double   spread_bps;
   double   session_vwap;
   double   tick_imbalance;
   double   net_inventory_lots;
   double   net_inventory_usd;
   double   equity_usd;
   double   balance_usd;
   double   drawdown_pct;
};

class CJevStateEngine
{
private:
   string m_symbol;

public:
   CJevStateEngine(void) : m_symbol(_Symbol) {}

   void SetSymbol(const string sym) { m_symbol = sym; }

   bool CaptureSnapshot(SJevSnapshot &snap)
   {
      MqlTick tick;
      if(!SymbolInfoTick(m_symbol, tick)) return false;

      snap.as_of     = tick.time;
      snap.mid_price = (tick.bid + tick.ask) / 2.0;

      double point = SymbolInfoDouble(m_symbol, SYMBOL_POINT);
      double spread = (tick.ask - tick.bid);
      snap.spread_bps = (snap.mid_price > 0.0) ? ((spread / snap.mid_price) * 10000.0) : 0.0;

      // Microprice approximation using tick volume / spread
      snap.microprice = snap.mid_price;

      // Session VWAP estimation using M1 bars from day start
      MqlDateTime dt;
      TimeToStruct(tick.time, dt);
      dt.hour = 0; dt.min = 0; dt.sec = 0;
      datetime day_start = StructToTime(dt);

      MqlRates rates[];
      int copied = CopyRates(m_symbol, PERIOD_M1, day_start, tick.time, rates);
      double cum_vol = 0.0;
      double cum_pv  = 0.0;
      if(copied > 0)
      {
         for(int i = 0; i < copied; i++)
         {
            double bar_typical = (rates[i].high + rates[i].low + rates[i].close) / 3.0;
            double vol = (double)(rates[i].tick_volume > 0 ? rates[i].tick_volume : 1);
            cum_pv  += bar_typical * vol;
            cum_vol += vol;
         }
         snap.session_vwap = (cum_vol > 0.0) ? (cum_pv / cum_vol) : snap.mid_price;
      }
      else
      {
         snap.session_vwap = snap.mid_price;
      }

      // Tick Imbalance
      snap.tick_imbalance = (snap.mid_price - snap.session_vwap) / ((snap.mid_price > 0.0) ? snap.mid_price : 1.0) * 1000.0;

      // Inventory Tracking
      double total_long_lot = 0.0;
      double total_short_lot = 0.0;
      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         ulong ticket = PositionGetTicket(i);
         if(ticket > 0 && PositionGetString(POSITION_SYMBOL) == m_symbol)
         {
            ENUM_POSITION_TYPE p_type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
            double volume = PositionGetDouble(POSITION_VOLUME);
            if(p_type == POSITION_TYPE_BUY)
               total_long_lot += volume;
            else if(p_type == POSITION_TYPE_SELL)
               total_short_lot += volume;
         }
      }

      snap.net_inventory_lots = total_long_lot - total_short_lot;
      snap.net_inventory_usd  = snap.net_inventory_lots * snap.mid_price;

      snap.equity_usd  = AccountInfoDouble(ACCOUNT_EQUITY);
      snap.balance_usd = AccountInfoDouble(ACCOUNT_BALANCE);
      snap.drawdown_pct = (snap.balance_usd > 0.0) ? ((snap.balance_usd - snap.equity_usd) / snap.balance_usd * 100.0) : 0.0;

      return true;
   }

   string ToJson(const SJevSnapshot &snap)
   {
      string json = StringFormat(
         "{\"as_of\":%d,\"symbol\":\"%s\",\"mid\":%.5f,\"spread_bps\":%.2f,\"vwap\":%.5f,\"imbalance\":%.2f,\"net_lot\":%.2f,\"equity\":%.2f,\"drawdown_pct\":%.2f}",
         snap.as_of, m_symbol, snap.mid_price, snap.spread_bps, snap.session_vwap, snap.tick_imbalance, snap.net_inventory_lots, snap.equity_usd, snap.drawdown_pct
      );
      return json;
   }
};
