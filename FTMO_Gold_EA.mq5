//+------------------------------------------------------------------+
//|  FTMO Gold EA v2.1 – Multi-TF Trend + Quality Gates             |
//|  Symbol : XAUUSD (Gold)   Timeframe : M15                       |
//|  Strategy: H4 trend bias → M15 EMA alignment → RSI momentum     |
//|            ATR-based SL/TP, partial close at 1R, ATR trail      |
//|  v2.1 changes (Jan-26 optimisation):                            |
//|   - Fix: H4 EMA now reads shift=1 (closed candle, not forming)  |
//|   - RSI band widened to 72/28 to allow strong-trend entries     |
//|   - ATR SL mult raised 1.5→1.8 for higher Jan-26 volatility     |
//|   - ATR trail mult raised 1.2→1.5; BE start raised 0.7→0.8R    |
//|   - ADX floor lowered 20→18; body filter relaxed 35%→30%        |
//|   - Time stop extended 240→360 min; full-stack toggle added     |
//+------------------------------------------------------------------+
#property strict
#property version   "2.10"
#property description "FTMO Gold EA v2.1 | H4+M15 Multi-TF | Jan-26 Tuned | Partial Close | Session Filter"

#include <Trade/Trade.mqh>
CTrade trade;

//====================================================================
//  INPUTS
//====================================================================

input group "=== FTMO RISK MANAGEMENT ==="
input ulong  InpMagicNumber       = 26022026;
input double InpBaseRiskPercent   = 0.20;   // Risk per trade (%)
input int    InpMaxTradesPerDay   = 2;      // Hard cap on entries per day
input int    InpMaxConsecLosses   = 3;      // Halt day after N straight losses

input double InpMaxDailyLossPct   = 1.5;   // % of day-start equity
input double InpMaxTotalLossPct   = 4.0;   // % of initial equity (buffer below 5%)
input double InpMaxTrailDDPct     = 1.8;   // % from equity peak

// Drawdown-based risk scaling
input double InpDDReduceStartPct  = 0.50;  // Start reducing risk at this daily DD %
input double InpRiskMinPct        = 0.08;  // Floor risk when scaling down
input double InpRiskReduceMaxFrac = 0.75;  // Max fraction to cut from base risk

input group "=== TIMEFRAMES ==="
input ENUM_TIMEFRAMES InpHTF      = PERIOD_H4;   // Higher timeframe (trend bias)
input ENUM_TIMEFRAMES InpTF       = PERIOD_M15;  // Entry / management timeframe

input group "=== TREND INDICATORS ==="
// H4 EMAs – define the macro trend direction
input int InpHTF_Fast             = 21;
input int InpHTF_Slow             = 55;

// M15 EMAs – entry alignment
input int InpFastEMA              = 21;
input int InpSlowEMA              = 55;
input int InpTrendEMA             = 200;   // Structural bias on entry TF

input group "=== RSI MOMENTUM FILTER ==="
input int    InpRSIPeriod         = 14;
input double InpRSI_BuyMax        = 72.0;  // Block long entries above this  (was 68 – raised to allow strong-trend entries)
input double InpRSI_SellMin       = 28.0;  // Block short entries below this (was 32 – lowered to match)

input group "=== ATR / SL / TP ==="
input int    InpATRPeriod         = 14;
input double InpATR_SL_Mult       = 1.8;   // SL = entry ± ATR × mult  (was 1.5 – wider stops for Jan-26 volatility)
input double InpRR                = 1.8;   // TP = SL distance × RR
// Volatility gate (XAU points – tune per broker)
// NOTE: value = atr / _Point. For 3-decimal brokers (_Point=0.001) multiply by 10.
input double InpMinATR_Points     = 80.0;
input double InpMaxATR_Points     = 2500.0;

input group "=== TREND STRENGTH (ADX) ==="
input int    InpADXPeriod         = 14;
input double InpADXMin            = 18.0;  // (was 20 – slightly relaxed to reduce over-filtering in Jan-26)

input group "=== CANDLE BODY FILTER ==="
input bool   InpBodyFilter        = true;   // Require directional candle
input double InpBodyMinPct        = 0.30;   // Min body / total range ratio  (was 0.35 – relaxed for high-wick Jan-26 candles)

input group "=== SESSION FILTER (Server Time) ==="
input bool InpUseSessionFilter    = true;
input int  InpSessionStartHour    = 7;      // 07:00 – London open
input int  InpSessionEndHour      = 21;     // 21:00 – NY close

