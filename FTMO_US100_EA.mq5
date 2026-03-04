//+------------------------------------------------------------------+
//|  FTMO US100 EA v1.0 – Trend-Pullback to EMA                     |
//|  Symbol : US100 / NAS100 / USTEC    Timeframe : M15             |
//|  Strategy: H1 EMA stack bias → M15 pullback to EMA(21)          |
//|            RSI zone filter, ADX strength gate, ATR SL/TP        |
//|  Risk   : 0.15 % per trade | Daily DD hard halt at 1.8 %        |
//|  Target : ≥ 80 % win rate   Daily DD never exceeds 2 %          |
//+------------------------------------------------------------------+
//
//  STRATEGY OVERVIEW
//  -----------------
//  High win-rate comes from entering ONLY when two conditions align:
//    (A) Strong, established trend confirmed on H1 (EMA 20 > 50 > 200
//        for longs; inverse for shorts).
//    (B) Price has pulled back to the M15 EMA(21) "value zone".
//        Entry is triggered once the last closed M15 candle bounces
//        off that EMA with a directional body ≥ 35 % of its range.
//
//  Additional quality gates (all must pass before entry):
//    • ADX ≥ 22 on M15 – confirms active trend, not choppy sideways
//    • RSI between 35 and 65 at entry – momentum zone, not extreme
//    • Price within 0.6 × ATR of EMA(21) – true pullback, not far away
//    • Spread ≤ InpMaxSpreadPoints
//    • Session filter: US equity session (configurable, default 14:30-21:00 UTC)
//
//  Risk management layered defence for daily DD < 2 %:
//    1. Base risk 0.15 % per trade.
//    2. Risk scales down linearly once daily DD > 0.5 %.
//    3. Hard halt at 1.8 % daily DD (80 % of the 2 % limit).
//    4. Trailing equity-peak DD halt at 1.5 %.
//    5. Total account DD halt at 4 % (stays well under 5 % limit).
//    6. Max 2 entries per day; halt after 2 consecutive losses.
//    7. Break-even at 0.4 R – most losers become scratches.
//    8. Partial close 50 % at 0.8 R – locks profit early.
//    9. ATR trail begins at 1.0 R – lets winners run.
//   10. Time stop 3 h – exits flat/stagnant trades.
//
//+------------------------------------------------------------------+
#property strict
#property version   "1.00"
#property description "FTMO US100 EA | H1+M15 Pullback | 80 % WR Target | DD < 2 %"

#include <Trade/Trade.mqh>
CTrade trade;

//====================================================================
//  INPUTS
//====================================================================

input group "=== FTMO RISK MANAGEMENT ==="
input ulong  InpMagicNumber        = 10032026;
input double InpBaseRiskPercent    = 0.15;   // Base risk per trade (%)
input int    InpMaxTradesPerDay    = 2;       // Hard cap on entries per day
input int    InpMaxConsecLosses    = 2;       // Halt day after N straight losses

input double InpMaxDailyLossPct   = 1.80;   // Daily DD halt (% of day-start equity)
input double InpMaxTotalLossPct   = 4.00;   // Total DD halt (% of initial equity)
input double InpMaxTrailDDPct     = 1.50;   // Trailing DD halt (% from equity peak)

// Drawdown-based risk scaling
input double InpDDReduceStartPct  = 0.50;   // Start reducing risk at this daily DD %
input double InpRiskMinPct        = 0.06;   // Floor risk when scaling down
input double InpRiskReduceMaxFrac = 0.80;   // Max fraction cut from base risk at halt level

input group "=== TIMEFRAMES ==="
input ENUM_TIMEFRAMES InpHTF      = PERIOD_H1;   // Higher timeframe – trend bias
input ENUM_TIMEFRAMES InpTF       = PERIOD_M15;  // Entry and management timeframe

input group "=== TREND EMAs (both timeframes share same periods) ==="
// H1 EMA stack – macro trend direction
input int InpHTF_Fast             = 20;
input int InpHTF_Mid              = 50;
input int InpHTF_Slow             = 200;

