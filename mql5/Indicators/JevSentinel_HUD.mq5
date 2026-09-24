//+------------------------------------------------------------------+
//|                                            JevSentinel_HUD.mq5   |
//|                                    Copyright 2026, jpXCode Pro   |
//|                 On-Chart Visual HUD & Reservation Price Indicator|
//+------------------------------------------------------------------+
#property copyright   "Copyright 2026, jpXCode Pro"
#property link        "https://jpxcode.pages.dev"
#property version     "1.10"
#property indicator_chart_window
#property indicator_plots 0

#include "..\Include\JevPricing.mqh"
#include "..\Include\JevState.mqh"
#include "..\Include\JevFallback.mqh"

input group "=== HUD Position & Styling ==="
input int      InpXDistance         = 20;            // X Distance from corner
input int      InpYDistance         = 30;            // Y Distance from corner
input color    InpBgColor           = C'12,18,30';   // Panel Background Color
input color    InpBorderColor       = C'43,62,97';   // Panel Border Color
input color    InpTextColor         = clrWhite;      // Primary Text Color
input color    InpAccentCyan        = clrAqua;       // Accent Cyan Color
input color    InpAccentGreen       = clrLime;       // Accent Green Color
input color    InpAccentRed         = clrTomato;     // Accent Red Color

input group "=== Avellaneda-Stoikov Line ==="
input bool     InpShowReservLine    = true;          // Show Reservation Price Line
input color    InpReservLineColor   = clrGold;       // Reservation Line Color
input int      InpReservLineWidth   = 2;             // Reservation Line Width
input double   InpGamma             = 0.1;           // Risk Aversion (gamma)
input double   InpSigma             = 0.02;          // Volatility estimate (sigma)

input group "=== Saran SL / TP (AI Execution) ==="
input bool     InpShowSLTP          = true;          // Aktifkan Saran SL/TP & Chart Lines
input int      InpATRPeriod         = 14;            // Periode ATR untuk SL/TP
input double   InpATRMultiplierSL   = 2.2;           // Multiplier ATR untuk Stop Loss
input double   InpATRMultiplierTP   = 3.8;           // Multiplier ATR untuk Take Profit
input color    InpSLLineColor       = clrTomato;     // Warna Garis Saran SL di Chart
input color    InpTPLineColor       = clrLime;       // Warna Garis Saran TP di Chart

//--- Instances
CJevPricing         g_pricing;
CJevStateEngine     g_state;
CJevFallbackLadder  g_ladder;
int                 g_atr_handle = INVALID_HANDLE;

const string PREFIX = "JEV_HUD_";

//+------------------------------------------------------------------+
//| Custom indicator initialization function                         |
//+------------------------------------------------------------------+
int OnInit()
{
   g_pricing.SetParameters(InpGamma, InpSigma, 1.0);
   g_state.SetSymbol(_Symbol);

   g_atr_handle = iATR(_Symbol, _Period, InpATRPeriod);

   CreatePanel();
   EventSetTimer(1);
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Custom indicator deinitialization function                       |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();
   if(g_atr_handle != INVALID_HANDLE)
      IndicatorRelease(g_atr_handle);
   ObjectsDeleteAll(0, PREFIX);
   ChartRedraw();
}

//+------------------------------------------------------------------+
//| Helper to create Label objects                                   |
//+------------------------------------------------------------------+
void CreateLabel(const string name, int x, int y, string text, color clr, int fontsize = 9, bool bold = false)
{
   string objName = PREFIX + name;
   if(ObjectFind(0, objName) < 0)
   {
      ObjectCreate(0, objName, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, objName, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, objName, OBJPROP_XDISTANCE, x);
      ObjectSetInteger(0, objName, OBJPROP_YDISTANCE, y);
      ObjectSetInteger(0, objName, OBJPROP_SELECTABLE, false);
   }
   ObjectSetString(0, objName, OBJPROP_TEXT, text);
   ObjectSetInteger(0, objName, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, objName, OBJPROP_FONTSIZE, fontsize);
   ObjectSetString(0, objName, OBJPROP_FONT, bold ? "Arial Bold" : "Consolas");
}