input group "=== ENTRY FILTERS ==="
// Full-stack: requires slow EMA > trend EMA (55 > 200) for entry.
// Set false to allow earlier entries – price above trend EMA is sufficient.
input bool   InpRequireFullStack  = false;  // false = relaxed M15 stack (catches earlier trend entries)

input group "=== TRADE MANAGEMENT ==="
// Partial close
input bool   InpUsePartialClose   = true;
input double InpPartialR          = 1.0;    // Close partial at this R multiple
input double InpPartialPct        = 50.0;   // % of position to close

// Break-even
input bool   InpUseBreakEven      = true;
input double InpBE_StartR         = 0.8;    // Move SL to BE when trade reaches this R  (was 0.7 – later trigger prevents early BE whipsaw)
input double InpBE_OffsetPoints   = 15.0;   // Lock tiny profit (points beyond entry)

// ATR trailing stop
input bool   InpUseATRTrail       = true;
input double InpTrailATRMult      = 1.5;    // (was 1.2 – wider trail gives winning trades more room)
input double InpTrailStartR       = 1.0;    // Begin trailing at 1R

// Time stop
input bool InpUseTimeStop         = true;
input int  InpMaxMinutesInTrade   = 360;    // Exit flat/losing trade after N minutes  (was 240 – gold trends can take longer)

input group "=== EXECUTION ==="
input int  InpMaxSpreadPoints     = 250;   // Live XAUUSD spread is typically 150-300 pts
input int  InpSlippagePoints      = 30;
input bool InpNewBarOnly          = true;
input bool InpDebugPrint          = true;  // Print filter status to Experts tab every 60s

//====================================================================
//  INDICATOR HANDLES
//====================================================================
int hHTF_Fast = INVALID_HANDLE;
int hHTF_Slow = INVALID_HANDLE;
int hFast     = INVALID_HANDLE;
int hSlow     = INVALID_HANDLE;
int hTrend    = INVALID_HANDLE;
int hATR      = INVALID_HANDLE;
int hADX      = INVALID_HANDLE;
int hRSI      = INVALID_HANDLE;

//====================================================================
//  GLOBAL STATE
//====================================================================
double   g_initialEquity   = 0.0;
double   g_dayStartEquity  = 0.0;
double   g_equityPeak      = 0.0;

datetime g_dayStamp        = 0;
int      g_tradesToday     = 0;

bool     g_haltDay         = false;
bool     g_haltTotal       = false;
bool     g_haltTrail       = false;

datetime g_lastBarTime     = 0;

// Consecutive loss tracking
ulong    g_lastClosedDeal  = 0;
int      g_consecLosses    = 0;

// Partial-close tracking (per open position)
ulong    g_partialDoneTicket = 0;   // Ticket for which partial close was done

//====================================================================
//  UTILITY: copy one value from an indicator buffer
//====================================================================
bool Copy1(int handle, int buffer, int shift, double &out)
{
   if(handle == INVALID_HANDLE) return false;
   if(BarsCalculated(handle) <= shift) return false;
   double arr[];
   ArraySetAsSeries(arr, true);
   if(CopyBuffer(handle, buffer, shift, 1, arr) != 1) return false;
   out = arr[0];
   return true;
}