// M15 pullback EMA – entry value zone
input int InpPullbackEMA          = 21;    // Price must be near this EMA to qualify
// M15 trend confirmation EMAs
input int InpM15_Fast             = 20;
input int InpM15_Slow             = 50;

input group "=== PULLBACK ZONE FILTER ==="
// Entry is valid only when bid is within this many ATR multiples of EMA(21)
input double InpPullbackATRMult   = 0.60;  // Max distance from EMA(21) in ATR units

input group "=== RSI MOMENTUM FILTER ==="
input int    InpRSIPeriod         = 14;
input double InpRSI_LongMin       = 35.0;  // RSI must be above this for longs
input double InpRSI_LongMax       = 65.0;  // RSI must be below this for longs
input double InpRSI_ShortMin      = 35.0;  // RSI must be above this for shorts
input double InpRSI_ShortMax      = 65.0;  // RSI must be below this for shorts

input group "=== ATR / SL / TP ==="
input int    InpATRPeriod         = 14;
input double InpATR_SL_Mult       = 1.50;  // SL = entry ± ATR × mult
input double InpRR                = 1.50;  // TP = SL distance × RR
// Volatility gate (US100 index points, broker-dependent)
// US100 typical ATR on M15: 30-150 points. Tune per broker tick size.
input double InpMinATR_Points     = 5.0;   // Minimum ATR in points (raw)
input double InpMaxATR_Points     = 500.0; // Maximum ATR in points (raw)

input group "=== TREND STRENGTH (ADX) ==="
input int    InpADXPeriod         = 14;
input double InpADXMin            = 22.0;  // Minimum ADX to confirm trending market

input group "=== CANDLE BODY FILTER ==="
input bool   InpBodyFilter        = true;
input double InpBodyMinPct        = 0.35;  // Min body / total range ratio

input group "=== SESSION FILTER (UTC Server Time) ==="
input bool InpUseSessionFilter    = true;
input int  InpSessionStartHour    = 14;    // 14:30 UTC – US pre-market / cash open
input int  InpSessionStartMin     = 30;
input int  InpSessionEndHour      = 21;    // 21:00 UTC – US cash close
input int  InpSessionEndMin       = 0;

input group "=== TRADE MANAGEMENT ==="
// Break-even – converts many losers into scratches, boosting win rate
input bool   InpUseBreakEven      = true;
input double InpBE_StartR         = 0.40;  // Move SL to BE when trade reaches 0.4 R
input double InpBE_OffsetPoints   = 5.0;   // Lock this many points profit (above/below entry)

// Partial close – locks profit early, counts as win before full TP
input bool   InpUsePartialClose   = true;
input double InpPartialR          = 0.80;  // Partially close at 0.8 R
input double InpPartialPct        = 50.0;  // % of position to close

// ATR trailing stop
input bool   InpUseATRTrail       = true;
input double InpTrailATRMult      = 1.20;
input double InpTrailStartR       = 1.00;  // Begin trailing at 1 R

// Time stop
input bool InpUseTimeStop         = true;
input int  InpMaxMinutesInTrade   = 180;   // Exit stagnant/losing trade after 3 h

input group "=== EXECUTION ==="
input int  InpMaxSpreadPoints     = 30;    // US100 spread is typically 1-10 pts; 30 = safe buffer
input int  InpSlippagePoints      = 10;
input bool InpNewBarOnly          = true;
input bool InpDebugPrint          = true;  // Print filter diagnostics every 60 s

//====================================================================
//  INDICATOR HANDLES
//====================================================================
int hHTF_Fast  = INVALID_HANDLE;  // H1 EMA(20)
int hHTF_Mid   = INVALID_HANDLE;  // H1 EMA(50)
int hHTF_Slow  = INVALID_HANDLE;  // H1 EMA(200)

int hPB_EMA    = INVALID_HANDLE;  // M15 EMA(21)  – pullback value zone
int hM15_Fast  = INVALID_HANDLE;  // M15 EMA(20)  – trend confirmation
int hM15_Slow  = INVALID_HANDLE;  // M15 EMA(50)  – trend confirmation

int hATR       = INVALID_HANDLE;
int hADX       = INVALID_HANDLE;
int hRSI       = INVALID_HANDLE;

