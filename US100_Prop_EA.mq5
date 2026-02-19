//+------------------------------------------------------------------+
//|                                              US100_Prop_EA.mq5  |
//|  Multi-timeframe trend + pullback entry, prop-safe risk controls |
//|  Version 4.0 – Production-grade rewrite                         |
//|                                                                  |
//|  Strategy:                                                       |
//|    Trend  : H4 EMA50 vs EMA200 (bias)                           |
//|    Entry  : H1 pullback to EMA20 + displacement candle           |
//|    Filter : ATR regime, session window, spread, ADX              |
//|  Prop safety:                                                    |
//|    Daily loss cap, trailing drawdown, consecutive loss halt,     |
//|    break-even, partial close at 1R, ATR trailing stop            |
//+------------------------------------------------------------------+
#property strict
#property version   "4.0"
#property description "Prop-safe US100 EA: H4 trend + H1 pullback + displacement + full trade management"

//============================================================
//  INPUTS – Risk / Prop Controls
//============================================================
input ulong  MagicNumber          = 26022026;

input double RiskPerTradePct      = 0.40;   // % of balance risked per trade
input double DailyStopPct         = 1.20;   // halt if equity drops X% from day-start
input double TotalDrawdownPct     = 4.50;   // halt if equity drops X% from init balance (stay above 5%)
input double TrailingDDFromPeakPct= 2.50;   // halt if equity drops X% from equity peak
input int    MaxTradesPerDay      = 2;       // max entries per calendar day
input int    MaxConcurrentTrades  = 1;       // max open positions at once
input int    ConsecLossHalt       = 2;       // halt day after N consecutive losses

//============================================================
//  INPUTS – Execution
//============================================================
input int    MaxSpreadPoints      = 250;    // US100 spread ~ 150-200 pts; allow buffer
input int    SlippagePoints       = 50;
// Fill policy: 0=FOK, 1=IOC, 2=RETURN (try IOC/RETURN for CFDs)
input int    FillPolicy           = 2;      // 2 = ORDER_FILLING_RETURN (most compatible)

//============================================================
//  INPUTS – Session Filter (server time hours, UTC+2/3 broker)
//============================================================
input bool   UseSessionFilter     = true;
input int    SessionStartHour     = 14;     // 14:00 server ~ NY open (UTC+2 broker)
input int    SessionEndHour       = 21;     // 21:00 server ~ NY close
input bool   AvoidFridayClose     = true;   // no new trades Friday after 20:00

//============================================================
//  INPUTS – Strategy Parameters
//============================================================
input int    H4_EMA_Fast          = 50;
input int    H4_EMA_Slow          = 200;

input int    H1_EMA_Pullback      = 20;

// How close to EMA counts as a pullback (in points, 0 = must touch)
input int    EMA_Touch_Buffer_Pts = 80;     // bar must come within N points of EMA

// Candle displacement: body >= X% of range on the signal bar
input double DisplaceBodyMinPct   = 0.55;

// ADX filter on H1 – avoid choppy markets
input bool   UseADXFilter         = true;
input int    ADX_Period           = 14;
input double ADX_MinLevel         = 20.0;   // only trade if ADX >= this

// Stop placement
input int    SwingLookbackBars    = 15;
input int    SL_Buffer_Points     = 60;

// Risk:Reward
input double RR_TP                = 2.0;    // full TP distance

// Partial close at 1R – close this fraction of position
input bool   UsePartialClose      = true;
input double PartialClosePct      = 0.50;   // 50% at 1R

// Break-even: move SL to entry+buffer after this fraction of TP reached
input bool   UseBreakEven         = true;
input double BreakEvenAtRR        = 0.90;   // trigger BE when 90% of 1R achieved
input int    BE_Buffer_Points     = 10;

// ATR trailing stop (applied after BE)
input bool   UseATRTrail          = true;
input int    ATRTrail_Period      = 14;
input double ATRTrail_Mult        = 1.50;   // trail at 1.5x ATR H1

//============================================================
//  INPUTS – ATR Regime Filter
//============================================================
input bool   UseATRRegimeFilter   = true;
input int    ATR_Period           = 14;
input int    ATR_Median_Lookback  = 1500;   // ~12 months H4 bars
input double ATR_RegimeMult       = 0.85;   // trade only if current ATR >= median * mult