//====================================================================
//  UTILITY: spread in points
//====================================================================
int SpreadPoints()
{
   return (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
}

//====================================================================
//  UTILITY: truncate datetime to day boundary
//====================================================================
datetime DayStamp(datetime t)
{
   MqlDateTime s;
   TimeToStruct(t, s);
   s.hour = 0; s.min = 0; s.sec = 0;
   return StructToTime(s);
}

//====================================================================
//  Reset per-day counters when a new trading day starts
//====================================================================
void ResetDailyIfNeeded()
{
   datetime ds = DayStamp(TimeCurrent());
   if(ds == g_dayStamp) return;

   g_dayStamp       = ds;
   g_dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   g_tradesToday    = 0;
   g_consecLosses   = 0;
   g_haltDay        = false;
   g_lastClosedDeal = 0;
}

//====================================================================
//  Keep equity peak up to date
//====================================================================
void UpdateEquityPeak()
{
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   if(eq > g_equityPeak) g_equityPeak = eq;
}

//====================================================================
//  Scan closed deals and update consecutive-loss counter
//====================================================================
void UpdateConsecLossesFromHistory()
{
   datetime toTime   = TimeCurrent();
   datetime fromTime = toTime - 60 * 60 * 24 * 30;

   if(!HistorySelect(fromTime, toTime)) return;

   int deals = HistoryDealsTotal();
   if(deals <= 0) return;

   for(int i = deals - 1; i >= 0; i--)
   {
      ulong dk = HistoryDealGetTicket(i);
      if(dk == 0) continue;
      if(dk == g_lastClosedDeal) break;  // Already processed

      if((string)HistoryDealGetString(dk, DEAL_SYMBOL) != _Symbol) continue;
      if((ulong)HistoryDealGetInteger(dk, DEAL_MAGIC)  != InpMagicNumber) continue;
      if((long)HistoryDealGetInteger(dk, DEAL_ENTRY)   != DEAL_ENTRY_OUT) continue;

      double profit = HistoryDealGetDouble(dk, DEAL_PROFIT);
      if(profit < 0.0) g_consecLosses++;
      else             g_consecLosses = 0;

      g_lastClosedDeal = dk;
      break;
   }
}

//====================================================================
//  Normalize lot size to broker rules
//====================================================================
double NormalizeLots(double lots)
{
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step    = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(step <= 0.0) step = 0.01;

   lots = MathMax(minLot, MathMin(maxLot, lots));
   lots = MathFloor(lots / step) * step;
   return NormalizeDouble(lots, 2);
}

//====================================================================
//  Dynamic risk % based on current daily drawdown
//====================================================================
double EffectiveRiskPct()
{
   if(g_dayStartEquity <= 0.0) return InpBaseRiskPercent;

   double eq    = AccountInfoDouble(ACCOUNT_EQUITY);
   double ddPct = (g_dayStartEquity - eq) / g_dayStartEquity * 100.0;

   if(ddPct <= InpDDReduceStartPct) return InpBaseRiskPercent;

   double range = MathMax(0.01, InpMaxDailyLossPct - InpDDReduceStartPct);
   double k     = MathMax(0.0, MathMin(1.0, (ddPct - InpDDReduceStartPct) / range));

   return MathMax(InpRiskMinPct, InpBaseRiskPercent * (1.0 - InpRiskReduceMaxFrac * k));
}

//====================================================================
//  Calculate lot size from risk money and SL distance
//====================================================================
double LotsByRisk(double entryPrice, double slPrice)
{
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(equity <= 0.0) return 0.0;

   double riskMoney = equity * (EffectiveRiskPct() / 100.0);

   double tickVal  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickVal <= 0.0 || tickSize <= 0.0) return 0.0;

   double dist = MathAbs(entryPrice - slPrice);
   if(dist <= 0.0) return 0.0;

   double lossPerLot = (dist / tickSize) * tickVal;
   if(lossPerLot <= 0.0) return 0.0;

   return NormalizeLots(riskMoney / lossPerLot);
}

//====================================================================
//  Position helpers
//====================================================================
bool HaveOurPosition(ulong &ticket, long &type, double &entry,
                     double &sl, double &tp, datetime &openTime, double &lots)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(!PositionSelectByTicket(t)) continue;
      if(PositionGetString(POSITION_SYMBOL)   != _Symbol)        continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;

      ticket   = t;
      type     = PositionGetInteger(POSITION_TYPE);
      entry    = PositionGetDouble(POSITION_PRICE_OPEN);
      sl       = PositionGetDouble(POSITION_SL);
      tp       = PositionGetDouble(POSITION_TP);
      openTime = (datetime)PositionGetInteger(POSITION_TIME);
      lots     = PositionGetDouble(POSITION_VOLUME);
      return true;
   }
   return false;
}

bool AnyOurPosition()
{
   ulong t; long ty; double e,s,tp,l; datetime ot;
   return HaveOurPosition(t,ty,e,s,tp,ot,l);
}

//====================================================================
//  Current R-multiple for open position
//====================================================================
double CurrentR(long posType, double entry, double sl)
{
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(bid <= 0.0 || ask <= 0.0) return 0.0;

   bool   isBuy = (posType == POSITION_TYPE_BUY);
   double price = isBuy ? bid : ask;
   double risk  = isBuy ? (entry - sl) : (sl - entry);
   if(risk <= 0.0) return 0.0;

   double profit = isBuy ? (price - entry) : (entry - price);
   return profit / risk;
}

//====================================================================
//  New-bar detector
//====================================================================
bool IsNewBar()
{
   datetime t0 = iTime(_Symbol, InpTF, 0);
   if(t0 == 0) return false;
   if(t0 != g_lastBarTime) { g_lastBarTime = t0; return true; }
   return false;
}

