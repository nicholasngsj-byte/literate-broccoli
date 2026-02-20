//+------------------------------------------------------------------+
//|                                              US100_Prop_EA.mq5  |
//|  Multi-timeframe trend + pullback entry, prop-safe risk controls |
//|  Version 5.0 – Backtest-driven fixes                            |
//|                                                                  |
//|  Fixes vs v4.0:                                                  |
//|   - CRITICAL: partial/BE/trail ticket was deal not position      |
//|   - CRITICAL: EOD forced close stops overnight Asian stop-outs   |
//|   - Dual-TF trend: H4 + H1 EMA50 slope must agree               |
//|   - H4 trend persistence: fast>slow for >= 3 bars                |
//|   - RSI filter: avoid overbought/oversold entries                |
//|   - ATR-based SL cap: SL can't be wider than 1.5×ATR            |
//|   - Minimum SL distance guard (no micro-stops)                   |
//|   - BreakEvenAtRR tightened to 0.80                              |
//|   - ADX minimum raised to 25                                     |
//+------------------------------------------------------------------+
#property strict
#property version   "5.0"
#property description "Prop US100 EA v5.0: dual-TF trend + RSI + EOD close + ATR SL cap"

//============================================================
//  INPUTS – Risk / Prop Controls
//============================================================
input ulong  MagicNumber           = 26022026;

input double RiskPerTradePct       = 0.40;   // % of balance risked per trade
input double DailyStopPct          = 1.20;   // halt if equity drops X% from day-start
input double TotalDrawdownPct      = 4.50;   // halt if equity drops X% from init balance
input double TrailingDDFromPeakPct = 2.50;   // halt if equity drops X% from equity peak
input int    MaxTradesPerDay       = 2;
input int    MaxConcurrentTrades   = 1;
input int    ConsecLossHalt        = 2;       // halt day after N consecutive losses

//============================================================
//  INPUTS – Execution
//============================================================
input int    MaxSpreadPoints       = 250;    // US100 spread ~150-200 pts
input int    SlippagePoints        = 50;
// Fill: 0=FOK, 1=IOC, 2=RETURN
input int    FillPolicy            = 2;      // ORDER_FILLING_RETURN (most CFD-compatible)

//============================================================
//  INPUTS – Session / EOD
//============================================================
input bool   UseSessionFilter      = true;
input int    SessionStartHour      = 14;     // 14:00 server ~ NY open (UTC+2 broker)
input int    SessionEndHour        = 20;     // stop new entries at 20:00
input int    ForceCloseHour        = 20;     // force-close all positions at 20:00 server
input bool   AvoidFridayClose      = true;   // no new entries Friday

//============================================================
//  INPUTS – Trend (H4 + H1 confirmation)
//============================================================
input int    H4_EMA_Fast           = 50;
input int    H4_EMA_Slow           = 200;
input int    H4_TrendPersistBars   = 3;      // fast>slow for at least N H4 bars
input int    H1_EMA_Slow           = 50;     // H1 trend slope confirmation

//============================================================
//  INPUTS – Entry
//============================================================
input int    H1_EMA_Pullback       = 20;
input int    EMA_Touch_Buffer_Pts  = 80;     // bar within N pts of EMA = pullback
input double DisplaceBodyMinPct    = 0.55;   // body/range >= this for signal candle

// RSI filter
input bool   UseRSIFilter          = true;
input int    RSI_Period            = 14;
input double RSI_BuyMin            = 40.0;   // buy only if RSI in [40, 70]
input double RSI_BuyMax            = 70.0;
input double RSI_SellMin           = 30.0;   // sell only if RSI in [30, 60]
input double RSI_SellMax           = 60.0;

// ADX filter
input bool   UseADXFilter          = true;
input int    ADX_Period            = 14;
input double ADX_MinLevel          = 25.0;

//============================================================
//  INPUTS – Stop / TP
//============================================================
input int    SwingLookbackBars     = 15;
input int    SL_Buffer_Points      = 60;
input double ATRSLCapMult          = 1.50;   // SL capped at entry ± mult×ATR_H1
input int    MinSL_Points          = 50;     // reject if SL < this from entry
input double RR_TP                 = 2.0;

//============================================================
//  INPUTS – Trade Management
//============================================================
input bool   UsePartialClose       = true;
input double PartialClosePct       = 0.50;   // close 50% at 1R