//============================================================
//  Global handles (created in OnInit, released in OnDeinit)
//============================================================
int g_h4FastHandle    = INVALID_HANDLE;
int g_h4SlowHandle    = INVALID_HANDLE;
int g_h1EMAHandle     = INVALID_HANDLE;
int g_h1ADXHandle     = INVALID_HANDLE;
int g_h1ATRHandle     = INVALID_HANDLE;   // for trailing
int g_h4ATRHandle     = INVALID_HANDLE;   // for regime filter

//============================================================
//  Global State
//============================================================
datetime g_lastH1BarTime     = 0;
datetime g_dayKey            = 0;
double   g_dayStartEquity    = 0.0;
double   g_initBalance       = 0.0;
double   g_equityPeak        = 0.0;
int      g_tradesToday       = 0;
int      g_consecLosses      = 0;
bool     g_haltedToday       = false;

// Per-position partial close tracking
struct PartialInfo {
   ulong  ticket;
   bool   partialDone;
   bool   beDone;
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
   MqlDateTime s;
   TimeToStruct(t, s);
   s.hour = 0; s.min = 0; s.sec = 0;
   return StructToTime(s);
}

ENUM_ORDER_TYPE_FILLING FillMode()
{
   switch(FillPolicy)
   {
      case 0: return ORDER_FILLING_FOK;
      case 1: return ORDER_FILLING_IOC;
      default: return ORDER_FILLING_RETURN;
   }
}

//------------------------------------------------------------
//  Daily state reset
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
   }
   // Track equity peak for trailing drawdown
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   if(eq > g_equityPeak) g_equityPeak = eq;
}

//------------------------------------------------------------
//  Drawdown / halt checks
//------------------------------------------------------------
bool DailyStopHit()
{
   if(g_dayStartEquity <= 0.0) return false;
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   double dd = (g_dayStartEquity - eq) / g_dayStartEquity * 100.0;
   return (dd >= DailyStopPct);
}

bool TotalDrawdownHit()
{
   if(g_initBalance <= 0.0) return false;
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   double dd = (g_initBalance - eq) / g_initBalance * 100.0;
   return (dd >= TotalDrawdownPct);
}

bool TrailingDDHit()
{
   if(g_equityPeak <= 0.0) return false;
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   double dd = (g_equityPeak - eq) / g_equityPeak * 100.0;
   return (dd >= TrailingDDFromPeakPct);
}

bool AnyHaltCondition()
{
   if(g_haltedToday)           return true;
   if(DailyStopHit())          { g_haltedToday = true; Print("HALT: Daily stop hit"); return true; }
   if(TotalDrawdownHit())      { g_haltedToday = true; Print("HALT: Total drawdown hit"); return true; }
   if(TrailingDDHit())         { g_haltedToday = true; Print("HALT: Trailing DD hit"); return true; }
   if(g_consecLosses >= ConsecLossHalt) { g_haltedToday = true; Print("HALT: Consecutive losses"); return true; }
   return false;
}

//------------------------------------------------------------
//  Emergency close all
//------------------------------------------------------------
void CloseAllPositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;

      MqlTradeRequest req; MqlTradeResult res;
      ZeroMemory(req); ZeroMemory(res);
      req.action   = TRADE_ACTION_DEAL;
      req.symbol   = _Symbol;
      req.volume   = PositionGetDouble(POSITION_VOLUME);
      req.magic    = MagicNumber;
      req.deviation= SlippagePoints;
      req.type_filling = FillMode();

      ENUM_POSITION_TYPE pt = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      if(pt == POSITION_TYPE_BUY)
      {
         req.type  = ORDER_TYPE_SELL;
         req.price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      }
      else
      {
         req.type  = ORDER_TYPE_BUY;
         req.price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      }
      OrderSend(req, res);
   }
}

