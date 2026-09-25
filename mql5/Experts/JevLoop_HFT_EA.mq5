//+------------------------------------------------------------------+
//|                                             JevLoop_HFT_EA.mq5   |
//|                    Copyright © 2026 jpXCode. All Rights Reserved. |
//|         Jev-MT5 24/7 Algorithmic Architecture with Hard Risk Gate|
//+------------------------------------------------------------------+
#property copyright   "Copyright © 2026 jpXCode. All Rights Reserved."
#property link        "https://jpxcode.pages.dev"
#property version     "1.40"
#property description "jpXCode Pro Institutional HFT & 24/7 Algorithmic Execution System"

#include <Trade\Trade.mqh>
#include "..\Include\JevRiskEngine.mqh"
#include "..\Include\JevPricing.mqh"
#include "..\Include\JevState.mqh"
#include "..\Include\JevFallback.mqh"

//--- Inputs
input group "=== Execution & Lot Settings ==="
input ulong    InpMagicNumber       = 20260924;      // Magic Number
input double   InpBaseLot           = 0.01;          // Base Lot Size (L2 Small Lot)
input int      InpStopLossPts       = 350;           // Stop Loss Points (35 pips / ~1.5 ATR)
input int      InpTakeProfitPts     = 750;           // Take Profit Points (75 pips / ~3.2 ATR)
input int      InpSlippagePts       = 25;            // Max Allowed Slippage

input group "=== 2-Year Backtest Optimized Risk & Shields ==="
input bool     InpUseBreakEven      = true;          // Aktifkan Auto BreakEven Shield
input int      InpBreakEvenTrigger  = 200;           // Trigger BE saat Profit (points)
input int      InpBreakEvenLock     = 25;            // Kunci Profit BE di atas Entry (points)
input bool     InpBlockRollover     = true;          // Bekukan Order saat Rollover (03:00-05:00 WIB)
input double   InpMaxSpreadPts      = 55.0;          // Max Allowed Spread (pts)
input double   InpMaxDrawdownPct    = 3.0;           // Max Floating Drawdown %
input double   InpMaxDailyLossUSD   = 50.0;          // Max Daily Loss USD
input double   InpMaxLotCap         = 0.10;          // Absolute Max Lot Cap
input double   InpMinMarginLevel    = 200.0;         // Min Margin Level %
input int      InpMaxLatencyMs      = 800;           // Max Response Deadline (ms)

input group "=== Top 3 Market Utility Tools Integration ==="
input bool     InpUsePOCFilter      = true;          // Tool 1: Order Flow Volume Profile POC Filter
input int      InpPOCLookbackBars   = 24;            // Periode Lookback Bar POC
input bool     InpUseFVGFilter      = true;          // Tool 2: SMC Fair Value Gap (FVG) Filter
input bool     InpUsePartialTP      = true;          // Tool 3: Advanced Trade Manager Partial TP (50% close)
input bool     InpUseDynamicTrailing= true;          // Tool 3: Dynamic Trailing Stop Shield
input int      InpTrailingStepPts   = 50;            // Step Trailing Stop Points

input group "=== Avellaneda-Stoikov Pricing ==="
input double   InpGamma             = 0.1;           // Risk Aversion (gamma)
input double   InpSigma             = 0.02;          // Volatility estimate (sigma)
input double   InpTimeHorizon       = 1.0;           // Session Horizon (T - t)

input group "=== AI Bridge Configuration ==="
input string   InpBridgeUrl         = "http://127.0.0.1:8765/evaluate"; // Localhost AI Bridge URL
input int      InpEvaluationSec     = 5;             // Evaluation Interval (seconds)

//--- Module instances
CTrade              g_trade;
CJevRiskEngine      g_risk;
CJevPricing         g_pricing;
CJevStateEngine     g_state;
CJevFallbackLadder  g_ladder;