input bool   UseBreakEven          = true;
input double BreakEvenAtRR         = 0.80;   // trigger BE at 0.8R
input int    BE_Buffer_Points      = 10;

input bool   UseATRTrail           = true;
input int    ATRTrail_Period       = 14;
input double ATRTrail_Mult         = 1.50;   // trail at 1.5×ATR_H1 (after BE)

//============================================================
//  INPUTS – ATR Regime Filter
//============================================================
input bool   UseATRRegimeFilter    = true;
input int    ATR_Period            = 14;
input int    ATR_Median_Lookback   = 1500;
input double ATR_RegimeMult        = 0.85;

//============================================================
//  Indicator handles
//============================================================
int g_h4FastHandle  = INVALID_HANDLE;
int g_h4SlowHandle  = INVALID_HANDLE;
int g_h1SlowHandle  = INVALID_HANDLE;   // H1 EMA50 for trend slope
int g_h1EMAHandle   = INVALID_HANDLE;   // H1 EMA20 for pullback
int g_h1ADXHandle   = INVALID_HANDLE;
int g_h1RSIHandle   = INVALID_HANDLE;
int g_h1ATRHandle   = INVALID_HANDLE;   // trailing + SL cap
int g_h4ATRHandle   = INVALID_HANDLE;   // regime filter

//============================================================
//  State
//============================================================
datetime g_lastH1BarTime     = 0;
datetime g_dayKey            = 0;
double   g_dayStartEquity    = 0.0;
double   g_initBalance       = 0.0;
double   g_equityPeak        = 0.0;
int      g_tradesToday       = 0;
int      g_consecLosses      = 0;
bool     g_haltedToday       = false;
bool     g_eodClosedToday    = false;   // so we only force-close once per day

struct PartialInfo {
   ulong ticket;       // position ticket (POSITION_IDENTIFIER)
   bool  partialDone;
   bool  beDone;
};
PartialInfo g_partials[];

//============================================================
//  Utility
//============================================================
double Median(double &arr[], int n)
{
   if(n <= 0) return 0.0;
   double tmp[];
   ArrayResize(tmp, n);
   for(int i = 0; i < n; i++) tmp[i] = arr[i];
   ArraySort(tmp);
   if((n % 2) == 1) return tmp[n / 2];
   return 0.5 * (tmp[n / 2 - 1] + tmp[n / 2]);
}

datetime DayKey(datetime t)
{
   MqlDateTime s; TimeToStruct(t, s);
   s.hour = 0; s.min = 0; s.sec = 0;
   return StructToTime(s);
}

ENUM_ORDER_TYPE_FILLING FillMode()
{
   switch(FillPolicy)
   {
      case 0:  return ORDER_FILLING_FOK;
      case 1:  return ORDER_FILLING_IOC;
      default: return ORDER_FILLING_RETURN;
   }
}

//------------------------------------------------------------
//  Daily reset
//------------------------------------------------------------
void UpdateDailyState()
{
   datetime dk = DayKey(TimeCurrent());
   if(dk != g_dayKey)
   {
      g_dayKey         = dk;
      g_dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
      g_tradesToday    = 0;
      g_consecLosses   = 0;
      g_haltedToday    = false;
      g_eodClosedToday = false;
   }
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   if(eq > g_equityPeak) g_equityPeak = eq;
}

//------------------------------------------------------------
//  Halt checks
//------------------------------------------------------------
bool DailyStopHit()
{
   if(g_dayStartEquity <= 0.0) return false;
   return ((g_dayStartEquity - AccountInfoDouble(ACCOUNT_EQUITY))
           / g_dayStartEquity * 100.0 >= DailyStopPct);
}
bool TotalDrawdownHit()
{
   if(g_initBalance <= 0.0) return false;
   return ((g_initBalance - AccountInfoDouble(ACCOUNT_EQUITY))
           / g_initBalance * 100.0 >= TotalDrawdownPct);
}
bool TrailingDDHit()
{
   if(g_equityPeak <= 0.0) return false;
   return ((g_equityPeak - AccountInfoDouble(ACCOUNT_EQUITY))
           / g_equityPeak * 100.0 >= TrailingDDFromPeakPct);
}
bool AnyHaltCondition()
{
   if(g_haltedToday) return true;
   if(DailyStopHit())   { g_haltedToday = true; Print("HALT: Daily stop");       return true; }
   if(TotalDrawdownHit()){ g_haltedToday = true; Print("HALT: Total DD");         return true; }
   if(TrailingDDHit())  { g_haltedToday = true; Print("HALT: Trailing DD peak"); return true; }
   if(g_consecLosses >= ConsecLossHalt)
                         { g_haltedToday = true; Print("HALT: Consec losses");    return true; }
   return false;
}