//====================================================================
//  Session filter – server time
//====================================================================
bool InSession()
{
   if(!InpUseSessionFilter) return true;
   MqlDateTime s;
   TimeToStruct(TimeCurrent(), s);
   return (s.hour >= InpSessionStartHour && s.hour < InpSessionEndHour);
}

//====================================================================
//  Candle body confirmation (shift=1 → last closed candle on InpTF)
//====================================================================
bool BullishBody(int shift = 1)
{
   if(!InpBodyFilter) return true;
   double o = iOpen(_Symbol, InpTF, shift);
   double c = iClose(_Symbol, InpTF, shift);
   double h = iHigh(_Symbol, InpTF, shift);
   double l = iLow(_Symbol, InpTF, shift);
   double range = h - l;
   if(range <= 0.0) return false;
   return (c > o) && ((c - o) / range >= InpBodyMinPct);
}

bool BearishBody(int shift = 1)
{
   if(!InpBodyFilter) return true;
   double o = iOpen(_Symbol, InpTF, shift);
   double c = iClose(_Symbol, InpTF, shift);
   double h = iHigh(_Symbol, InpTF, shift);
   double l = iLow(_Symbol, InpTF, shift);
   double range = h - l;
   if(range <= 0.0) return false;
   return (c < o) && ((o - c) / range >= InpBodyMinPct);
}

//====================================================================
//  HARD DD GUARDS  (returns true = halt trading)
//====================================================================
void CloseAllPositions()
{
   trade.SetExpertMagicNumber((long)InpMagicNumber);
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(!PositionSelectByTicket(t)) continue;
      if(PositionGetString(POSITION_SYMBOL)        != _Symbol)        continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;
      trade.PositionClose(t);
   }
}

bool CheckHardDD()
{
   ResetDailyIfNeeded();
   UpdateEquityPeak();
   UpdateConsecLossesFromHistory();

   if(g_haltDay || g_haltTotal || g_haltTrail) return true;

   double eq = AccountInfoDouble(ACCOUNT_EQUITY);

   // Total drawdown from initial equity
   double totalDD = (g_initialEquity - eq) / g_initialEquity * 100.0;
   if(totalDD >= InpMaxTotalLossPct) { g_haltTotal = true; return true; }

   // Daily drawdown from day-start equity
   double dayDD = (g_dayStartEquity - eq) / g_dayStartEquity * 100.0;
   if(dayDD >= InpMaxDailyLossPct) { g_haltDay = true; return true; }

   // Trailing drawdown from peak
   double peakDD = (g_equityPeak - eq) / g_equityPeak * 100.0;
   if(peakDD >= InpMaxTrailDDPct) { g_haltTrail = true; return true; }

   if(g_consecLosses  >= InpMaxConsecLosses)  { g_haltDay = true; return true; }
   if(g_tradesToday   >= InpMaxTradesPerDay)              return true;

   return false;
}

//====================================================================
//  POSITION MANAGEMENT
//====================================================================
void ManageOpenPosition()
{
   ulong ticket; long type; double entry, sl, tp, lots; datetime openTime;
   if(!HaveOurPosition(ticket, type, entry, sl, tp, openTime, lots)) return;

   double atr;
   if(!Copy1(hATR, 0, 0, atr) || atr <= 0.0) return;

   double rNow = CurrentR(type, entry, sl);
   bool   isBuy = (type == POSITION_TYPE_BUY);
   double bid   = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask   = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double price = isBuy ? bid : ask;

   //--- Time stop: exit flat/losing positions
   if(InpUseTimeStop)
   {
      int mins = (int)((TimeCurrent() - openTime) / 60);
      if(mins >= InpMaxMinutesInTrade && rNow < 0.3)
      {
         trade.PositionClose(ticket);
         return;
      }
   }

   //--- Partial close at InpPartialR
   if(InpUsePartialClose && g_partialDoneTicket != ticket && rNow >= InpPartialR)
   {
      double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
      double closeLots = NormalizeLots(lots * InpPartialPct / 100.0);
      if(closeLots >= minLot && closeLots < lots)
      {
         if(trade.PositionClosePartial(ticket, closeLots))
            g_partialDoneTicket = ticket;
      }
   }

   //--- Break-even
   if(InpUseBreakEven && rNow >= InpBE_StartR)
   {
      double be = isBuy ? (entry + InpBE_OffsetPoints * _Point)
                        : (entry - InpBE_OffsetPoints * _Point);
      be = NormalizeDouble(be, _Digits);

      if(isBuy  && be > sl) trade.PositionModify(ticket, be, tp);
      if(!isBuy && be < sl) trade.PositionModify(ticket, be, tp);
   }

   //--- ATR trailing stop
   if(InpUseATRTrail && rNow >= InpTrailStartR)
   {
      double newSL = isBuy ? (price - atr * InpTrailATRMult)
                           : (price + atr * InpTrailATRMult);
      newSL = NormalizeDouble(newSL, _Digits);

      if(isBuy  && newSL > sl) trade.PositionModify(ticket, newSL, tp);
      if(!isBuy && newSL < sl) trade.PositionModify(ticket, newSL, tp);
   }
}