//------------------------------------------------------------
//  Session filter
//------------------------------------------------------------
bool InSession()
{
   if(!UseSessionFilter) return true;
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);

   // No new trades on Friday after SessionEndHour
   if(AvoidFridayClose && dt.day_of_week == 5 && dt.hour >= 20) return false;

   // Weekend
   if(dt.day_of_week == 0 || dt.day_of_week == 6) return false;

   return (dt.hour >= SessionStartHour && dt.hour < SessionEndHour);
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
//  Position counting
//------------------------------------------------------------
int PositionsByMagic()
{
   int cnt = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != MagicNumber) cnt++;
      // Note: correct condition
      if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
         (ulong)PositionGetInteger(POSITION_MAGIC) == MagicNumber) cnt++;
   }
   // The loop above double-counts; rewrite cleanly:
   cnt = 0;
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

   int need = ATR_Median_Lookback;
   double atrBuf[];
   ArraySetAsSeries(atrBuf, true);
   int copied = CopyBuffer(g_h4ATRHandle, 0, 1, need, atrBuf);
   if(copied < need / 2) return false;   // need at least half

   double atr_current = atrBuf[0];   // most recent closed H4 bar
   double med = Median(atrBuf, copied);
   if(med <= 0.0) return false;

   bool pass = (atr_current >= med * ATR_RegimeMult);
   if(!pass) Print("ATR regime filter: current=", atr_current, " median=", med, " – SKIP");
   return pass;
}

//------------------------------------------------------------
//  Indicator buffer helpers
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

// ADX: buffer 0 = ADX line
bool GetADX(int &outAdx)
{
   if(!UseADXFilter || g_h1ADXHandle == INVALID_HANDLE) { outAdx = 100; return true; }
   double buf[];
   ArraySetAsSeries(buf, true);
   if(CopyBuffer(g_h1ADXHandle, 0, 1, 1, buf) < 1) return false;
   outAdx = (int)buf[0];
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
//  Trend direction (H4)
//------------------------------------------------------------
int TrendDirectionH4()
{
   double fast = 0, slow = 0;
   if(!GetBuf(g_h4FastHandle, 1, fast)) return 0;
   if(!GetBuf(g_h4SlowHandle, 1, slow)) return 0;
   if(fast > slow) return +1;
   if(fast < slow) return -1;
   return 0;
}

//------------------------------------------------------------
//  Displacement candle check
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
//  Pullback to H1 EMA check
//------------------------------------------------------------
bool PullbackOK(bool bullish)
{
   double ema = 0;
   if(!GetBuf(g_h1EMAHandle, 1, ema)) return false;

   MqlRates sig;
   if(!GetH1Bar(1, sig)) return false;

   double point  = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double buffer = EMA_Touch_Buffer_Pts * point;

   // Bar must have come within 'buffer' points of EMA
   bool touched = (sig.low <= ema + buffer && sig.high >= ema - buffer);
   if(!touched) return false;

   // Direction: for buy, price should be approaching EMA from above (pullback down)
   // Signal close should be near or above EMA for buy, near or below for sell
   if(bullish  && sig.close < ema - buffer) return false;
   if(!bullish && sig.close > ema + buffer) return false;

   if(!DisplacementOK(sig, bullish)) return false;
   return true;
}

//------------------------------------------------------------
//  Swing SL
//------------------------------------------------------------
bool FindSwingSL(bool bullish, double &outSL)
{
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   int need = SwingLookbackBars;
   int copied = CopyRates(_Symbol, PERIOD_H1, 1, need, rates);
   if(copied < need) return false;

   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

   if(bullish)
   {
      double lo = rates[0].low;
      for(int i = 1; i < copied; i++) lo = MathMin(lo, rates[i].low);
      outSL = lo - (SL_Buffer_Points * point);
   }
   else
   {
      double hi = rates[0].high;
      for(int i = 1; i < copied; i++) hi = MathMax(hi, rates[i].high);
      outSL = hi + (SL_Buffer_Points * point);
   }
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

   double lots  = riskMoney / riskPerLot;
   double minL  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxL  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   lots = MathFloor(lots / step) * step;
   lots = MathMax(lots, minL);
   lots = MathMin(lots, maxL);
   outLots = lots;
   return true;
}

//------------------------------------------------------------
//  Place market order
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

   bool ok = OrderSend(req, res);
   if(ok && (res.retcode == TRADE_RETCODE_DONE || res.retcode == TRADE_RETCODE_PLACED))
   {
      // Register in partial tracking
      int sz = ArraySize(g_partials);
      ArrayResize(g_partials, sz + 1);
      g_partials[sz].ticket      = res.deal;  // deal ticket; position ticket differs
      g_partials[sz].partialDone = false;
      g_partials[sz].beDone      = false;
      Print("Order placed: ticket=", res.deal, " retcode=", res.retcode,
            " lots=", lots, " sl=", sl, " tp=", tp);
      return true;
   }
   Print("OrderSend failed: retcode=", res.retcode, " comment=", res.comment);
   return false;
}