//------------------------------------------------------------
//  Close all EA positions
//------------------------------------------------------------
void CloseAllPositions(string reason = "")
{
   if(reason != "") Print("Force-close: ", reason);
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;

      MqlTradeRequest req; MqlTradeResult res;
      ZeroMemory(req); ZeroMemory(res);
      req.action       = TRADE_ACTION_DEAL;
      req.symbol       = _Symbol;
      req.position     = ticket;
      req.volume       = PositionGetDouble(POSITION_VOLUME);
      req.magic        = MagicNumber;
      req.deviation    = SlippagePoints;
      req.type_filling = FillMode();

      ENUM_POSITION_TYPE pt = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      if(pt == POSITION_TYPE_BUY)
      { req.type = ORDER_TYPE_SELL; req.price = SymbolInfoDouble(_Symbol, SYMBOL_BID); }
      else
      { req.type = ORDER_TYPE_BUY;  req.price = SymbolInfoDouble(_Symbol, SYMBOL_ASK); }
      OrderSend(req, res);
   }
}

//------------------------------------------------------------
//  Session
//------------------------------------------------------------
bool InSession()
{
   if(!UseSessionFilter) return true;
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   if(dt.day_of_week == 0 || dt.day_of_week == 6) return false;
   if(AvoidFridayClose && dt.day_of_week == 5)     return false;
   return (dt.hour >= SessionStartHour && dt.hour < SessionEndHour);
}

bool IsEOD()
{
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   return (dt.hour >= ForceCloseHour);
}

//------------------------------------------------------------
//  Spread
//------------------------------------------------------------
int CurrentSpreadPoints()
{
   long spr = 0;
   if(!SymbolInfoInteger(_Symbol, SYMBOL_SPREAD, spr)) return 999999;
   return (int)spr;
}

//------------------------------------------------------------
//  Position count
//------------------------------------------------------------
int PositionsByMagic()
{
   int cnt = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
         (ulong)PositionGetInteger(POSITION_MAGIC) == MagicNumber)
         cnt++;
   }
   return cnt;
}

//------------------------------------------------------------
//  ATR Regime Filter
//------------------------------------------------------------
bool PassATRRegimeFilter()
{
   if(!UseATRRegimeFilter) return true;
   if(g_h4ATRHandle == INVALID_HANDLE) return false;

   double atrBuf[];
   ArraySetAsSeries(atrBuf, true);
   int copied = CopyBuffer(g_h4ATRHandle, 0, 1, ATR_Median_Lookback, atrBuf);
   if(copied < ATR_Median_Lookback / 2) return false;

   double atr_now = atrBuf[0];
   double med     = Median(atrBuf, copied);
   if(med <= 0.0) return false;
   return (atr_now >= med * ATR_RegimeMult);
}

//------------------------------------------------------------
//  Buffer helper
//------------------------------------------------------------
bool GetBuf(int handle, int shift, double &out)
{
   if(handle == INVALID_HANDLE) return false;
   double buf[];
   ArraySetAsSeries(buf, true);
   if(CopyBuffer(handle, 0, shift, 1, buf) < 1) return false;
   out = buf[0];
   return true;
}

bool GetH1Bar(int shift, MqlRates &bar)
{
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   if(CopyRates(_Symbol, PERIOD_H1, shift, 1, rates) < 1) return false;
   bar = rates[0];
   return true;
}

bool NewH1Bar()
{
   MqlRates b;
   if(!GetH1Bar(0, b)) return false;
   if(g_lastH1BarTime == 0) { g_lastH1BarTime = b.time; return false; }
   if(b.time != g_lastH1BarTime) { g_lastH1BarTime = b.time; return true; }
   return false;
}