//====================================================================
//  ENTRY EXECUTION
//====================================================================
bool ExecuteTrade(ENUM_ORDER_TYPE orderType, double atr)
{
   bool   isBuy  = (orderType == ORDER_TYPE_BUY);
   double bid    = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask    = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double entry  = isBuy ? ask : bid;

   double slDist = atr * InpATR_SL_Mult;
   double sl     = isBuy ? (entry - slDist) : (entry + slDist);
   double tp     = isBuy ? (entry + slDist * InpRR) : (entry - slDist * InpRR);
   sl = NormalizeDouble(sl, _Digits);
   tp = NormalizeDouble(tp, _Digits);

   double lots = LotsByRisk(entry, sl);
   if(lots <= 0.0) return false;

   trade.SetExpertMagicNumber((long)InpMagicNumber);
   trade.SetDeviationInPoints(InpSlippagePoints);

   bool ok = isBuy ? trade.Buy (lots, _Symbol, 0.0, sl, tp, "FTMO_GOLD_BUY")
                   : trade.Sell(lots, _Symbol, 0.0, sl, tp, "FTMO_GOLD_SELL");

   if(ok)
   {
      g_tradesToday++;
      g_partialDoneTicket = 0;  // Reset for new position
   }
   return ok;
}

//====================================================================
//  INIT / DEINIT
//====================================================================
int OnInit()
{
   g_initialEquity  = AccountInfoDouble(ACCOUNT_EQUITY);
   g_dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   g_equityPeak     = AccountInfoDouble(ACCOUNT_EQUITY);
   g_dayStamp       = DayStamp(TimeCurrent());
   g_lastBarTime    = iTime(_Symbol, InpTF, 0);

   // Higher timeframe EMAs
   hHTF_Fast = iMA(_Symbol, InpHTF, InpHTF_Fast, 0, MODE_EMA, PRICE_CLOSE);
   hHTF_Slow = iMA(_Symbol, InpHTF, InpHTF_Slow, 0, MODE_EMA, PRICE_CLOSE);

   // Entry timeframe EMAs
   hFast  = iMA(_Symbol, InpTF, InpFastEMA,  0, MODE_EMA, PRICE_CLOSE);
   hSlow  = iMA(_Symbol, InpTF, InpSlowEMA,  0, MODE_EMA, PRICE_CLOSE);
   hTrend = iMA(_Symbol, InpTF, InpTrendEMA, 0, MODE_EMA, PRICE_CLOSE);

   // Volatility / momentum
   hATR = iATR(_Symbol, InpTF, InpATRPeriod);
   hADX = iADX(_Symbol, InpTF, InpADXPeriod);
   hRSI = iRSI(_Symbol, InpTF, InpRSIPeriod, PRICE_CLOSE);

   if(hHTF_Fast == INVALID_HANDLE || hHTF_Slow == INVALID_HANDLE ||
      hFast     == INVALID_HANDLE || hSlow     == INVALID_HANDLE ||
      hTrend    == INVALID_HANDLE || hATR      == INVALID_HANDLE ||
      hADX      == INVALID_HANDLE || hRSI      == INVALID_HANDLE)
   {
      Print("Indicator init failed – check symbol/TF");
      return INIT_FAILED;
   }

   Print("FTMO Gold EA v2 initialised | Equity: ", g_initialEquity);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   int handles[] = {hHTF_Fast, hHTF_Slow, hFast, hSlow, hTrend, hATR, hADX, hRSI};
   for(int i = 0; i < ArraySize(handles); i++)
      if(handles[i] != INVALID_HANDLE) IndicatorRelease(handles[i]);
}