//====================================================================
//  GLOBAL STATE
//====================================================================
double   g_initialEquity    = 0.0;
double   g_dayStartEquity   = 0.0;
double   g_equityPeak       = 0.0;

datetime g_dayStamp         = 0;
int      g_tradesToday      = 0;

bool     g_haltDay          = false;
bool     g_haltTotal        = false;
bool     g_haltTrail        = false;

datetime g_lastBarTime      = 0;

ulong    g_lastClosedDeal   = 0;
int      g_consecLosses     = 0;

ulong    g_partialDoneTicket = 0;

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
//  UTILITY: truncate datetime to day boundary (midnight)
//====================================================================
datetime DayStamp(datetime t)
{
   MqlDateTime s;
   TimeToStruct(t, s);
   s.hour = 0; s.min = 0; s.sec = 0;
   return StructToTime(s);
}

//====================================================================
//  Reset per-day counters on new calendar day
//====================================================================
void ResetDailyIfNeeded()
{
   datetime ds = DayStamp(TimeCurrent());
   if(ds == g_dayStamp) return;

   g_dayStamp        = ds;
   g_dayStartEquity  = AccountInfoDouble(ACCOUNT_EQUITY);
   g_tradesToday     = 0;
   g_consecLosses    = 0;
   g_haltDay         = false;
   g_lastClosedDeal  = 0;

   if(InpDebugPrint)
      PrintFormat("[US100 EA] New day – day-start equity: %.2f", g_dayStartEquity);
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
   datetime fromTime = toTime - 60 * 60 * 24 * 7;   // look back 1 week

   if(!HistorySelect(fromTime, toTime)) return;

   int deals = HistoryDealsTotal();
   if(deals <= 0) return;

   for(int i = deals - 1; i >= 0; i--)
   {
      ulong dk = HistoryDealGetTicket(i);
      if(dk == 0) continue;
      if(dk == g_lastClosedDeal) break;

      if((string)HistoryDealGetString(dk, DEAL_SYMBOL)   != _Symbol)        continue;
      if((ulong)HistoryDealGetInteger(dk, DEAL_MAGIC)    != InpMagicNumber) continue;
      if((long)HistoryDealGetInteger(dk, DEAL_ENTRY)     != DEAL_ENTRY_OUT) continue;

      double profit = HistoryDealGetDouble(dk, DEAL_PROFIT)
                    + HistoryDealGetDouble(dk, DEAL_SWAP)
                    + HistoryDealGetDouble(dk, DEAL_COMMISSION);

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
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(step <= 0.0) step = 0.01;

   lots = MathMax(minLot, MathMin(maxLot, lots));
   lots = MathFloor(lots / step) * step;
   return NormalizeDouble(lots, 2);
}

//====================================================================
//  Dynamic risk % – scales down as daily DD accumulates
//  Keeps actual risk well below the 2 % limit
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
      if(PositionGetString(POSITION_SYMBOL)          != _Symbol)        continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC)   != InpMagicNumber) continue;

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
   ulong t; long ty; double e, s, tp, l; datetime ot;
   return HaveOurPosition(t, ty, e, s, tp, ot, l);
}

