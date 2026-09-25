//+------------------------------------------------------------------+
//|                                            JevSentinel_HUD.mq5   |
//|                    Copyright © 2026 jpXCode. All Rights Reserved. |
//|                 Institutional Quant & Real-Time HFT Sentinel HUD |
//+------------------------------------------------------------------+
#property copyright   "Copyright © 2026 jpXCode. All Rights Reserved."
#property link        "https://jpxcode.pages.dev"
#property description "jpXCode Pro HFT Framework | Proprietary Trading Sentinel & Execution Engine"
#property version     "1.40"
#property indicator_chart_window
#property indicator_plots 0

#include "..\Include\JevPricing.mqh"
#include "..\Include\JevState.mqh"
#include "..\Include\JevFallback.mqh"

input group "=== HUD Position & Default Styling ==="
input int      InpXDistance         = 20;            // X Default Distance
input int      InpYDistance         = 30;            // Y Default Distance
input double   InpDefaultScale      = 1.00;          // Skala Panel Default (1.0 = 100%)
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

input group "=== Saran SL / TP & Interactive Buttons ==="
input bool     InpShowSLTP          = true;          // Aktifkan Saran SL/TP & Chart Lines
input int      InpATRPeriod         = 14;            // Periode ATR untuk SL/TP
input double   InpATRMultiplierSL   = 2.2;           // Multiplier ATR untuk Stop Loss
input double   InpATRMultiplierTP   = 3.8;           // Multiplier ATR untuk Take Profit
input color    InpSLLineColor       = clrTomato;     // Warna Garis Saran SL di Chart
input color    InpTPLineColor       = clrLime;       // Warna Garis Saran TP di Chart
input double   InpDefaultLot        = 0.01;          // Lot size default

//--- Instances
CJevPricing         g_pricing;
CJevStateEngine     g_state;
CJevFallbackLadder  g_ladder;
int                 g_atr_handle = INVALID_HANDLE;

const string PREFIX = "JEV_HUD_";

//--- State Drag & Scaling
int    g_panelX     = 20;
int    g_panelY     = 30;
double g_scale      = 1.00;
bool   g_isDragging = false;
int    g_dragOffX   = 0;
int    g_dragOffY   = 0;

double g_last_buy_sl = 0.0, g_last_buy_tp = 0.0;
double g_last_sell_sl = 0.0, g_last_sell_tp = 0.0;

// Scaling helpers
int S(int v) { return (int)MathRound(v * g_scale); }
int F(int font_size) { int sz = (int)MathRound(font_size * g_scale); return (sz < 7) ? 7 : sz; }

string VarNameX() { return StringFormat("JEV_HUD_X_%I64d", ChartID()); }
string VarNameY() { return StringFormat("JEV_HUD_Y_%I64d", ChartID()); }
string VarNameS() { return StringFormat("JEV_HUD_S_%I64d", ChartID()); }

//+------------------------------------------------------------------+
//| Custom indicator initialization function                         |
//+------------------------------------------------------------------+
int OnInit()
{
   g_pricing.SetParameters(InpGamma, InpSigma, 1.0);
   g_state.SetSymbol(_Symbol);

   g_atr_handle = iATR(_Symbol, _Period, InpATRPeriod);

   // Restore Position and Scale if saved
   if(GlobalVariableCheck(VarNameX())) g_panelX = (int)GlobalVariableGet(VarNameX());
   else g_panelX = InpXDistance;

   if(GlobalVariableCheck(VarNameY())) g_panelY = (int)GlobalVariableGet(VarNameY());
   else g_panelY = InpYDistance;

   if(GlobalVariableCheck(VarNameS())) g_scale = GlobalVariableGet(VarNameS());
   else g_scale = InpDefaultScale;

   if(g_scale < 0.75) g_scale = 0.75;
   if(g_scale > 1.75) g_scale = 1.75;

   ChartSetInteger(0, CHART_EVENT_MOUSE_MOVE, true);

   CreatePanel();
   UpdateHUD();
   EventSetTimer(1);
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Custom indicator deinitialization function                       |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();
   ChartSetInteger(0, CHART_EVENT_MOUSE_MOVE, false);
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
      ObjectSetInteger(0, objName, OBJPROP_SELECTABLE, false);
   }
   ObjectSetInteger(0, objName, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, objName, OBJPROP_YDISTANCE, y);
   ObjectSetString(0, objName, OBJPROP_TEXT, text);
   ObjectSetInteger(0, objName, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, objName, OBJPROP_FONTSIZE, F(fontsize));
   ObjectSetString(0, objName, OBJPROP_FONT, bold ? "Arial Bold" : "Consolas");
}