//------------------------------------------------------------
//  Modify SL/TP on open position
//------------------------------------------------------------
bool ModifySL(ulong ticket, double newSL)
{
   if(!PositionSelectByTicket(ticket)) return false;
   double curSL = PositionGetDouble(POSITION_SL);
   double curTP = PositionGetDouble(POSITION_TP);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

   // Only move in favourable direction
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
   {
      req.type  = ORDER_TYPE_SELL;
      req.price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   }
   else
   {
      req.type  = ORDER_TYPE_BUY;
      req.price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   }
   return OrderSend(req, res) &&
          (res.retcode == TRADE_RETCODE_DONE || res.retcode == TRADE_RETCODE_PLACED);
}

//------------------------------------------------------------
//  Trade management: BE, partial, trailing
//------------------------------------------------------------
void ManageOpenTrades()
{
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;

      ENUM_POSITION_TYPE pt  = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double curSL     = PositionGetDouble(POSITION_SL);
      double curTP     = PositionGetDouble(POSITION_TP);
      double curBid    = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double curAsk    = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double curPrice  = (pt == POSITION_TYPE_BUY) ? curBid : curAsk;

      double riskDist  = MathAbs(openPrice - curSL);
      if(riskDist <= 0) continue;
      double tpDist    = MathAbs(curTP - openPrice);

      // Profit in terms of R
      double profitDist = (pt == POSITION_TYPE_BUY) ?
                          (curPrice - openPrice) :
                          (openPrice - curPrice);
      double R = (riskDist > 0) ? (profitDist / riskDist) : 0.0;

      // Find partial info for this ticket
      int idx = -1;
      for(int j = 0; j < ArraySize(g_partials); j++)
         if(g_partials[j].ticket == ticket) { idx = j; break; }
      // If not found (e.g. EA restarted), add entry
      if(idx == -1)
      {
         int sz = ArraySize(g_partials);
         ArrayResize(g_partials, sz + 1);
         g_partials[sz].ticket      = ticket;
         g_partials[sz].partialDone = false;
         g_partials[sz].beDone      = false;
         idx = sz;
      }

      // --- Partial close at 1R ---
      if(UsePartialClose && !g_partials[idx].partialDone && R >= 1.0)
      {
         if(PartialClose(ticket, PartialClosePct))
         {
            g_partials[idx].partialDone = true;
            Print("Partial close done at R=", R, " ticket=", ticket);
         }
      }

      // --- Break-even ---
      if(UseBreakEven && !g_partials[idx].beDone && R >= BreakEvenAtRR)
      {
         double bePrice;
         if(pt == POSITION_TYPE_BUY)
            bePrice = openPrice + BE_Buffer_Points * point;
         else
            bePrice = openPrice - BE_Buffer_Points * point;

         if(ModifySL(ticket, bePrice))
         {
            g_partials[idx].beDone = true;
            Print("Break-even set at R=", R, " ticket=", ticket);
         }
      }

      // --- ATR Trailing Stop (only after BE) ---
      if(UseATRTrail && g_partials[idx].beDone && g_h1ATRHandle != INVALID_HANDLE)
      {
         double atrVal = 0;
         if(GetBuf(g_h1ATRHandle, 1, atrVal) && atrVal > 0)
         {
            double trailDist = ATRTrail_Mult * atrVal;
            double newSL;
            if(pt == POSITION_TYPE_BUY)
               newSL = curBid - trailDist;
            else
               newSL = curAsk + trailDist;

            ModifySL(ticket, newSL);   // only moves if better than current SL
         }
      }
   }
}