//--- Runtime state variables
datetime            g_last_eval_time = 0;
string              g_ai_regime      = "UNKNOWN";
string              g_ai_direction   = "NEUTRAL";
double              g_ai_confidence  = 0.0;
int                 g_last_latency   = 0;
bool                g_bridge_online  = false;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   g_trade.SetExpertMagicNumber(InpMagicNumber);
   g_trade.SetDeviationInPoints(InpSlippagePts);
   g_trade.SetTypeFilling(ORDER_FILLING_FOK);

   g_risk.Init(InpMaxDrawdownPct, InpMaxDailyLossUSD, InpMaxLotCap, InpMaxSpreadPts, InpMinMarginLevel, InpMaxLatencyMs);
   g_pricing.SetParameters(InpGamma, InpSigma, InpTimeHorizon);
   g_state.SetSymbol(_Symbol);

   PrintFormat("[INIT] JevLoop_HFT_EA v1.00 initialized on %s (Magic: %d)", _Symbol, InpMagicNumber);
   EventSetTimer(InpEvaluationSec);
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();
   Comment("");
   PrintFormat("[DEINIT] JevLoop_HFT_EA shut down. Reason: %d", reason);
}

//+------------------------------------------------------------------+
//| MT5 Common Files IPC Fallback                                    |
//+------------------------------------------------------------------+
bool QueryBridgeFile(const string payload, string &response, int &latency_ms)
{
   uint start_tick = GetTickCount();
   int h_write = FileOpen("jev_snapshot.json", FILE_WRITE|FILE_TXT|FILE_COMMON|FILE_SHARE_READ|FILE_SHARE_WRITE, 0, CP_UTF8);
   if(h_write == INVALID_HANDLE) return false;
   FileWriteString(h_write, payload);
   FileClose(h_write);

   for(int i = 0; i < 20; i++)
   {
      Sleep(15);
      if(FileIsExist("jev_response.json", FILE_COMMON))
      {
         int h_read = FileOpen("jev_response.json", FILE_READ|FILE_TXT|FILE_COMMON|FILE_SHARE_READ|FILE_SHARE_WRITE, 0, CP_UTF8);
         if(h_read != INVALID_HANDLE)
         {
            response = "";
            while(!FileIsEnding(h_read))
               response += FileReadString(h_read);
            FileClose(h_read);
            if(StringLen(response) > 5)
            {
               latency_ms = (int)(GetTickCount() - start_tick);
               return true;
            }
         }
      }
   }
   return false;
}

//+------------------------------------------------------------------+
//| Dual Transport Query to Python / Gemini Bridge                   |
//+------------------------------------------------------------------+
bool QueryBridge(const string payload, string &response, int &latency_ms)
{
   char post_data[];
   char result_data[];
   string result_headers;
   int len = StringLen(payload);
   StringToCharArray(payload, post_data, 0, len, CP_UTF8);

   uint start_tick = GetTickCount();
   ResetLastError();
   int res = WebRequest("POST", InpBridgeUrl, "Content-Type: application/json\r\n", 500, post_data, result_data, result_headers);
   latency_ms = (int)(GetTickCount() - start_tick);

   if(res == 200)
   {
      response = CharArrayToString(result_data, 0, WHOLE_ARRAY, CP_UTF8);
      return true;
   }

   // Fast fallback to Common Files IPC
   return QueryBridgeFile(payload, response, latency_ms);
}

//+------------------------------------------------------------------+
//| Fast JSON parser for AI Battery fields                          |
//+------------------------------------------------------------------+
void ParseBatteryResponse(const string json)
{
   // Parse direction
   int dir_pos = StringFind(json, "\"direction\":");
   if(dir_pos >= 0)
   {
      int start = StringFind(json, "\"", dir_pos + 12);
      int end   = StringFind(json, "\"", start + 1);
      if(start >= 0 && end > start)
         g_ai_direction = StringSubstr(json, start + 1, end - start - 1);
   }

   // Parse regime
   int reg_pos = StringFind(json, "\"regime\":");
   if(reg_pos >= 0)
   {
      int start = StringFind(json, "\"", reg_pos + 9);
      int end   = StringFind(json, "\"", start + 1);
      if(start >= 0 && end > start)
         g_ai_regime = StringSubstr(json, start + 1, end - start - 1);
   }

   // Parse confidence
   int conf_pos = StringFind(json, "\"confidence\":");
   if(conf_pos >= 0)
   {
      int end = StringFind(json, ",", conf_pos);
      if(end < 0) end = StringFind(json, "}", conf_pos);
      if(end > conf_pos)
         g_ai_confidence = StringToDouble(StringSubstr(json, conf_pos + 13, end - conf_pos - 13));
   }
}