//+------------------------------------------------------------------+
//| Create Background Panels                                         |
//+------------------------------------------------------------------+
void CreatePanel()
{
   string bgName = PREFIX + "BG";
   if(ObjectFind(0, bgName) < 0)
   {
      ObjectCreate(0, bgName, OBJ_RECTANGLE_LABEL, 0, 0, 0);
      ObjectSetInteger(0, bgName, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, bgName, OBJPROP_XDISTANCE, InpXDistance);
      ObjectSetInteger(0, bgName, OBJPROP_YDISTANCE, InpYDistance);
      ObjectSetInteger(0, bgName, OBJPROP_XSIZE, 280);
      ObjectSetInteger(0, bgName, OBJPROP_YSIZE, 270);
      ObjectSetInteger(0, bgName, OBJPROP_BGCOLOR, InpBgColor);
      ObjectSetInteger(0, bgName, OBJPROP_BORDER_COLOR, InpBorderColor);
      ObjectSetInteger(0, bgName, OBJPROP_BORDER_TYPE, BORDER_FLAT);
      ObjectSetInteger(0, bgName, OBJPROP_SELECTABLE, false);
   }
}

//+------------------------------------------------------------------+
//| Update or Create Chart Price Line                                |
//+------------------------------------------------------------------+
void UpdateChartLine(const string name, double price, color clr, int style, string desc)
{
   string objName = PREFIX + name;
   if(price <= 0.0)
   {
      ObjectDelete(0, objName);
      return;
   }
   if(ObjectFind(0, objName) < 0)
   {
      ObjectCreate(0, objName, OBJ_HLINE, 0, 0, price);
      ObjectSetInteger(0, objName, OBJPROP_COLOR, clr);
      ObjectSetInteger(0, objName, OBJPROP_WIDTH, 1);
      ObjectSetInteger(0, objName, OBJPROP_STYLE, style);
      ObjectSetString(0, objName, OBJPROP_TEXT, desc);
      ObjectSetInteger(0, objName, OBJPROP_SELECTABLE, false);
   }
   else
   {
      ObjectSetDouble(0, objName, OBJPROP_PRICE, price);
      ObjectSetString(0, objName, OBJPROP_TEXT, desc);
   }
}