//------------------------------------------------------------
//  Loss tracking (called from OnTradeTransaction)
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

   ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
   if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_OUT_BY) return;

   double profit = HistoryDealGetDouble(dealTicket, DEAL_PROFIT);
   if(profit < 0.0)
      g_consecLosses++;
   else
      g_consecLosses = 0;
}

//------------------------------------------------------------
//  Entry logic
//------------------------------------------------------------
void TryEnter()
{
   UpdateDailyState();

   if(AnyHaltCondition()) return;
   if(g_tradesToday >= MaxTradesPerDay) return;
   if(!InSession()) return;
   if(CurrentSpreadPoints() > MaxSpreadPoints) return;
   if(PositionsByMagic() >= MaxConcurrentTrades) return;
   if(!PassATRRegimeFilter()) return;

   // ADX filter
   if(UseADXFilter)
   {
      double adxBuf[];
      ArraySetAsSeries(adxBuf, true);
      if(g_h1ADXHandle != INVALID_HANDLE &&
         CopyBuffer(g_h1ADXHandle, 0, 1, 1, adxBuf) >= 1)
      {
         if(adxBuf[0] < ADX_MinLevel)
         {
            Print("ADX filter: ", adxBuf[0], " < ", ADX_MinLevel, " – skip");
            return;
         }
      }
   }

   int trend = TrendDirectionH4();
   if(trend == 0) return;
   bool bullish = (trend > 0);

   if(!PullbackOK(bullish)) return;

   double sl = 0;
   if(!FindSwingSL(bullish, sl)) return;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double entry = bullish ? ask : bid;

   if(bullish  && sl >= entry) return;
   if(!bullish && sl <= entry) return;

   double riskDist = MathAbs(entry - sl);
   double tp = bullish ? (entry + RR_TP * riskDist) : (entry - RR_TP * riskDist);

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

   // Create persistent indicator handles
   g_h4FastHandle = iMA(_Symbol, PERIOD_H4, H4_EMA_Fast, 0, MODE_EMA, PRICE_CLOSE);
   g_h4SlowHandle = iMA(_Symbol, PERIOD_H4, H4_EMA_Slow, 0, MODE_EMA, PRICE_CLOSE);
   g_h1EMAHandle  = iMA(_Symbol, PERIOD_H1, H1_EMA_Pullback, 0, MODE_EMA, PRICE_CLOSE);
   g_h1ADXHandle  = iADX(_Symbol, PERIOD_H1, ADX_Period);
   g_h1ATRHandle  = iATR(_Symbol, PERIOD_H1, ATRTrail_Period);
   g_h4ATRHandle  = iATR(_Symbol, PERIOD_H4, ATR_Period);

   if(g_h4FastHandle == INVALID_HANDLE || g_h4SlowHandle == INVALID_HANDLE ||
      g_h1EMAHandle  == INVALID_HANDLE || g_h1ATRHandle  == INVALID_HANDLE ||
      g_h4ATRHandle  == INVALID_HANDLE)
   {
      Print("ERROR: Failed to create indicator handles");
      return INIT_FAILED;
   }

   // Prime last bar time
   MqlRates b;
   if(GetH1Bar(0, b)) g_lastH1BarTime = b.time;

   Print("US100 Prop EA v4.0 initialized. InitBalance=", g_initBalance);
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(g_h4FastHandle != INVALID_HANDLE) IndicatorRelease(g_h4FastHandle);
   if(g_h4SlowHandle != INVALID_HANDLE) IndicatorRelease(g_h4SlowHandle);
   if(g_h1EMAHandle  != INVALID_HANDLE) IndicatorRelease(g_h1EMAHandle);
   if(g_h1ADXHandle  != INVALID_HANDLE) IndicatorRelease(g_h1ADXHandle);
   if(g_h1ATRHandle  != INVALID_HANDLE) IndicatorRelease(g_h1ATRHandle);
   if(g_h4ATRHandle  != INVALID_HANDLE) IndicatorRelease(g_h4ATRHandle);
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   // Emergency halt check on every tick
   UpdateDailyState();
   if(AnyHaltCondition())
   {
      CloseAllPositions();
      return;
   }

   // Trade management runs every tick (for accurate trailing/BE)
   ManageOpenTrades();

   // Entry only on new H1 bar
   if(NewH1Bar())
      TryEnter();
}
//+------------------------------------------------------------------+