//====================================================================
//  MAIN TICK
//====================================================================
void OnTick()
{
   //--- Diagnostics: print filter status to Experts tab once per minute
   if(InpDebugPrint)
   {
      static datetime _lastPrint = 0;
      if(TimeCurrent() - _lastPrint >= 60)
      {
         _lastPrint = TimeCurrent();
         double _a = 0, _d = 0, _r = 0;
         Copy1(hATR, 0, 1, _a);
         Copy1(hADX, 0, 1, _d);
         Copy1(hRSI, 0, 1, _r);
         PrintFormat("[DIAG] Spread=%d | ATR_pts=%.1f | ADX=%.2f | RSI=%.2f | HaltDay=%s | HaltTotal=%s | HaltTrail=%s | Trades=%d/%d | Session=%s",
            SpreadPoints(), (_Point > 0 ? _a / _Point : 0), _d, _r,
            g_haltDay  ? "Y" : "N",
            g_haltTotal? "Y" : "N",
            g_haltTrail? "Y" : "N",
            g_tradesToday, InpMaxTradesPerDay,
            InSession() ? "Y" : "N");
      }
   }

   //--- FTMO safety first
   if(CheckHardDD())
   {
      CloseAllPositions();
      return;
   }

   //--- Spread gate
   if(SpreadPoints() > InpMaxSpreadPoints) return;

   //--- New-bar gate
   if(InpNewBarOnly && !IsNewBar()) return;

   //--- Manage any open position (trailing, BE, partial close, time stop)
   ManageOpenPosition();

   //--- Only look for new entry when flat
   if(AnyOurPosition()) return;

   //--- Session gate
   if(!InSession()) return;

   //=== INDICATORS (use last closed candle → shift 1 on entry TF) ===

   // H4 trend EMAs – use shift=1 (last *closed* H4 candle) so bias is stable
   // (shift=0 reads the still-forming candle whose EMA value changes every tick)
   double htfFast, htfSlow;
   if(!Copy1(hHTF_Fast, 0, 1, htfFast)) return;
   if(!Copy1(hHTF_Slow, 0, 1, htfSlow)) return;

   // M15 EMAs
   double fast, slow, trend;
   if(!Copy1(hFast,  0, 1, fast))  return;
   if(!Copy1(hSlow,  0, 1, slow))  return;
   if(!Copy1(hTrend, 0, 1, trend)) return;

   // ATR, ADX, RSI
   double atr, adx, rsi;
   if(!Copy1(hATR, 0, 1, atr)) return;
   if(!Copy1(hADX, 0, 1, adx)) return;   // buffer 0 = ADX line
   if(!Copy1(hRSI, 0, 1, rsi)) return;

   //=== QUALITY GATES ===

   // Volatility gate
   double atrPts = atr / _Point;
   if(atrPts < InpMinATR_Points || atrPts > InpMaxATR_Points) return;

   // Trend strength gate
   if(adx < InpADXMin) return;

   // Current bid for direction check
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(bid <= 0.0) return;

   //=== ENTRY LOGIC ===
   //
   // LONG conditions:
   //   1. H4 bullish (closed candle): htfFast > htfSlow
   //   2. M15 aligned: InpRequireFullStack=true  → bid > fast > slow > trend
   //                   InpRequireFullStack=false → bid > fast > slow  AND  bid > trend
   //   3. RSI not overbought: rsi < InpRSI_BuyMax  (72 – allows strong-trend entries)
   //   4. Bullish confirmation candle (body ≥ 30% of range)
   //
   // SHORT conditions: mirror image
   //

   bool h4Bull = (htfFast > htfSlow);
   bool h4Bear = (htfFast < htfSlow);

   // Full-stack: bid > fast > slow > trend  (strict – requires 55 EMA above 200 EMA)
   // Relaxed:   bid > fast > slow  AND  bid > trend  (price confirms structural bias;
   //            allows earlier entries before the 55 crosses the 200)
   bool m15Bull = InpRequireFullStack
                  ? (bid > fast && fast > slow && slow > trend)
                  : (bid > fast && fast > slow && bid > trend);
   bool m15Bear = InpRequireFullStack
                  ? (bid < fast && fast < slow && slow < trend)
                  : (bid < fast && fast < slow && bid < trend);

   if(h4Bull && m15Bull && rsi < InpRSI_BuyMax  && BullishBody())
      ExecuteTrade(ORDER_TYPE_BUY,  atr);
   else if(h4Bear && m15Bear && rsi > InpRSI_SellMin && BearishBody())
      ExecuteTrade(ORDER_TYPE_SELL, atr);
}