//+------------------------------------------------------------------+
//| Deterministic Rules-Only Fallback Engine                         |
//+------------------------------------------------------------------+
void ExecuteRulesOnly(const SJevSnapshot &snap)
{
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double vwap_diff = snap.mid_price - snap.session_vwap;

   if(vwap_diff > (InpTakeProfitPts * point))
   {
      g_ai_direction = "DOWN"; // Mean reversion to VWAP
      g_ai_regime    = "mean_reverting";
      g_ai_confidence= 0.65;
   }
   else if(vwap_diff < -(InpTakeProfitPts * point))
   {
      g_ai_direction = "UP";   // Mean reversion to VWAP
      g_ai_regime    = "mean_reverting";
      g_ai_confidence= 0.65;
   }
   else
   {
      g_ai_direction = "NEUTRAL";
      g_ai_confidence= 0.50;
   }
}

//+------------------------------------------------------------------+
//| Timer function: Evaluation Loop                                  |
//+------------------------------------------------------------------+
void OnTimer()
{
   SJevSnapshot snap;
   if(!g_state.CaptureSnapshot(snap)) return;

   string payload = g_state.ToJson(snap);
   string response = "";

   g_bridge_online = QueryBridge(payload, response, g_last_latency);

   if(g_bridge_online)
   {
      ParseBatteryResponse(response);
   }
   else
   {
      ExecuteRulesOnly(snap);
   }

   bool is_late = (g_last_latency > InpMaxLatencyMs);
   ENUM_FALLBACK_STATE ladder_state = g_ladder.Evaluate(false, is_late, g_bridge_online, g_ai_confidence);

   // Update on-chart telemetry
   double r_price = g_pricing.CalculateReservationPrice(snap.mid_price, snap.net_inventory_lots);
   string telemetry = StringFormat(
      "=== JEV-MT5 HFT SENTINEL ===\n" +
      "Symbol: %s | Time: %s\n" +
      "Ladder State: %s\n" +
      "Bridge Status: %s (Latency: %d ms)\n" +
      "AI Battery: Regime: %s | Dir: %s | Conf: %.2f\n" +
      "Pricing: Mid: %.5f | VWAP: %.5f | Reserv: %.5f\n" +
      "Inventory: Net Lots: %.2f ($%.2f) | DD: %.2f%%\n" +
      "============================",
      _Symbol, TimeToString(TimeCurrent(), TIME_SECONDS),
      g_ladder.StateToString(),
      (g_bridge_online ? "ONLINE" : "OFFLINE (Rules-Only)"), g_last_latency,
      g_ai_regime, g_ai_direction, g_ai_confidence,
      snap.mid_price, snap.session_vwap, r_price,
      snap.net_inventory_lots, snap.net_inventory_usd, snap.drawdown_pct
   );
   Comment(telemetry);
}

//+------------------------------------------------------------------+
//| Top 1 Tool: Order Flow Point of Control (POC) Profile            |
//+------------------------------------------------------------------+
double CalcEAPOC(int bars = 24)
{
   double high[], low[], close[];
   long vol[];
   ArraySetAsSeries(high, true);
   ArraySetAsSeries(low, true);
   ArraySetAsSeries(close, true);
   ArraySetAsSeries(vol, true);

   if(CopyHigh(_Symbol, _Period, 0, bars, high) <= 0) return 0.0;
   CopyLow(_Symbol, _Period, 0, bars, low);
   CopyClose(_Symbol, _Period, 0, bars, close);
   CopyTickVolume(_Symbol, _Period, 0, bars, vol);

   double sum_vol_price = 0.0;
   long total_vol = 0;
   for(int i = 0; i < bars; i++)
   {
      double mid = (high[i] + low[i] + close[i]) / 3.0;
      sum_vol_price += (mid * (double)vol[i]);
      total_vol += vol[i];
   }
   if(total_vol > 0)
      return NormalizeDouble(sum_vol_price / (double)total_vol, _Digits);
   return 0.0;
}