//------------------------------------------------------------
//  Trend: H4 + H1 dual-timeframe confirmation
//------------------------------------------------------------
int GetTrend()
{
   // H4 EMA fast vs slow
   double h4fast1 = 0, h4slow1 = 0;
   if(!GetBuf(g_h4FastHandle, 1, h4fast1)) return 0;
   if(!GetBuf(g_h4SlowHandle, 1, h4slow1)) return 0;

   int h4Dir = 0;
   if(h4fast1 > h4slow1) h4Dir = +1;
   else if(h4fast1 < h4slow1) h4Dir = -1;
   else return 0;

   // H4 trend persistence: fast must have been same side for N bars
   for(int b = 2; b <= H4_TrendPersistBars; b++)
   {
      double fastB = 0, slowB = 0;
      if(!GetBuf(g_h4FastHandle, b, fastB)) return 0;
      if(!GetBuf(g_h4SlowHandle, b, slowB)) return 0;
      int dirB = (fastB > slowB) ? +1 : (fastB < slowB) ? -1 : 0;
      if(dirB != h4Dir) return 0;   // not persistent
   }

   // H1 EMA50 slope confirmation (bar 1 vs bar 3, 2-bar delta)
   double h1slow1 = 0, h1slow3 = 0;
   if(!GetBuf(g_h1SlowHandle, 1, h1slow1)) return 0;
   if(!GetBuf(g_h1SlowHandle, 3, h1slow3)) return 0;
   int h1Dir = (h1slow1 > h1slow3) ? +1 : (h1slow1 < h1slow3) ? -1 : 0;
   if(h1Dir != h4Dir) return 0;   // H1 slope disagrees

   return h4Dir;
}

//------------------------------------------------------------
//  Displacement candle
//------------------------------------------------------------
bool DisplacementOK(const MqlRates &bar, bool bullish)
{
   double range = bar.high - bar.low;
   if(range <= 0.0) return false;
   double body = MathAbs(bar.close - bar.open);
   if((body / range) < DisplaceBodyMinPct) return false;
   if(bullish  && bar.close <= bar.open) return false;
   if(!bullish && bar.close >= bar.open) return false;
   return true;
}

//------------------------------------------------------------
//  Pullback to H1 EMA20
//------------------------------------------------------------
bool PullbackOK(bool bullish)
{
   double ema = 0;
   if(!GetBuf(g_h1EMAHandle, 1, ema)) return false;

   MqlRates sig;
   if(!GetH1Bar(1, sig)) return false;

   double buffer = EMA_Touch_Buffer_Pts * SymbolInfoDouble(_Symbol, SYMBOL_POINT);

   bool touched = (sig.low <= ema + buffer && sig.high >= ema - buffer);
   if(!touched) return false;

   if(bullish  && sig.close < ema - buffer) return false;
   if(!bullish && sig.close > ema + buffer) return false;

   return DisplacementOK(sig, bullish);
}

//------------------------------------------------------------
//  RSI filter
//------------------------------------------------------------
bool PassRSIFilter(bool bullish)
{
   if(!UseRSIFilter || g_h1RSIHandle == INVALID_HANDLE) return true;
   double rsi = 0;
   if(!GetBuf(g_h1RSIHandle, 1, rsi)) return false;
   if(bullish)  return (rsi >= RSI_BuyMin  && rsi <= RSI_BuyMax);
   else         return (rsi >= RSI_SellMin && rsi <= RSI_SellMax);
}

//------------------------------------------------------------
//  Swing SL with ATR cap
//------------------------------------------------------------
bool FindSwingSL(bool bullish, double entry, double &outSL)
{
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   int copied = CopyRates(_Symbol, PERIOD_H1, 1, SwingLookbackBars, rates);
   if(copied < SwingLookbackBars) return false;

   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

   double swingSL;
   if(bullish)
   {
      double lo = rates[0].low;
      for(int i = 1; i < copied; i++) lo = MathMin(lo, rates[i].low);
      swingSL = lo - SL_Buffer_Points * point;
   }
   else
   {
      double hi = rates[0].high;
      for(int i = 1; i < copied; i++) hi = MathMax(hi, rates[i].high);
      swingSL = hi + SL_Buffer_Points * point;
   }

   // ATR-based SL cap: SL can't be further than ATRSLCapMult × ATR from entry
   double atrVal = 0;
   if(g_h1ATRHandle != INVALID_HANDLE && GetBuf(g_h1ATRHandle, 1, atrVal) && atrVal > 0)
   {
      double atrSL = bullish ? entry - ATRSLCapMult * atrVal
                             : entry + ATRSLCapMult * atrVal;
      // Use the tighter SL (closer to entry = smaller risk distance)
      if(bullish)  swingSL = MathMax(swingSL, atrSL);   // higher = closer for buy
      else         swingSL = MathMin(swingSL, atrSL);   // lower  = closer for sell
   }

   outSL = swingSL;
   return true;
}