//+------------------------------------------------------------------+
//| Helper to create Interactive Button objects                      |
//+------------------------------------------------------------------+
void CreateButton(const string name, int x, int y, int width, int height, string text, color bg_clr, color text_clr, int font_size = 9)
{
   string objName = PREFIX + name;
   if(ObjectFind(0, objName) < 0)
   {
      ObjectCreate(0, objName, OBJ_BUTTON, 0, 0, 0);
      ObjectSetInteger(0, objName, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetString(0, objName, OBJPROP_FONT, "Arial Bold");
      ObjectSetInteger(0, objName, OBJPROP_SELECTABLE, false);
   }
   ObjectSetInteger(0, objName, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, objName, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, objName, OBJPROP_XSIZE, width);
   ObjectSetInteger(0, objName, OBJPROP_YSIZE, height);
   ObjectSetInteger(0, objName, OBJPROP_FONTSIZE, F(font_size));
   ObjectSetString(0, objName, OBJPROP_TEXT, text);
   ObjectSetInteger(0, objName, OBJPROP_BGCOLOR, bg_clr);
   ObjectSetInteger(0, objName, OBJPROP_COLOR, text_clr);
   ObjectSetInteger(0, objName, OBJPROP_STATE, false);
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
      ObjectSetInteger(0, bgName, OBJPROP_BORDER_TYPE, BORDER_FLAT);
      ObjectSetInteger(0, bgName, OBJPROP_SELECTABLE, false);
   }
   ObjectSetInteger(0, bgName, OBJPROP_XDISTANCE, g_panelX);
   ObjectSetInteger(0, bgName, OBJPROP_YDISTANCE, g_panelY);
   ObjectSetInteger(0, bgName, OBJPROP_XSIZE, S(310));
   ObjectSetInteger(0, bgName, OBJPROP_YSIZE, S(385));
   ObjectSetInteger(0, bgName, OBJPROP_BGCOLOR, InpBgColor);
   ObjectSetInteger(0, bgName, OBJPROP_BORDER_COLOR, InpBorderColor);

   // Header Drag Handle Bar
   string headerName = PREFIX + "HEADER_BAR";
   if(ObjectFind(0, headerName) < 0)
   {
      ObjectCreate(0, headerName, OBJ_RECTANGLE_LABEL, 0, 0, 0);
      ObjectSetInteger(0, headerName, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, headerName, OBJPROP_BORDER_TYPE, BORDER_FLAT);
      ObjectSetInteger(0, headerName, OBJPROP_SELECTABLE, false);
   }
   ObjectSetInteger(0, headerName, OBJPROP_XDISTANCE, g_panelX);
   ObjectSetInteger(0, headerName, OBJPROP_YDISTANCE, g_panelY);
   ObjectSetInteger(0, headerName, OBJPROP_XSIZE, S(310));
   ObjectSetInteger(0, headerName, OBJPROP_YSIZE, S(28));
   ObjectSetInteger(0, headerName, OBJPROP_BGCOLOR, C'20,30,50');
   ObjectSetInteger(0, headerName, OBJPROP_BORDER_COLOR, InpBorderColor);

   // Percentage Scale Resize Buttons on Title Bar
   CreateButton("BTN_SC_M", g_panelX + S(200), g_panelY + S(3), S(32), S(22), "-25%", C'35,45,65', clrAqua, 7);
   CreateButton("BTN_SC_R", g_panelX + S(234), g_panelY + S(3), S(38), S(22), "100%", C'35,45,65', clrWhite, 7);
   CreateButton("BTN_SC_P", g_panelX + S(274), g_panelY + S(3), S(32), S(22), "+25%", C'35,45,65', clrAqua, 7);

   // Interactive Execution & Action Buttons (Repositioned to Y+262)
   CreateButton("BTN_BUY", g_panelX + S(12), g_panelY + S(262), S(90), S(28), "BUY 0.01", C'5,150,105', clrWhite, 8);
   CreateButton("BTN_SELL", g_panelX + S(108), g_panelY + S(262), S(90), S(28), "SELL 0.01", C'220,38,38', clrWhite, 8);
   CreateButton("BTN_COPY", g_panelX + S(204), g_panelY + S(262), S(94), S(28), "COPY SL/TP", C'30,58,138', clrWhite, 8);
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
//| Multi-Timeframe (MTF) Momentum & Power Calculator               |
//+------------------------------------------------------------------+
double CalcTFPower(ENUM_TIMEFRAMES tf, double atr)
{
   double c0 = iClose(_Symbol, tf, 0);
   double o0 = iOpen(_Symbol, tf, 0);
   double c3 = iClose(_Symbol, tf, 3);
   double ma14 = 0.0;
   for(int i = 0; i < 14; i++) ma14 += iClose(_Symbol, tf, i);
   ma14 /= 14.0;
   
   double score = 50.0;
   if(c0 > o0) score += 15.0;
   else if(c0 < o0) score -= 15.0;
   
   if(c0 > ma14) score += 15.0;
   else if(c0 < ma14) score -= 15.0;
   
   double delta4 = c0 - c3;
   score += MathMax(-15.0, MathMin(15.0, (delta4 / (atr > 0 ? atr : 1.0)) * 15.0));
   return MathMax(5.0, MathMin(95.0, score));
}

//+------------------------------------------------------------------+
//| Helper to read simple numeric value from JSON string             |
//+------------------------------------------------------------------+
double ParseJsonNumber(string json, string key, double default_val)
{
   string needle = "\"" + key + "\":";
   int pos = StringFind(json, needle);
   if(pos < 0) return default_val;
   int start = pos + StringLen(needle);
   while(start < StringLen(json) && (StringGetCharacter(json, start) == ' ' || StringGetCharacter(json, start) == '\t'))
      start++;
   int end = start;
   while(end < StringLen(json))
   {
      ushort ch = StringGetCharacter(json, end);
      if((ch >= '0' && ch <= '9') || ch == '.' || ch == '-')
         end++;
      else
         break;
   }
   if(end > start)
      return StringToDouble(StringSubstr(json, start, end - start));
   return default_val;
}

//+------------------------------------------------------------------+
//| Update Display Elements                                          |
//+------------------------------------------------------------------+
void UpdateHUD()
{
   CreatePanel();

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

   // Min SL & TP buffers
   double sl_dist = MathMax(atr_val * InpATRMultiplierSL, 850.0 * point);
   double tp_dist = MathMax(atr_val * InpATRMultiplierTP, 1500.0 * point);

   // Calculate Suggested SL & TP
   double buy_sl = NormalizeDouble(ask - sl_dist, digits);
   double buy_tp = NormalizeDouble(ask + tp_dist, digits);
   double sell_sl = NormalizeDouble(bid + sl_dist, digits);
   double sell_tp = NormalizeDouble(bid - tp_dist, digits);

   g_last_buy_sl = buy_sl;
   g_last_buy_tp = buy_tp;
   g_last_sell_sl = sell_sl;
   g_last_sell_tp = sell_tp;

   // Multi-Timeframe (MTF) Momentum Calculation: M1, M5, M15, H1
   double m1_p = CalcTFPower(PERIOD_M1, atr_val);
   double m5_p = CalcTFPower(PERIOD_M5, atr_val);
   double m15_p = CalcTFPower(PERIOD_M15, atr_val);
   double h1_p = CalcTFPower(PERIOD_H1, atr_val);
   double buy_power = MathRound((m1_p * 0.20) + (m5_p * 0.35) + (m15_p * 0.25) + (h1_p * 0.20));
   double sell_power = 100.0 - buy_power;

   // Try reading bridge telemetry JSON if available for 100% exact sync
   int handle = FileOpen("jev_telemetry.json", FILE_READ|FILE_TXT|FILE_COMMON);
   if(handle != INVALID_HANDLE)
   {
      string json_content = "";
      while(!FileIsEnding(handle))
         json_content += FileReadString(handle);
      FileClose(handle);

      if(StringLen(json_content) > 10)
      {
         double f_bp = ParseJsonNumber(json_content, "buy_power", -1.0);
         if(f_bp >= 0.0)
         {
            buy_power = f_bp;
            sell_power = 100.0 - buy_power;
            m1_p = ParseJsonNumber(json_content, "m1_buy", m1_p);
            m5_p = ParseJsonNumber(json_content, "m5_buy", m5_p);
            m15_p = ParseJsonNumber(json_content, "m15_buy", m15_p);
            h1_p = ParseJsonNumber(json_content, "h1_buy", h1_p);
            buy_sl = ParseJsonNumber(json_content, "buy_sl", buy_sl);
            buy_tp = ParseJsonNumber(json_content, "buy_tp", buy_tp);
            sell_sl = ParseJsonNumber(json_content, "sell_sl", sell_sl);
            sell_tp = ParseJsonNumber(json_content, "sell_tp", sell_tp);
         }
      }
   }

   g_last_buy_sl = buy_sl;
   g_last_buy_tp = buy_tp;
   g_last_sell_sl = sell_sl;
   g_last_sell_tp = sell_tp;

   // Dominant Bias & Power Score
   bool is_bullish = (snap.mid_price >= snap.session_vwap);
   string dominant_bias = buy_power >= 50.0 ? "BUY (Bullish Flow)" : "SELL (Bearish Flow)";
   color bias_color = buy_power >= 50.0 ? InpAccentGreen : InpAccentRed;

   // 1. Header (Title + Drag Hint)
   string sc_pct = StringFormat("%.0f%%", g_scale * 100.0);
   CreateLabel("TITLE", g_panelX + S(8), g_panelY + S(5), "⚡ JEV SENTINEL [DRAGGABLE]", InpAccentCyan, 9, true);

   // 2. Price & VWAP
   string p_str = StringFormat("Mid: %.3f | Spr: %.1f bps", snap.mid_price, snap.spread_bps);
   CreateLabel("PRICES", g_panelX + S(12), g_panelY + S(36), p_str, InpTextColor, 9);

   string r_str = StringFormat("Reserv.Price: %.3f", r_price);
   CreateLabel("RESERV", g_panelX + S(12), g_panelY + S(54), r_str, clrGold, 9, true);

   string v_str = StringFormat("Session VWAP: %.3f", snap.session_vwap);
   CreateLabel("VWAP", g_panelX + S(12), g_panelY + S(72), v_str, clrSilver, 9);

   // 3. KEKUATAN BUY vs SELL & PARAMETER MTF (M1, M5, M15, H1)
   string pwr_str = StringFormat("Kekuatan: BUY %.0f%% | SELL %.0f%%", buy_power, sell_power);
   color pwr_color = buy_power >= 50.0 ? InpAccentGreen : InpAccentRed;
   CreateLabel("POWER", g_panelX + S(12), g_panelY + S(90), pwr_str, pwr_color, 9, true);

   string mtf_str = StringFormat("MTF: M1[%.0f%%] M5[%.0f%%] M15[%.0f%%] H1[%.0f%%]", m1_p, m5_p, m15_p, h1_p);
   CreateLabel("MTF_POWER", g_panelX + S(12), g_panelY + S(108), mtf_str, clrSkyBlue, 8, true);

   // 4. SARAN SL & TP SECTION
   CreateLabel("SEP", g_panelX + S(12), g_panelY + S(126), "── SARAN SL / TP (AI QUANT) ──", clrGray, 8, true);

   string buy_str = StringFormat("🟢 BUY  SL: %.3f | TP: %.3f", buy_sl, buy_tp);
   CreateLabel("SUGG_BUY", g_panelX + S(12), g_panelY + S(144), buy_str, InpAccentGreen, 9, is_bullish);

   string sell_str = StringFormat("🔴 SELL SL: %.3f | TP: %.3f", sell_sl, sell_tp);
   CreateLabel("SUGG_SELL", g_panelX + S(12), g_panelY + S(162), sell_str, InpAccentRed, 9, !is_bullish);

   string bias_str = StringFormat("🎯 Bias: %s (R:R 1:1.73)", dominant_bias);
   CreateLabel("BIAS", g_panelX + S(12), g_panelY + S(182), bias_str, bias_color, 9, true);

   // 5. Battery & Volatility
   string dir_str = StringFormat("ATR: %.3f | Vol Buffer: %.0f pts", atr_val, sl_dist / point);
   CreateLabel("FLOW", g_panelX + S(12), g_panelY + S(202), dir_str, clrLightSlateGray, 8);

   string rec_str = StringFormat("Target Recovery: 1,000 USC | Skala: %s", sc_pct);
   CreateLabel("REC_GOAL", g_panelX + S(12), g_panelY + S(220), rec_str, clrGold, 8, true);

   string stat_str = "Geser Header untuk Drag | Klik Tombol Aksi:";
   CreateLabel("BTN_HINT", g_panelX + S(12), g_panelY + S(238), stat_str, clrLightSteelBlue, 8, false);

   // 6. Action Feedback Label & Author Brand Legacy
   CreateLabel("ACTION_FEEDBACK", g_panelX + S(12), g_panelY + S(296), "Siap eksekusi / copy", clrDarkGray, 8, false);
   CreateLabel("FOOTER_BRAND", g_panelX + S(12), g_panelY + S(318), "⚡ jpXCode Pro © 2026 | All Rights Reserved", clrDarkCyan, 7, true);
   CreateLabel("FOOTER_LINK", g_panelX + S(12), g_panelY + S(336), "Author: jpXCode | https://jpxcode.pages.dev", clrSlateGray, 7, false);

   // 7. Update Chart Lines
   if(InpShowReservLine)
   {
      UpdateChartLine("RESERV_LINE", r_price, InpReservLineColor, STYLE_DASH, "Jev Reservation Price");
   }

   if(InpShowSLTP)
   {
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
//| Chart Event Handler (Mouse Drag & Interactive Button Clicks)     |
//+------------------------------------------------------------------+
void OnChartEvent(const int id,
                  const long &lparam,
                  const double &dparam,
                  const string &sparam)
{
   // 1. Mouse Dragging
   if(id == CHARTEVENT_MOUSE_MOVE)
   {
      int mx = (int)lparam;
      int my = (int)dparam;
      uint mBtn = (uint)StringToInteger(sparam);
      bool leftBtn = ((mBtn & 1) != 0);

      if(leftBtn)
      {
         if(!g_isDragging)
         {
            // Cek apakah klik berada di Header Drag Bar
            int headerW = S(310);
            int headerH = S(28);
            if(mx >= g_panelX && mx <= g_panelX + headerW &&
               my >= g_panelY && my <= g_panelY + headerH)
            {
               g_isDragging = true;
               g_dragOffX = mx - g_panelX;
               g_dragOffY = my - g_panelY;
            }
         }
         else
         {
            // Sedang drag: update posisi panel
            int newX = mx - g_dragOffX;
            int newY = my - g_dragOffY;

            // Batasi dalam chart window
            long chartW = ChartGetInteger(0, CHART_WIDTH_IN_PIXELS);
            long chartH = ChartGetInteger(0, CHART_HEIGHT_IN_PIXELS);

            if(newX < 0) newX = 0;
            if(newY < 0) newY = 0;
            if(newX > (int)chartW - S(100)) newX = (int)chartW - S(100);
            if(newY > (int)chartH - S(50)) newY = (int)chartH - S(50);

            g_panelX = newX;
            g_panelY = newY;

            UpdateHUD();
         }
      }
      else
      {
         // Mouse dilepas: hentikan drag dan simpan posisi
         if(g_isDragging)
         {
            g_isDragging = false;
            GlobalVariableSet(VarNameX(), (double)g_panelX);
            GlobalVariableSet(VarNameY(), (double)g_panelY);
         }
      }
   }

   // 2. Object Click Events
   if(id == CHARTEVENT_OBJECT_CLICK)
   {
      // A. Tombol Skala Persentase
      if(sparam == PREFIX + "BTN_SC_M")
      {
         g_scale = MathMax(0.75, g_scale - 0.25);
         GlobalVariableSet(VarNameS(), g_scale);
         UpdateHUD();
         ObjectSetInteger(0, sparam, OBJPROP_STATE, false);
      }
      else if(sparam == PREFIX + "BTN_SC_R")
      {
         g_scale = 1.00;
         GlobalVariableSet(VarNameS(), g_scale);
         UpdateHUD();
         ObjectSetInteger(0, sparam, OBJPROP_STATE, false);
      }
      else if(sparam == PREFIX + "BTN_SC_P")
      {
         g_scale = MathMin(1.75, g_scale + 0.25);
         GlobalVariableSet(VarNameS(), g_scale);
         UpdateHUD();
         ObjectSetInteger(0, sparam, OBJPROP_STATE, false);
      }
      // B. Tombol Copy SL/TP
      else if(sparam == PREFIX + "BTN_COPY")
      {
         string text = StringFormat("XAUUSD SARAN SL/TP | BUY SL:%.3f TP:%.3f | SELL SL:%.3f TP:%.3f",
                                    g_last_buy_sl, g_last_buy_tp, g_last_sell_sl, g_last_sell_tp);
         Print("📋 [COPY_SLTP]: ", text);
         Alert("📋 NILAI DISALIN KE LOG:\n", text);
         CreateLabel("ACTION_FEEDBACK", g_panelX + S(12), g_panelY + S(294), "✅ SL/TP dicetak ke Terminal Log", clrAqua, 8, true);
         ObjectSetInteger(0, sparam, OBJPROP_STATE, false);
         ChartRedraw();
      }
      // C. Tombol BUY & SELL Action
      else if(sparam == PREFIX + "BTN_BUY")
      {
         Alert("🟢 [BUY CLICKED]: Saran BUY SL: ", g_last_buy_sl, " TP: ", g_last_buy_tp);
         CreateLabel("ACTION_FEEDBACK", g_panelX + S(12), g_panelY + S(294), "🟢 BUY Triggered (Gunakan Web/EA)", InpAccentGreen, 8, true);
         ObjectSetInteger(0, sparam, OBJPROP_STATE, false);
         ChartRedraw();
      }
      else if(sparam == PREFIX + "BTN_SELL")
      {
         Alert("🔴 [SELL CLICKED]: Saran SELL SL: ", g_last_sell_sl, " TP: ", g_last_sell_tp);
         CreateLabel("ACTION_FEEDBACK", g_panelX + S(12), g_panelY + S(294), "🔴 SELL Triggered (Gunakan Web/EA)", InpAccentRed, 8, true);
         ObjectSetInteger(0, sparam, OBJPROP_STATE, false);
         ChartRedraw();
      }
   }
}

//+------------------------------------------------------------------+
//| Timer & Calculate                                                |
//+------------------------------------------------------------------+
void OnTimer()
{
   if(!g_isDragging)
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
   if(!g_isDragging)
      UpdateHUD();
   return(rates_total);
}