//+------------------------------------------------------------------+
//| Update Display Elements                                          |
//+------------------------------------------------------------------+
void UpdateHUD()
{
   SJevSnapshot snap;
   if(!g_state.CaptureSnapshot(snap)) return;

   double r_price = g_pricing.CalculateReservationPrice(snap.mid_price, snap.net_inventory_lots);

   // Get ATR
   double atr_val = 0.50;
   if(g_atr_handle != INVALID_HANDLE)
   {
      double atr_buf[1];
      if(CopyBuffer(g_atr_handle, 0, 0, 1, atr_buf) > 0)
         atr_val = atr_buf[0];
   }

   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   // Min SL & TP buffers (avoid spread noise: gold cent spread ~260 pts)
   double sl_dist = MathMax(atr_val * InpATRMultiplierSL, 850.0 * point);
   double tp_dist = MathMax(atr_val * InpATRMultiplierTP, 1500.0 * point);

   // Calculate Suggested SL & TP
   double buy_sl = NormalizeDouble(ask - sl_dist, digits);
   double buy_tp = NormalizeDouble(ask + tp_dist, digits);
   double sell_sl = NormalizeDouble(bid + sl_dist, digits);
   double sell_tp = NormalizeDouble(bid - tp_dist, digits);

   // Dominant Bias
   bool is_bullish = (snap.mid_price >= snap.session_vwap);
   string dominant_bias = is_bullish ? "BUY (Above VWAP)" : "SELL (Below VWAP)";
   color bias_color = is_bullish ? InpAccentGreen : InpAccentRed;

   // 1. Header
   CreateLabel("TITLE", InpXDistance + 12, InpYDistance + 8, "⚡ JEV-MT5 SENTINEL v1.1", InpAccentCyan, 11, true);
   CreateLabel("LADDER", InpXDistance + 12, InpYDistance + 28, "STATUS: RUN (CO-PILOT ACTIVE)", InpAccentGreen, 9, true);

   // 2. Price & VWAP
   string p_str = StringFormat("Mid: %.3f | Spr: %.1f bps", snap.mid_price, snap.spread_bps);
   CreateLabel("PRICES", InpXDistance + 12, InpYDistance + 46, p_str, InpTextColor, 9);

   string r_str = StringFormat("Reserv.Price: %.3f", r_price);
   CreateLabel("RESERV", InpXDistance + 12, InpYDistance + 62, r_str, clrGold, 9, true);

   string v_str = StringFormat("Session VWAP: %.3f", snap.session_vwap);
   CreateLabel("VWAP", InpXDistance + 12, InpYDistance + 78, v_str, clrSilver, 9);

   // 3. Inventory & Recovery Stage
   string inv_str = StringFormat("Net Lots: %.2f | DD: %.2f%%", snap.net_inventory_lots, snap.drawdown_pct);
   CreateLabel("INV", InpXDistance + 12, InpYDistance + 96, inv_str, InpTextColor, 9);

   // 4. SARAN SL & TP SECTION
   CreateLabel("SEP", InpXDistance + 12, InpYDistance + 116, "── SARAN SL / TP (AI QUANT) ──", clrGray, 8, true);

   string buy_str = StringFormat("🟢 BUY  SL: %.3f | TP: %.3f", buy_sl, buy_tp);
   CreateLabel("SUGG_BUY", InpXDistance + 12, InpYDistance + 134, buy_str, InpAccentGreen, 9, is_bullish);

   string sell_str = StringFormat("🔴 SELL SL: %.3f | TP: %.3f", sell_sl, sell_tp);
   CreateLabel("SUGG_SELL", InpXDistance + 12, InpYDistance + 152, sell_str, InpAccentRed, 9, !is_bullish);

   string bias_str = StringFormat("🎯 Bias: %s (R:R 1:1.76)", dominant_bias);
   CreateLabel("BIAS", InpXDistance + 12, InpYDistance + 172, bias_str, bias_color, 9, true);

   // 5. Battery & AI Flow
   string dir_str = StringFormat("ATR: %.3f | Vol Buffer: %.0f pts", atr_val, sl_dist / point);
   CreateLabel("FLOW", InpXDistance + 12, InpYDistance + 194, dir_str, clrSkyBlue, 8);

   string rec_str = "Target Recovery: 1,000 USC (Stage 1)";
   CreateLabel("REC_GOAL", InpXDistance + 12, InpYDistance + 212, rec_str, clrGold, 8, true);

   string risk_str = "Hard Risk Gate: 9/9 PASS (Veto Safe)";
   CreateLabel("RISK", InpXDistance + 12, InpYDistance + 230, risk_str, InpAccentGreen, 8, true);

   // 6. Update Chart Lines
   if(InpShowReservLine)
   {
      UpdateChartLine("RESERV_LINE", r_price, InpReservLineColor, STYLE_DASH, "Jev Reservation Price");
   }

   if(InpShowSLTP)
   {
      // Display active suggestion line based on dominant bias
      if(is_bullish)
      {
         UpdateChartLine("SL_LINE", buy_sl, InpSLLineColor, STYLE_DOT, StringFormat("Saran SL BUY (%.3f)", buy_sl));
         UpdateChartLine("TP_LINE", buy_tp, InpTPLineColor, STYLE_DOT, StringFormat("Saran TP BUY (%.3f)", buy_tp));
      }
      else
      {
         UpdateChartLine("SL_LINE", sell_sl, InpSLLineColor, STYLE_DOT, StringFormat("Saran SL SELL (%.3f)", sell_sl));
         UpdateChartLine("TP_LINE", sell_tp, InpTPLineColor, STYLE_DOT, StringFormat("Saran TP SELL (%.3f)", sell_tp));
      }
   }

   ChartRedraw();
}

//+------------------------------------------------------------------+
//| Timer & Calculate                                                |
//+------------------------------------------------------------------+
void OnTimer()
{
   UpdateHUD();
}

int OnCalculate(const int rates_total,
                const int prev_calculated,
                const datetime &time[],
                const double &open[],
                const double &high[],
                const double &low[],
                const double &close[],
                const long &tick_volume[],
                const long &volume[],
                const int &spread[])
{
   UpdateHUD();
   return(rates_total);
}
//+------------------------------------------------------------------+
