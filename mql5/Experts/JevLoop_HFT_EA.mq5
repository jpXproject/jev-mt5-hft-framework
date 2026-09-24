//+------------------------------------------------------------------+
//|                                             JevLoop_HFT_EA.mq5   |
//|                                    Copyright 2026, jpXCode Pro   |
//|         Jev-MT5 24/7 Algorithmic Architecture with Hard Risk Gate|
//+------------------------------------------------------------------+
#property copyright   "Copyright 2026, jpXCode Pro"
#property link        "https://jpxcode.pages.dev"
#property version     "1.00"
#property description "Jev-MT5 Deterministic Execution & Probabilistic AI Gate"

#include <Trade\Trade.mqh>
#include "..\Include\JevRiskEngine.mqh"
#include "..\Include\JevPricing.mqh"
#include "..\Include\JevState.mqh"
#include "..\Include\JevFallback.mqh"

//--- Inputs
input group "=== Execution & Lot Settings ==="
input ulong    InpMagicNumber       = 20260924;      // Magic Number
input double   InpBaseLot           = 0.01;          // Base Lot Size (L2 Small Lot)
input int      InpStopLossPts       = 200;           // Stop Loss in Points
input int      InpTakeProfitPts     = 400;           // Take Profit in Points
input int      InpSlippagePts       = 30;            // Max Allowed Slippage

input group "=== 9 Hard Risk Veto Limits ==="
input double   InpMaxDrawdownPct    = 3.0;           // Max Floating Drawdown %
input double   InpMaxDailyLossUSD   = 50.0;          // Max Daily Loss USD
input double   InpMaxLotCap         = 0.10;          // Absolute Max Lot Cap
input double   InpMaxSpreadPts      = 50.0;          // Max Allowed Spread (pts)
input double   InpMinMarginLevel    = 200.0;         // Min Margin Level %
input int      InpMaxLatencyMs      = 800;           // Max Response Deadline (ms)

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
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   ENUM_FALLBACK_STATE state = g_ladder.GetCurrentState();
   if(state == FALLBACK_KILL || state == FALLBACK_HOLD_LATE)
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

   // Determine order parameters
   double order_lot = InpBaseLot;
   if(state == FALLBACK_REDUCE)
      order_lot = NormalizeDouble(InpBaseLot * 0.5, 2);
   if(order_lot < 0.01) order_lot = 0.01;

   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   if(g_ai_direction == "UP" && g_ai_confidence >= 0.70)
   {
      double sl = NormalizeDouble(ask - (InpStopLossPts * point), _Digits);
      double tp = NormalizeDouble(ask + (InpTakeProfitPts * point), _Digits);

      ENUM_VETO_REASON veto = g_risk.EvaluateOrderVeto(_Symbol, ORDER_TYPE_BUY, order_lot, sl, g_last_latency);
      if(veto == VETO_NONE)
      {
         if(g_trade.Buy(order_lot, _Symbol, ask, sl, tp, "Jev-MT5 BUY"))
            PrintFormat("[EXECUTION] BUY executed: %.2f lots @ %.5f, SL: %.5f, TP: %.5f", order_lot, ask, sl, tp);
      }
   }
   else if(g_ai_direction == "DOWN" && g_ai_confidence >= 0.70)
   {
      double sl = NormalizeDouble(bid + (InpStopLossPts * point), _Digits);
      double tp = NormalizeDouble(bid - (InpTakeProfitPts * point), _Digits);

      ENUM_VETO_REASON veto = g_risk.EvaluateOrderVeto(_Symbol, ORDER_TYPE_SELL, order_lot, sl, g_last_latency);
      if(veto == VETO_NONE)
      {
         if(g_trade.Sell(order_lot, _Symbol, bid, sl, tp, "Jev-MT5 SELL"))
            PrintFormat("[EXECUTION] SELL executed: %.2f lots @ %.5f, SL: %.5f, TP: %.5f", order_lot, bid, sl, tp);
      }
   }
}
//+------------------------------------------------------------------+
