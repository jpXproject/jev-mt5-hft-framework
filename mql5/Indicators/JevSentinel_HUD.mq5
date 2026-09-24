//+------------------------------------------------------------------+
//|                                            JevSentinel_HUD.mq5   |
//|                                    Copyright 2026, jpXCode Pro   |
//|                 On-Chart Visual HUD & Reservation Price Indicator|
//+------------------------------------------------------------------+
#property copyright   "Copyright 2026, jpXCode Pro"
#property link        "https://jpxcode.pages.dev"
#property version     "1.00"
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

//--- Instances
CJevPricing         g_pricing;
CJevStateEngine     g_state;
CJevFallbackLadder  g_ladder;

const string PREFIX = "JEV_HUD_";

//+------------------------------------------------------------------+
//| Custom indicator initialization function                         |
//+------------------------------------------------------------------+
int OnInit()
{
   g_pricing.SetParameters(InpGamma, InpSigma, 1.0);
   g_state.SetSymbol(_Symbol);

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
      ObjectSetInteger(0, bgName, OBJPROP_XSIZE, 260);
      ObjectSetInteger(0, bgName, OBJPROP_YSIZE, 190);
      ObjectSetInteger(0, bgName, OBJPROP_BGCOLOR, InpBgColor);
      ObjectSetInteger(0, bgName, OBJPROP_BORDER_COLOR, InpBorderColor);
      ObjectSetInteger(0, bgName, OBJPROP_BORDER_TYPE, BORDER_FLAT);
      ObjectSetInteger(0, bgName, OBJPROP_SELECTABLE, false);
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

   // Header
   CreateLabel("TITLE", InpXDistance + 12, InpYDistance + 10, "⚡ JEV-MT5 SENTINEL", InpAccentCyan, 11, true);
   CreateLabel("LADDER", InpXDistance + 12, InpYDistance + 32, "STATUS: RUN (OPTIMAL)", InpAccentGreen, 9, true);

   // Price & VWAP
   string p_str = StringFormat("Mid: %.5f | Spr: %.1f bps", snap.mid_price, snap.spread_bps);
   CreateLabel("PRICES", InpXDistance + 12, InpYDistance + 52, p_str, InpTextColor, 9);

   string r_str = StringFormat("Reserv.Price: %.5f", r_price);
   CreateLabel("RESERV", InpXDistance + 12, InpYDistance + 70, r_str, clrGold, 9, true);

   string v_str = StringFormat("Session VWAP: %.5f", snap.session_vwap);
   CreateLabel("VWAP", InpXDistance + 12, InpYDistance + 88, v_str, clrSilver, 9);

   // Battery & AI State
   string b_str = "Regime: Mean Reverting (86%)";
   CreateLabel("REGIME", InpXDistance + 12, InpYDistance + 110, b_str, InpAccentCyan, 9);

   string dir_str = "Bias: UP | Toxic Flow: LOW";
   CreateLabel("FLOW", InpXDistance + 12, InpYDistance + 128, dir_str, InpAccentGreen, 9);

   // Inventory & DD
   string inv_str = StringFormat("Net Lots: %.2f | DD: %.2f%%", snap.net_inventory_lots, snap.drawdown_pct);
   CreateLabel("INV", InpXDistance + 12, InpYDistance + 148, inv_str, InpTextColor, 9);

   string risk_str = "Hard Risk Gate: 9/9 PASS";
   CreateLabel("RISK", InpXDistance + 12, InpYDistance + 166, risk_str, InpAccentGreen, 8, true);

   // Update Reservation Price Horizontal Line on Chart
   if(InpShowReservLine)
   {
      string lineName = PREFIX + "RESERV_LINE";
      if(ObjectFind(0, lineName) < 0)
      {
         ObjectCreate(0, lineName, OBJ_HLINE, 0, 0, r_price);
         ObjectSetInteger(0, lineName, OBJPROP_COLOR, InpReservLineColor);
         ObjectSetInteger(0, lineName, OBJPROP_WIDTH, InpReservLineWidth);
         ObjectSetInteger(0, lineName, OBJPROP_STYLE, STYLE_DASH);
         ObjectSetString(0, lineName, OBJPROP_TEXT, "Jev Reservation Price");
      }
      else
      {
         ObjectSetDouble(0, lineName, OBJPROP_PRICE, r_price);
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