//====================================================================
//  Current R-multiple for open position
//====================================================================
double CurrentR(long posType, double entry, double sl)
{
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(bid <= 0.0 || ask <= 0.0) return 0.0;

   bool   isBuy  = (posType == POSITION_TYPE_BUY);
   double price  = isBuy ? bid : ask;
   double risk   = isBuy ? (entry - sl) : (sl - entry);
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
//  Session filter – checks server UTC time
//====================================================================
bool InSession()
{
   if(!InpUseSessionFilter) return true;
   MqlDateTime s;
   TimeToStruct(TimeCurrent(), s);
   int nowMins = s.hour * 60 + s.min;
   int startMins = InpSessionStartHour * 60 + InpSessionStartMin;
   int endMins   = InpSessionEndHour   * 60 + InpSessionEndMin;
   return (nowMins >= startMins && nowMins < endMins);
}

//====================================================================
//  Candle body filter (shift = 1 → last closed M15 candle)
//====================================================================
bool BullishBody(int shift = 1)
{
   if(!InpBodyFilter) return true;
   double o = iOpen (_Symbol, InpTF, shift);
   double c = iClose(_Symbol, InpTF, shift);
   double h = iHigh (_Symbol, InpTF, shift);
   double l = iLow  (_Symbol, InpTF, shift);
   double range = h - l;
   if(range <= 0.0) return false;
   return (c > o) && ((c - o) / range >= InpBodyMinPct);
}

bool BearishBody(int shift = 1)
{
   if(!InpBodyFilter) return true;
   double o = iOpen (_Symbol, InpTF, shift);
   double c = iClose(_Symbol, InpTF, shift);
   double h = iHigh (_Symbol, InpTF, shift);
   double l = iLow  (_Symbol, InpTF, shift);
   double range = h - l;
   if(range <= 0.0) return false;
   return (c < o) && ((o - c) / range >= InpBodyMinPct);
}

//====================================================================
//  PULLBACK ZONE CHECK
//  Returns true when last closed candle's close is within
//  InpPullbackATRMult × ATR of the M15 EMA(21).
//  This ensures we enter at value, not while price is extended.
//====================================================================
bool InPullbackZone(double pbEMA, double atr, bool isBullish)
{
   double close1 = iClose(_Symbol, InpTF, 1);
   if(close1 <= 0.0 || atr <= 0.0) return false;

   double dist = MathAbs(close1 - pbEMA);
   if(dist > InpPullbackATRMult * atr) return false;

   // For a bullish pullback: close must be at or slightly below EMA – then bounce
   // For a bearish pullback: close must be at or slightly above EMA – then bounce
   if(isBullish) return (close1 <= pbEMA + InpPullbackATRMult * atr);
   else          return (close1 >= pbEMA - InpPullbackATRMult * atr);
}

//====================================================================
//  CLOSE ALL POSITIONS (emergency DD halt)
//====================================================================
void CloseAllPositions()
{
   trade.SetExpertMagicNumber((long)InpMagicNumber);
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(!PositionSelectByTicket(t)) continue;
      if(PositionGetString(POSITION_SYMBOL)          != _Symbol)        continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC)   != InpMagicNumber) continue;
      trade.PositionClose(t);
   }
}

//====================================================================
//  HARD DD GUARDS – returns true when trading must be suspended
//====================================================================
bool CheckHardDD()
{
   ResetDailyIfNeeded();
   UpdateEquityPeak();
   UpdateConsecLossesFromHistory();

   if(g_haltDay || g_haltTotal || g_haltTrail) return true;

   double eq = AccountInfoDouble(ACCOUNT_EQUITY);

   // Total account drawdown
   double totalDD = (g_initialEquity > 0.0)
                     ? (g_initialEquity - eq) / g_initialEquity * 100.0 : 0.0;
   if(totalDD >= InpMaxTotalLossPct)
   {
      g_haltTotal = true;
      PrintFormat("[US100 EA] HALT – Total DD %.2f %% >= limit %.2f %%",
                  totalDD, InpMaxTotalLossPct);
      return true;
   }

   // Daily drawdown from day-start equity
   double dayDD = (g_dayStartEquity > 0.0)
                   ? (g_dayStartEquity - eq) / g_dayStartEquity * 100.0 : 0.0;
   if(dayDD >= InpMaxDailyLossPct)
   {
      g_haltDay = true;
      PrintFormat("[US100 EA] HALT – Daily DD %.2f %% >= limit %.2f %%",
                  dayDD, InpMaxDailyLossPct);
      return true;
   }

   // Trailing equity-peak drawdown
   double peakDD = (g_equityPeak > 0.0)
                    ? (g_equityPeak - eq) / g_equityPeak * 100.0 : 0.0;
   if(peakDD >= InpMaxTrailDDPct)
   {
      g_haltTrail = true;
      PrintFormat("[US100 EA] HALT – Trail DD %.2f %% >= limit %.2f %%",
                  peakDD, InpMaxTrailDDPct);
      return true;
   }

   if(g_consecLosses >= InpMaxConsecLosses)
   {
      g_haltDay = true;
      PrintFormat("[US100 EA] HALT – %d consecutive losses", g_consecLosses);
      return true;
   }

   if(g_tradesToday >= InpMaxTradesPerDay) return true;

   return false;
}

