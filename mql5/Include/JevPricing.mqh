//+------------------------------------------------------------------+
//|                                                   JevPricing.mqh |
//|                                    Copyright 2026, jpXCode Pro   |
//|                 Avellaneda-Stoikov Reservation Pricing for MT5   |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, jpXCode Pro"
#property link      "https://jpxcode.pages.dev"
#property version   "1.00"
#property strict

class CJevPricing
{
private:
   double m_gamma;        // Risk aversion parameter (e.g. 0.1)
   double m_sigma;        // Volatility parameter
   double m_time_horizon; // Remaining normalized session time (e.g. 1.0 down to 0.0)

public:
   CJevPricing(void) : m_gamma(0.1), m_sigma(0.01), m_time_horizon(1.0) {}

   void SetParameters(double gamma, double sigma, double time_horizon)
   {
      m_gamma        = gamma;
      m_sigma        = sigma;
      m_time_horizon = (time_horizon > 0.0) ? time_horizon : 0.01;
   }

   // Avellaneda-Stoikov Reservation Price: r(s, q, t) = s - q * gamma * sigma^2 * (T - t)
   double CalculateReservationPrice(const double mid_price, const double net_inventory_lots)
   {
      double variance = m_sigma * m_sigma;
      double skew     = net_inventory_lots * m_gamma * variance * m_time_horizon;
      double r_price  = mid_price - skew;
      return r_price;
   }

   // Optimal Half-Spread calculation
   double CalculateOptimalHalfSpread(const double kappa)
   {
      if(kappa <= 0.0) return 0.0;
      double half_spread = (1.0 / m_gamma) * MathLog(1.0 + (m_gamma / kappa));
      return half_spread;
   }
};