//------------------------------------------------------------
//  Lot sizing
//------------------------------------------------------------
bool CalcLots(double entry, double sl, double &outLots)
{
   double balance   = AccountInfoDouble(ACCOUNT_BALANCE);
   if(balance <= 0) return false;
   double riskMoney = balance * (RiskPerTradePct / 100.0);

   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickValue <= 0 || tickSize <= 0) return false;

   double dist = MathAbs(entry - sl);
   if(dist <= 0) return false;

   double riskPerLot = (dist / tickSize) * tickValue;
   if(riskPerLot <= 0) return false;

   double lots = riskMoney / riskPerLot;
   double minL = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxL = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   lots = MathFloor(lots / step) * step;
   lots = MathMax(lots, minL);
   lots = MathMin(lots, maxL);
   outLots = lots;
   return true;
}

//------------------------------------------------------------
//  Place order — stores POSITION ticket for management
//------------------------------------------------------------
bool PlaceOrder(bool bullish, double sl, double tp, double lots)
{
   MqlTradeRequest req; MqlTradeResult res;
   ZeroMemory(req); ZeroMemory(res);

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   req.action       = TRADE_ACTION_DEAL;
   req.symbol       = _Symbol;
   req.magic        = MagicNumber;
   req.volume       = lots;
   req.deviation    = SlippagePoints;
   req.type         = bullish ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   req.price        = bullish ? ask : bid;
   req.sl           = sl;
   req.tp           = tp;
   req.type_filling = FillMode();

   if(!OrderSend(req, res)) { Print("OrderSend failed: ", res.retcode, " ", res.comment); return false; }
   if(res.retcode != TRADE_RETCODE_DONE && res.retcode != TRADE_RETCODE_PLACED)
   { Print("OrderSend retcode: ", res.retcode); return false; }

   // res.position = position ticket of the resulting position (correct for MT5 market orders)
   int sz = ArraySize(g_partials);
   ArrayResize(g_partials, sz + 1);
   g_partials[sz].ticket      = res.position;   // FIX: position ticket, not deal ticket
   g_partials[sz].partialDone = false;
   g_partials[sz].beDone      = false;

   Print("Order placed: pos=", res.position, " deal=", res.deal,
         " lots=", lots, " sl=", sl, " tp=", tp);
   return true;
}

//------------------------------------------------------------
//  Modify SL (only improves)
//------------------------------------------------------------
bool ModifySL(ulong ticket, double newSL)
{
   if(!PositionSelectByTicket(ticket)) return false;
   double curSL = PositionGetDouble(POSITION_SL);
   double curTP = PositionGetDouble(POSITION_TP);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

   ENUM_POSITION_TYPE pt = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   if(pt == POSITION_TYPE_BUY  && newSL <= curSL) return false;
   if(pt == POSITION_TYPE_SELL && newSL >= curSL) return false;
   if(MathAbs(newSL - curSL) < point) return false;

   MqlTradeRequest req; MqlTradeResult res;
   ZeroMemory(req); ZeroMemory(res);
   req.action   = TRADE_ACTION_SLTP;
   req.symbol   = _Symbol;
   req.position = ticket;
   req.sl       = newSL;
   req.tp       = curTP;
   req.magic    = MagicNumber;
   return OrderSend(req, res) &&
          (res.retcode == TRADE_RETCODE_DONE || res.retcode == TRADE_RETCODE_PLACED);
}

//------------------------------------------------------------
//  Partial close
//------------------------------------------------------------
bool PartialClose(ulong ticket, double fraction)
{
   if(!PositionSelectByTicket(ticket)) return false;
   double vol  = PositionGetDouble(POSITION_VOLUME);
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minL = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);

   double closeVol = MathFloor(vol * fraction / step) * step;
   if(closeVol < minL) return false;
   if(closeVol >= vol) return false;   // don't full-close via partial path

   MqlTradeRequest req; MqlTradeResult res;
   ZeroMemory(req); ZeroMemory(res);
   req.action       = TRADE_ACTION_DEAL;
   req.symbol       = _Symbol;
   req.position     = ticket;
   req.volume       = closeVol;
   req.magic        = MagicNumber;
   req.deviation    = SlippagePoints;
   req.type_filling = FillMode();

   ENUM_POSITION_TYPE pt = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   if(pt == POSITION_TYPE_BUY)
   { req.type = ORDER_TYPE_SELL; req.price = SymbolInfoDouble(_Symbol, SYMBOL_BID); }
   else
   { req.type = ORDER_TYPE_BUY;  req.price = SymbolInfoDouble(_Symbol, SYMBOL_ASK); }

   return OrderSend(req, res) &&
          (res.retcode == TRADE_RETCODE_DONE || res.retcode == TRADE_RETCODE_PLACED);
}