//====================================================================
//  POSITION MANAGEMENT – trailing stop, break-even, partial close
//====================================================================
void ManageOpenPosition()
{
   ulong ticket; long type; double entry, sl, tp, lots; datetime openTime;
   if(!HaveOurPosition(ticket, type, entry, sl, tp, openTime, lots)) return;

   double atr;
   if(!Copy1(hATR, 0, 0, atr) || atr <= 0.0) return;

   double rNow  = CurrentR(type, entry, sl);
   bool   isBuy = (type == POSITION_TYPE_BUY);
   double bid   = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask   = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double price = isBuy ? bid : ask;

   //--- Time stop: exit flat/losing positions after InpMaxMinutesInTrade
   if(InpUseTimeStop)
   {
      int mins = (int)((TimeCurrent() - openTime) / 60);
      if(mins >= InpMaxMinutesInTrade && rNow < 0.20)
      {
         PrintFormat("[US100 EA] Time stop – ticket %d | %d min | R=%.2f", ticket, mins, rNow);
         trade.PositionClose(ticket);
         return;
      }
   }

   //--- Partial close at InpPartialR
   if(InpUsePartialClose && g_partialDoneTicket != ticket && rNow >= InpPartialR)
   {
      double minLot    = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
      double closeLots = NormalizeLots(lots * InpPartialPct / 100.0);
      if(closeLots >= minLot && closeLots < lots)
      {
         if(trade.PositionClosePartial(ticket, closeLots))
         {
            g_partialDoneTicket = ticket;
            PrintFormat("[US100 EA] Partial close %.2f lots at %.2f R – ticket %d",
                        closeLots, rNow, ticket);
         }
      }
   }

   //--- Break-even: move SL to entry + tiny offset once 0.4 R reached
   if(InpUseBreakEven && rNow >= InpBE_StartR)
   {
      double be = isBuy ? (entry + InpBE_OffsetPoints * _Point)
                        : (entry - InpBE_OffsetPoints * _Point);
      be = NormalizeDouble(be, _Digits);

      if(isBuy  && be > sl) trade.PositionModify(ticket, be, tp);
      if(!isBuy && be < sl) trade.PositionModify(ticket, be, tp);
   }

   //--- ATR trailing stop: begins at InpTrailStartR
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
   if(lots <= 0.0)
   {
      Print("[US100 EA] LotsByRisk returned 0 – skipping entry");
      return false;
   }

   trade.SetExpertMagicNumber((long)InpMagicNumber);
   trade.SetDeviationInPoints(InpSlippagePoints);

   string comment = isBuy ? "US100_BUY" : "US100_SELL";
   bool ok = isBuy ? trade.Buy (lots, _Symbol, 0.0, sl, tp, comment)
                   : trade.Sell(lots, _Symbol, 0.0, sl, tp, comment);

   if(ok)
   {
      g_tradesToday++;
      g_partialDoneTicket = 0;
      PrintFormat("[US100 EA] %s %.2f lots | Entry=%.5f SL=%.5f TP=%.5f | Risk=%.2f %%",
                  comment, lots, entry, sl, tp, EffectiveRiskPct());
   }
   else
   {
      PrintFormat("[US100 EA] Order failed: %d – %s", GetLastError(), comment);
   }
   return ok;
}