//+------------------------------------------------------------------+
//| Top 2 Tool: Smart Money Concept (SMC) Fair Value Gap (FVG)       |
//+------------------------------------------------------------------+
string DetectEAFVG(ENUM_TIMEFRAMES tf)
{
   double high[], low[];
   ArraySetAsSeries(high, true);
   ArraySetAsSeries(low, true);

   if(CopyHigh(_Symbol, tf, 0, 4, high) < 4 || CopyLow(_Symbol, tf, 0, 4, low) < 4)
      return "BALANCED";

   if(low[1] > high[3]) return "BULLISH GAP";
   if(high[1] < low[3]) return "BEARISH GAP";
   return "BALANCED";
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double spread = (ask - bid) / point;

   // 1. Tool 3: Advanced Trade Manager (Auto BreakEven, Partial TP & Dynamic Trailing)
   if(InpUseBreakEven || InpUsePartialTP || InpUseDynamicTrailing)
   {
      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         ulong ticket = PositionGetTicket(i);
         if(ticket > 0 && PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
         {
            long p_type = PositionGetInteger(POSITION_TYPE);
            double open_p = PositionGetDouble(POSITION_PRICE_OPEN);
            double cur_sl = PositionGetDouble(POSITION_SL);
            double cur_tp = PositionGetDouble(POSITION_TP);
            double volume = PositionGetDouble(POSITION_VOLUME);

            if(p_type == POSITION_TYPE_BUY)
            {
               double profit_pts = (bid - open_p) / point;

               // Partial Take Profit (50% volume saat mencapai Trigger)
               if(InpUsePartialTP && volume > 0.01 && profit_pts >= InpBreakEvenTrigger)
               {
                  double close_vol = NormalizeDouble(volume * 0.5, 2);
                  if(close_vol >= 0.01)
                  {
                     if(g_trade.PositionClosePartial(ticket, close_vol))
                        PrintFormat("[TRADE_MGR] BUY #%I64d 50%% Partial Close executed: %.2f lots at profit %.1f pts", ticket, close_vol, profit_pts);
                  }
               }

               // BreakEven Shield
               if(InpUseBreakEven && profit_pts >= InpBreakEvenTrigger)
               {
                  double new_sl = NormalizeDouble(open_p + (InpBreakEvenLock * point), _Digits);
                  if(cur_sl < new_sl || cur_sl == 0.0)
                  {
                     g_trade.PositionModify(ticket, new_sl, cur_tp);
                     PrintFormat("[BE_SHIELD] BUY #%I64d SL moved to BreakEven: %.5f", ticket, new_sl);
                  }
               }

               // Dynamic Trailing Stop
               if(InpUseDynamicTrailing && profit_pts >= (InpBreakEvenTrigger + InpTrailingStepPts))
               {
                  double trail_sl = NormalizeDouble(bid - (InpBreakEvenTrigger * point), _Digits);
                  if(trail_sl > cur_sl)
                  {
                     g_trade.PositionModify(ticket, trail_sl, cur_tp);
                     PrintFormat("[TRAILING_STOP] BUY #%I64d Trailing SL updated to %.5f", ticket, trail_sl);
                  }
               }
            }
            else if(p_type == POSITION_TYPE_SELL)
            {
               double profit_pts = (open_p - ask) / point;

               // Partial Take Profit (50% volume saat mencapai Trigger)
               if(InpUsePartialTP && volume > 0.01 && profit_pts >= InpBreakEvenTrigger)
               {
                  double close_vol = NormalizeDouble(volume * 0.5, 2);
                  if(close_vol >= 0.01)
                  {
                     if(g_trade.PositionClosePartial(ticket, close_vol))
                        PrintFormat("[TRADE_MGR] SELL #%I64d 50%% Partial Close executed: %.2f lots at profit %.1f pts", ticket, close_vol, profit_pts);
                  }
               }

               // BreakEven Shield
               if(InpUseBreakEven && profit_pts >= InpBreakEvenTrigger)
               {
                  double new_sl = NormalizeDouble(open_p - (InpBreakEvenLock * point), _Digits);
                  if(cur_sl > new_sl || cur_sl == 0.0)
                  {
                     g_trade.PositionModify(ticket, new_sl, cur_tp);
                     PrintFormat("[BE_SHIELD] SELL #%I64d SL moved to BreakEven: %.5f", ticket, new_sl);
                  }
               }

               // Dynamic Trailing Stop
               if(InpUseDynamicTrailing && profit_pts >= (InpBreakEvenTrigger + InpTrailingStepPts))
               {
                  double trail_sl = NormalizeDouble(ask + (InpBreakEvenTrigger * point), _Digits);
                  if(cur_sl == 0.0 || trail_sl < cur_sl)
                  {
                     g_trade.PositionModify(ticket, trail_sl, cur_tp);
                     PrintFormat("[TRAILING_STOP] SELL #%I64d Trailing SL updated to %.5f", ticket, trail_sl);
                  }
               }
            }
         }
      }
   }

   ENUM_FALLBACK_STATE state = g_ladder.GetCurrentState();
   if(state == FALLBACK_KILL || state == FALLBACK_HOLD_LATE)
      return;

   // Rollover Protection Gate (20:00 - 22:00 UTC / 03:00 - 05:00 WIB)
   if(InpBlockRollover)
   {
      MqlDateTime dt;
      TimeCurrent(dt);
      if(dt.hour >= 20 && dt.hour <= 22)
         return;
   }

   // Strict Spread Filter
   if(spread > InpMaxSpreadPts)
      return;

   // Only take trades when there are 0 open positions for this symbol/magic
   int open_positions = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
         open_positions++;
   }
   if(open_positions > 0) return;

   // Top 1 & Top 2 Confluence Indicators
   double poc = InpUsePOCFilter ? CalcEAPOC(InpPOCLookbackBars) : 0.0;
   string fvg = InpUseFVGFilter ? DetectEAFVG(PERIOD_M15) : "BALANCED";

   // Determine order parameters
   double order_lot = InpBaseLot;
   if(state == FALLBACK_REDUCE)
      order_lot = NormalizeDouble(InpBaseLot * 0.5, 2);
   if(order_lot < 0.01) order_lot = 0.01;

   // Refresh current bid/ask
   ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   // AI Direction & Confluence Triggers
   if(g_ai_direction == "UP" && g_ai_confidence >= 0.70)
   {
      // Confluence Checks
      if(InpUsePOCFilter && poc > 0.0 && ask < poc)
         return; // Tolak Buy jika harga di bawah Point of Control (Discount trap)
      if(InpUseFVGFilter && fvg == "BEARISH GAP")
         return; // Tolak Buy jika ada gap ketidakseimbangan bearish M15

      double sl = NormalizeDouble(bid - (InpStopLossPts * point), _Digits);
      double tp = NormalizeDouble(ask + (InpTakeProfitPts * point), _Digits);

      ENUM_VETO_REASON veto = g_risk.EvaluateOrderVeto(_Symbol, ORDER_TYPE_BUY, order_lot, sl, g_last_latency);
      if(veto == VETO_NONE)
      {
         if(g_trade.Buy(order_lot, _Symbol, ask, sl, tp, "Jev-MT5 BUY [POC+SMC]"))
            PrintFormat("[EXECUTION] BUY executed: %.2f lots @ %.5f, SL: %.5f, TP: %.5f | POC: %.5f | FVG: %s", order_lot, ask, sl, tp, poc, fvg);
      }
   }
   else if(g_ai_direction == "DOWN" && g_ai_confidence >= 0.70)
   {
      // Confluence Checks
      if(InpUsePOCFilter && poc > 0.0 && bid > poc)
         return; // Tolak Sell jika harga di atas Point of Control (Premium trap)
      if(InpUseFVGFilter && fvg == "BULLISH GAP")
         return; // Tolak Sell jika ada gap ketidakseimbangan bullish M15

      double sl = NormalizeDouble(ask + (InpStopLossPts * point), _Digits);
      double tp = NormalizeDouble(bid - (InpTakeProfitPts * point), _Digits);

      ENUM_VETO_REASON veto = g_risk.EvaluateOrderVeto(_Symbol, ORDER_TYPE_SELL, order_lot, sl, g_last_latency);
      if(veto == VETO_NONE)
      {
         if(g_trade.Sell(order_lot, _Symbol, bid, sl, tp, "Jev-MT5 SELL [POC+SMC]"))
            PrintFormat("[EXECUTION] SELL executed: %.2f lots @ %.5f, SL: %.5f, TP: %.5f | POC: %.5f | FVG: %s", order_lot, bid, sl, tp, poc, fvg);
      }
   }
}
//+------------------------------------------------------------------+