//------------------------------------------------------------
//  Trade management: EOD close, partial, BE, trail
//------------------------------------------------------------
void ManageOpenTrades()
{
   // EOD forced close — fire once per day when hour >= ForceCloseHour
   if(IsEOD() && !g_eodClosedToday && PositionsByMagic() > 0)
   {
      CloseAllPositions("EOD forced close");
      g_eodClosedToday = true;
      return;
   }

   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;

      ENUM_POSITION_TYPE pt = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double curSL     = PositionGetDouble(POSITION_SL);
      double curTP     = PositionGetDouble(POSITION_TP);
      double curBid    = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double curAsk    = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double curPrice  = (pt == POSITION_TYPE_BUY) ? curBid : curAsk;

      double riskDist = MathAbs(openPrice - curSL);
      if(riskDist <= 0) continue;

      double profitDist = (pt == POSITION_TYPE_BUY) ?
                          (curPrice - openPrice) : (openPrice - curPrice);
      double R = profitDist / riskDist;

      // Find or register partial info by position ticket
      int idx = -1;
      for(int j = 0; j < ArraySize(g_partials); j++)
         if(g_partials[j].ticket == ticket) { idx = j; break; }
      if(idx == -1)
      {
         int sz = ArraySize(g_partials);
         ArrayResize(g_partials, sz + 1);
         g_partials[sz].ticket      = ticket;
         g_partials[sz].partialDone = false;
         g_partials[sz].beDone      = false;
         idx = sz;
      }

      // Partial close at 1R
      if(UsePartialClose && !g_partials[idx].partialDone && R >= 1.0)
      {
         if(PartialClose(ticket, PartialClosePct))
         {
            g_partials[idx].partialDone = true;
            Print("Partial close at R=", DoubleToString(R, 2), " ticket=", ticket);
         }
      }

      // Break-even
      if(UseBreakEven && !g_partials[idx].beDone && R >= BreakEvenAtRR)
      {
         double bePrice = (pt == POSITION_TYPE_BUY) ?
                          openPrice + BE_Buffer_Points * point :
                          openPrice - BE_Buffer_Points * point;
         if(ModifySL(ticket, bePrice))
         {
            g_partials[idx].beDone = true;
            Print("Break-even set at R=", DoubleToString(R, 2), " ticket=", ticket);
         }
      }

      // ATR trailing (only after BE is set)
      if(UseATRTrail && g_partials[idx].beDone && g_h1ATRHandle != INVALID_HANDLE)
      {
         double atrVal = 0;
         if(GetBuf(g_h1ATRHandle, 1, atrVal) && atrVal > 0)
         {
            double newSL = (pt == POSITION_TYPE_BUY) ?
                           curBid - ATRTrail_Mult * atrVal :
                           curAsk + ATRTrail_Mult * atrVal;
            ModifySL(ticket, newSL);
         }
      }
   }
}

//------------------------------------------------------------
//  Loss streak tracking
//------------------------------------------------------------
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest     &request,
                        const MqlTradeResult      &result)
{
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;
   if(trans.symbol != _Symbol) return;
   ulong dealTicket = trans.deal;
   if(dealTicket == 0) return;
   if(!HistoryDealSelect(dealTicket)) return;
   if((ulong)HistoryDealGetInteger(dealTicket, DEAL_MAGIC) != MagicNumber) return;

   ENUM_DEAL_ENTRY de = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
   if(de != DEAL_ENTRY_OUT && de != DEAL_ENTRY_OUT_BY) return;

   double profit = HistoryDealGetDouble(dealTicket, DEAL_PROFIT)
                 + HistoryDealGetDouble(dealTicket, DEAL_SWAP)
                 + HistoryDealGetDouble(dealTicket, DEAL_COMMISSION);
   if(profit < 0.0) g_consecLosses++;
   else             g_consecLosses = 0;
}