//====================================================================
//  INIT
//====================================================================
int OnInit()
{
   g_initialEquity  = AccountInfoDouble(ACCOUNT_EQUITY);
   g_dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   g_equityPeak     = AccountInfoDouble(ACCOUNT_EQUITY);
   g_dayStamp       = DayStamp(TimeCurrent());
   g_lastBarTime    = iTime(_Symbol, InpTF, 0);

   // H1 EMA stack
   hHTF_Fast = iMA(_Symbol, InpHTF, InpHTF_Fast, 0, MODE_EMA, PRICE_CLOSE);
   hHTF_Mid  = iMA(_Symbol, InpHTF, InpHTF_Mid,  0, MODE_EMA, PRICE_CLOSE);
   hHTF_Slow = iMA(_Symbol, InpHTF, InpHTF_Slow, 0, MODE_EMA, PRICE_CLOSE);

   // M15 EMAs
   hPB_EMA   = iMA(_Symbol, InpTF, InpPullbackEMA, 0, MODE_EMA, PRICE_CLOSE);
   hM15_Fast = iMA(_Symbol, InpTF, InpM15_Fast,    0, MODE_EMA, PRICE_CLOSE);
   hM15_Slow = iMA(_Symbol, InpTF, InpM15_Slow,    0, MODE_EMA, PRICE_CLOSE);

   // Volatility / momentum
   hATR = iATR(_Symbol, InpTF, InpATRPeriod);
   hADX = iADX(_Symbol, InpTF, InpADXPeriod);
   hRSI = iRSI(_Symbol, InpTF, InpRSIPeriod, PRICE_CLOSE);

   bool allOk = (hHTF_Fast != INVALID_HANDLE && hHTF_Mid  != INVALID_HANDLE &&
                 hHTF_Slow != INVALID_HANDLE && hPB_EMA   != INVALID_HANDLE &&
                 hM15_Fast != INVALID_HANDLE && hM15_Slow != INVALID_HANDLE &&
                 hATR      != INVALID_HANDLE && hADX      != INVALID_HANDLE &&
                 hRSI      != INVALID_HANDLE);

   if(!allOk)
   {
      Print("[US100 EA] ERROR – one or more indicator handles invalid. Check symbol/TF.");
      return INIT_FAILED;
   }

   PrintFormat("[US100 EA] v1.0 initialised | Symbol=%s | Equity=%.2f | Base risk=%.2f %%",
               _Symbol, g_initialEquity, InpBaseRiskPercent);
   return INIT_SUCCEEDED;
}

//====================================================================
//  DEINIT
//====================================================================
void OnDeinit(const int reason)
{
   int handles[] = {hHTF_Fast, hHTF_Mid, hHTF_Slow,
                    hPB_EMA,  hM15_Fast, hM15_Slow,
                    hATR, hADX, hRSI};
   for(int i = 0; i < ArraySize(handles); i++)
      if(handles[i] != INVALID_HANDLE) IndicatorRelease(handles[i]);
}

//====================================================================
//  MAIN TICK
//====================================================================
void OnTick()
{
   //--- Diagnostics: print filter status once per minute
   if(InpDebugPrint)
   {
      static datetime _lastPrint = 0;
      if(TimeCurrent() - _lastPrint >= 60)
      {
         _lastPrint = TimeCurrent();
         double _a = 0, _d = 0, _r = 0, _pb = 0;
         Copy1(hATR,    0, 1, _a);
         Copy1(hADX,    0, 1, _d);
         Copy1(hRSI,    0, 1, _r);
         Copy1(hPB_EMA, 0, 1, _pb);
         double eq = AccountInfoDouble(ACCOUNT_EQUITY);
         double dayDD = (g_dayStartEquity > 0.0)
                         ? (g_dayStartEquity - eq) / g_dayStartEquity * 100.0 : 0.0;
         PrintFormat("[DIAG] Spread=%d | ATR_pts=%.2f | ADX=%.2f | RSI=%.2f | PB_EMA=%.2f | "
                     "DayDD=%.3f %% | RiskPct=%.3f %% | Halt(D/T/Tr)=%s/%s/%s | "
                     "Trades=%d/%d | Session=%s",
                     SpreadPoints(), (_Point > 0 ? _a / _Point : 0),
                     _d, _r, _pb, dayDD, EffectiveRiskPct(),
                     g_haltDay   ? "Y" : "N",
                     g_haltTotal ? "Y" : "N",
                     g_haltTrail ? "Y" : "N",
                     g_tradesToday, InpMaxTradesPerDay,
                     InSession() ? "Y" : "N");
      }
   }

   //--- FTMO safety layer first
   if(CheckHardDD())
   {
      CloseAllPositions();
      return;
   }

   //--- Spread gate
   if(SpreadPoints() > InpMaxSpreadPoints) return;

   //--- New-bar gate (entry decisions only on bar close)
   if(InpNewBarOnly && !IsNewBar()) return;

   //--- Manage any open position on every new bar
   ManageOpenPosition();

   //--- Only look for new entry when flat
   if(AnyOurPosition()) return;

   //--- Session gate
   if(!InSession()) return;

   //=================================================================
   //  READ INDICATORS
   //  Shift 0 on H1 = current H1 bar (stable enough for trend bias)
   //  Shift 1 on M15 = last fully closed M15 candle (confirmed data)
   //=================================================================

   // H1 EMA stack – trend bias
   double h1Fast, h1Mid, h1Slow;
   if(!Copy1(hHTF_Fast, 0, 0, h1Fast)) return;
   if(!Copy1(hHTF_Mid,  0, 0, h1Mid))  return;
   if(!Copy1(hHTF_Slow, 0, 0, h1Slow)) return;

   // M15 EMAs
   double pbEMA, m15Fast, m15Slow;
   if(!Copy1(hPB_EMA,   0, 1, pbEMA))   return;
   if(!Copy1(hM15_Fast, 0, 1, m15Fast)) return;
   if(!Copy1(hM15_Slow, 0, 1, m15Slow)) return;

   // ATR, ADX, RSI (M15 values from last closed candle)
   double atr, adx, rsi;
   if(!Copy1(hATR, 0, 1, atr)) return;
   if(!Copy1(hADX, 0, 1, adx)) return;   // buffer 0 = ADX line
   if(!Copy1(hRSI, 0, 1, rsi)) return;

   //=================================================================
   //  QUALITY GATES (all must pass – these are the win-rate filters)
   //=================================================================

   // 1. Volatility gate – ensures ATR is within tradeable range
   double atrPts = (_Point > 0.0) ? (atr / _Point) : atr;
   if(atrPts < InpMinATR_Points || atrPts > InpMaxATR_Points) return;

   // 2. Trend strength gate – ADX confirms directional momentum
   if(adx < InpADXMin) return;

   // Current price reference
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(bid <= 0.0) return;

   //=================================================================
   //  TREND CONDITIONS
   //
   //  H1 BULL: Full stack up  (EMA20 > EMA50 > EMA200, price > EMA50)
   //  H1 BEAR: Full stack down (EMA20 < EMA50 < EMA200, price < EMA50)
   //
   //  M15 alignment: fast > slow for bull, fast < slow for bear
   //  – ensures the entry timeframe trend agrees with the H1 bias
   //=================================================================
   bool h1Bull = (h1Fast > h1Mid  && h1Mid  > h1Slow && bid > h1Mid);
   bool h1Bear = (h1Fast < h1Mid  && h1Mid  < h1Slow && bid < h1Mid);

   bool m15Bull = (m15Fast > m15Slow);
   bool m15Bear = (m15Fast < m15Slow);

   //=================================================================
   //  PULLBACK CONDITIONS
   //
   //  For LONG: price pulled back to within InpPullbackATRMult × ATR
   //            of the M15 EMA(21), so we are entering at value.
   //            Last closed candle must be a bullish body (bounce).
   //
   //  For SHORT: mirror image.
   //
   //  RSI must be in the 35-65 zone to avoid chasing overextended moves.
   //=================================================================
   bool pullbackLong  = InPullbackZone(pbEMA, atr, true)  && BullishBody(1);
   bool pullbackShort = InPullbackZone(pbEMA, atr, false) && BearishBody(1);

   bool rsiLongOk  = (rsi >= InpRSI_LongMin  && rsi <= InpRSI_LongMax);
   bool rsiShortOk = (rsi >= InpRSI_ShortMin && rsi <= InpRSI_ShortMax);

   //=================================================================
   //  ENTRY LOGIC
   //
   //  LONG : H1 fully bullish stack + M15 bullish + pullback to EMA21
   //         + RSI in zone + ADX trending + bullish body candle
   //
   //  SHORT: mirror image
   //=================================================================
   if(h1Bull && m15Bull && pullbackLong && rsiLongOk)
      ExecuteTrade(ORDER_TYPE_BUY, atr);
   else if(h1Bear && m15Bear && pullbackShort && rsiShortOk)
      ExecuteTrade(ORDER_TYPE_SELL, atr);
}
//+------------------------------------------------------------------+