//------------------------------------------------------------
//  Entry
//------------------------------------------------------------
void TryEnter()
{
   UpdateDailyState();
   if(AnyHaltCondition())                        return;
   if(g_tradesToday >= MaxTradesPerDay)           return;
   if(!InSession())                               return;
   if(IsEOD())                                    return;
   if(CurrentSpreadPoints() > MaxSpreadPoints)    return;
   if(PositionsByMagic() >= MaxConcurrentTrades)  return;
   if(!PassATRRegimeFilter())                     return;

   // ADX
   if(UseADXFilter && g_h1ADXHandle != INVALID_HANDLE)
   {
      double adx = 0;
      if(GetBuf(g_h1ADXHandle, 1, adx) && adx < ADX_MinLevel)
      {
         Print("ADX ", DoubleToString(adx, 1), " < ", ADX_MinLevel, " – skip");
         return;
      }
   }

   int trend = GetTrend();
   if(trend == 0) return;
   bool bullish = (trend > 0);

   if(!PullbackOK(bullish))     return;
   if(!PassRSIFilter(bullish))  return;

   double sl = 0;
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double entry = bullish ? ask : bid;

   if(!FindSwingSL(bullish, entry, sl)) return;

   if(bullish  && sl >= entry) return;
   if(!bullish && sl <= entry) return;

   // Minimum SL distance guard
   double slDist = MathAbs(entry - sl);
   double point  = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(slDist < MinSL_Points * point)
   {
      Print("SL too tight: ", slDist / point, " pts – skip");
      return;
   }

   double tp = bullish ? (entry + RR_TP * slDist) : (entry - RR_TP * slDist);

   double lots = 0;
   if(!CalcLots(entry, sl, lots)) return;

   if(PlaceOrder(bullish, sl, tp, lots))
      g_tradesToday++;
}

//+------------------------------------------------------------------+
//| Expert initialization                                            |
//+------------------------------------------------------------------+
int OnInit()
{
   g_initBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   g_equityPeak  = AccountInfoDouble(ACCOUNT_EQUITY);
   UpdateDailyState();

   g_h4FastHandle = iMA(_Symbol, PERIOD_H4, H4_EMA_Fast,     0, MODE_EMA, PRICE_CLOSE);
   g_h4SlowHandle = iMA(_Symbol, PERIOD_H4, H4_EMA_Slow,     0, MODE_EMA, PRICE_CLOSE);
   g_h1SlowHandle = iMA(_Symbol, PERIOD_H1, H1_EMA_Slow,     0, MODE_EMA, PRICE_CLOSE);
   g_h1EMAHandle  = iMA(_Symbol, PERIOD_H1, H1_EMA_Pullback, 0, MODE_EMA, PRICE_CLOSE);
   g_h1ADXHandle  = iADX(_Symbol, PERIOD_H1, ADX_Period);
   g_h1RSIHandle  = iRSI(_Symbol, PERIOD_H1, RSI_Period, PRICE_CLOSE);
   g_h1ATRHandle  = iATR(_Symbol, PERIOD_H1, ATRTrail_Period);
   g_h4ATRHandle  = iATR(_Symbol, PERIOD_H4, ATR_Period);

   if(g_h4FastHandle == INVALID_HANDLE || g_h4SlowHandle == INVALID_HANDLE ||
      g_h1SlowHandle == INVALID_HANDLE || g_h1EMAHandle  == INVALID_HANDLE ||
      g_h1ATRHandle  == INVALID_HANDLE || g_h4ATRHandle  == INVALID_HANDLE)
   {
      Print("ERROR: Failed to create indicator handles");
      return INIT_FAILED;
   }

   MqlRates b;
   if(GetH1Bar(0, b)) g_lastH1BarTime = b.time;

   Print("US100 Prop EA v5.0 initialized. Balance=", g_initBalance);
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   int handles[] = { g_h4FastHandle, g_h4SlowHandle, g_h1SlowHandle,
                     g_h1EMAHandle,  g_h1ADXHandle,  g_h1RSIHandle,
                     g_h1ATRHandle,  g_h4ATRHandle };
   for(int i = 0; i < ArraySize(handles); i++)
      if(handles[i] != INVALID_HANDLE) IndicatorRelease(handles[i]);
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   UpdateDailyState();

   if(AnyHaltCondition())
   {
      CloseAllPositions("halt condition");
      return;
   }

   ManageOpenTrades();

   if(NewH1Bar())
      TryEnter();
}
//+------------------------------------------------------------------+
