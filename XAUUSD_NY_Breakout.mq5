//+------------------------------------------------------------------+
//|  XAUUSD NY Breakout EA  —  Fixed & Hardened for Prop Firms      |
//|                                                                  |
//|  IMPORTANT — INPUT TIMES:                                        |
//|  All time inputs are in BROKER SERVER TIME, not New York time.  |
//|  Verify your broker's UTC offset and adjust inputs accordingly.  |
//|  Default values assume a UTC+2/+3 broker where NY 09:00 open    |
//|  corresponds to server 14:00/15:00. Check before going live.    |
//|                                                                  |
//|  PIP DEFINITION FOR XAUUSD:                                      |
//|  1 pip = $1.00 price movement (e.g. 2345.00 → 2346.00).        |
//|  So InpStopLossPips=40 means a $40 SL distance. Adjust if       |
//|  your broker quotes Gold differently.                            |
//+------------------------------------------------------------------+
#property strict
#include <Trade/Trade.mqh>
#include <Trade/SymbolInfo.mqh>

input group "=== STRATEGY SETTINGS ==="
input string   InpMonitoringStart    = "14:00";   // Range start (server time)
input string   InpMonitoringEnd      = "15:59";   // Range end   (server time)
input string   InpEntryTime          = "16:00";   // Earliest order placement (server time)
input string   InpExpirationTime     = "19:00";   // Cancel pendings + stop trading (server time)
input double   InpOffsetPips         = 5.0;        // Offset above/below range for stop entry
input int      InpRangeTFMins        = 15;         // Timeframe for range bars (1/5/15/30/60)

input group "=== RISK MANAGEMENT ==="
input double   InpLotSize            = 0.0;        // Fixed lot (0 = auto risk-based)
input double   InpRiskPercent        = 1.0;        // Total risk % per setup (split if both sides)
input double   InpStopLossPips       = 40.0;       // SL distance in pips (1 pip = $1.00 XAUUSD)
input double   InpTakeProfitPips     = 80.0;       // TP distance in pips
input double   InpMaxLots            = 5.0;        // Hard lot cap per order (0 = no cap)

input bool     InpUseTrailing        = true;
input double   InpTrailStartPips     = 30.0;       // Profit in pips before trailing starts
input double   InpTrailStepPips      = 10.0;       // Trail distance behind current price

input group "=== PROP FIRM PROTECTION ==="
input double   InpMaxDailyLossPct    = 3.5;        // Daily loss limit % of start balance (keep < 5% for FTMO)
input int      InpMaxConsecLosses    = 3;           // Halt after N consecutive losses (0 = disabled)

input group "=== MARGIN SAFETY ==="
input bool     InpSplitRiskBothSides = true;        // Split InpRiskPercent between buy + sell
input double   InpMaxMarginUsePct    = 30.0;        // Max % of free margin to use per order

input group "=== TECH ==="
input ulong    InpMagic              = 123456;
input int      InpSlippagePoints     = 20;
input bool     InpDebugPrint         = false;

CTrade      trade;
CSymbolInfo sym;

double   g_daily_start_balance = 0.0;
datetime g_day_key             = 0;
bool     g_killswitch          = false;
bool     g_orders_placed_today = false;
int      g_consec_losses       = 0;

//---------------- GlobalVariable persistence keys ----------------
// Allows state to survive EA restarts / terminal reconnects within the same day.
string GVKey_KillSwitch()    { return "KS_" + _Symbol + "_" + (string)InpMagic; }
string GVKey_PlacedToday()   { return "PT_" + _Symbol + "_" + (string)InpMagic; }
string GVKey_DayKey()        { return "DK_" + _Symbol + "_" + (string)InpMagic; }
string GVKey_StartBalance()  { return "SB_" + _Symbol + "_" + (string)InpMagic; }
string GVKey_ConsecLosses()  { return "CL_" + _Symbol + "_" + (string)InpMagic; }

void SaveState()
{
   GlobalVariableSet(GVKey_DayKey(),      (double)g_day_key);
   GlobalVariableSet(GVKey_KillSwitch(),  g_killswitch          ? 1.0 : 0.0);
   GlobalVariableSet(GVKey_PlacedToday(), g_orders_placed_today ? 1.0 : 0.0);
   GlobalVariableSet(GVKey_StartBalance(), g_daily_start_balance);
   GlobalVariableSet(GVKey_ConsecLosses(), (double)g_consec_losses);
}

void LoadState()
{
   // Called once at OnInit. Restores today's state if the EA was restarted mid-session.
   datetime today = iTime(_Symbol, PERIOD_D1, 0);
   if(today == 0) return;   // data not ready; OnTick will handle

   datetime stored_day = (datetime)(long)GlobalVariableGet(GVKey_DayKey());

   if(stored_day == today)
   {
      // Same trading day — restore flags so we don't re-enter or ignore the killswitch
      g_killswitch          = GlobalVariableGet(GVKey_KillSwitch())  > 0.0;
      g_orders_placed_today = GlobalVariableGet(GVKey_PlacedToday()) > 0.0;
      g_daily_start_balance = GlobalVariableGet(GVKey_StartBalance());
      g_consec_losses       = (int)GlobalVariableGet(GVKey_ConsecLosses());
      Print("State restored: KS=", g_killswitch, " Placed=", g_orders_placed_today,
            " Balance=", g_daily_start_balance, " ConsecLoss=", g_consec_losses);
   }
   else
   {
      // New day — start fresh
      g_day_key = today;
      ResetDailyProtector();
   }
}

//---------------- Time helpers ----------------
bool ParseHHMM(const string hhmm, int &hh, int &mm)
{
   int colon = StringFind(hhmm, ":");
   if(colon <= 0) return false;
   hh = (int)StringToInteger(StringSubstr(hhmm, 0, colon));
   mm = (int)StringToInteger(StringSubstr(hhmm, colon + 1));
   return (hh >= 0 && hh <= 23 && mm >= 0 && mm <= 59);
}

datetime TodayAt(const string hhmm)
{
   int hh, mm;
   if(!ParseHHMM(hhmm, hh, mm)) return 0;
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   dt.hour = hh; dt.min = mm; dt.sec = 0;
   return StructToTime(dt);
}

bool IsNewDay()
{
   datetime today_key = iTime(_Symbol, PERIOD_D1, 0);
   if(today_key == 0) return false;
   if(today_key != g_day_key) { g_day_key = today_key; return true; }
   return false;
}

bool IsTimeAfterOrEqual(const string targetHHMM)
{
   int th, tm;
   if(!ParseHHMM(targetHHMM, th, tm)) return false;
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   return (dt.hour * 60 + dt.min) >= (th * 60 + tm);
}

//---------------- Pip helper ----------------
// XAUUSD: 1 pip = $1.00 price move (e.g. 2345 → 2346).
// FX 5-digit: 1 pip = 0.0001.
double PipSize()
{
   string s = _Symbol;
   StringToUpper(s);
   if(StringFind(s, "XAU")  >= 0 || StringFind(s, "GOLD")   >= 0) return 1.0;
   if(StringFind(s, "XAG")  >= 0 || StringFind(s, "SILVER") >= 0) return 0.01;
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   if(digits == 4 || digits == 5) return 0.0001;
   return _Point;
}

//---------------- Orders / positions ----------------
bool HasActivePosition()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong pt = PositionGetTicket(i);
      if(pt == 0 || !PositionSelectByTicket(pt)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      return true;
   }
   return false;
}

bool HasPendingOrders()
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ot = OrderGetTicket(i);
      if(ot == 0 || !OrderSelect(ot)) continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol) continue;
      if((ulong)OrderGetInteger(ORDER_MAGIC) != InpMagic) continue;
      ENUM_ORDER_TYPE t = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if(t == ORDER_TYPE_BUY_STOP  || t == ORDER_TYPE_SELL_STOP  ||
         t == ORDER_TYPE_BUY_LIMIT || t == ORDER_TYPE_SELL_LIMIT ||
         t == ORDER_TYPE_BUY_STOP_LIMIT || t == ORDER_TYPE_SELL_STOP_LIMIT)
         return true;
   }
   return false;
}

bool HasOpenOrPendingForMagic()
{
   return HasActivePosition() || HasPendingOrders();
}

void DeleteAllPendings()
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ot = OrderGetTicket(i);
      if(ot == 0 || !OrderSelect(ot)) continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol) continue;
      if((ulong)OrderGetInteger(ORDER_MAGIC) != InpMagic) continue;
      ENUM_ORDER_TYPE t = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if(t == ORDER_TYPE_BUY_STOP  || t == ORDER_TYPE_SELL_STOP  ||
         t == ORDER_TYPE_BUY_LIMIT || t == ORDER_TYPE_SELL_LIMIT ||
         t == ORDER_TYPE_BUY_STOP_LIMIT || t == ORDER_TYPE_SELL_STOP_LIMIT)
         trade.OrderDelete(ot);
   }
}

void CloseAllPositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong pt = PositionGetTicket(i);
      if(pt == 0 || !PositionSelectByTicket(pt)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      // FIX: use ticket overload — symbol overload closes the wrong position
      // in multi-EA environments
      trade.PositionClose(pt);
   }
}

//---------------- Daily protector ----------------
void ResetDailyProtector()
{
   // FIX: snapshot balance, not equity — matches prop firm methodology
   // (FTMO measures daily loss from beginning-of-day balance)
   g_daily_start_balance = AccountInfoDouble(ACCOUNT_BALANCE);
   g_killswitch          = false;
   g_orders_placed_today = false;
   // g_consec_losses intentionally NOT reset — persists across trading days
   SaveState();
}

void CheckEquityProtector()
{
   if(g_daily_start_balance <= 0) return;

   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
   // FIX: use lower of balance/equity — matches FTMO's drawdown methodology
   double current = MathMin(balance, equity);
   double dd      = g_daily_start_balance - current;
   double maxdd   = g_daily_start_balance * (InpMaxDailyLossPct / 100.0);

   if(dd >= maxdd && !g_killswitch)
   {
      Print("KILLSWITCH: Daily loss limit reached. DrawDown=", DoubleToString(dd, 2),
            " Limit=", DoubleToString(maxdd, 2));
      g_killswitch = true;
      SaveState();
   }

   // Consecutive loss halt
   if(InpMaxConsecLosses > 0 && g_consec_losses >= InpMaxConsecLosses && !g_killswitch)
   {
      Print("KILLSWITCH: ", g_consec_losses, " consecutive losses — halting for the day.");
      g_killswitch = true;
      SaveState();
   }
}

//---------------- Lot sizing ----------------
double NormalizeLot(double lots)
{
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(step <= 0) step = 0.01;

   // Apply hard lot cap
   if(InpMaxLots > 0.0) maxLot = MathMin(maxLot, InpMaxLots);

   lots = MathMax(minLot, MathMin(maxLot, lots));
   lots = MathFloor(lots / step) * step;

   // FIX: derive decimal places from step rather than hardcoding 2
   int dp = 2;
   if(step < 0.0099)      dp = 3;
   else if(step < 0.099)  dp = 2;
   else                   dp = 1;

   return NormalizeDouble(lots, dp);
}

// orderPrice: the actual price at which the pending will execute —
// used for accurate margin estimation rather than current ask/bid.
double CalcLotByRiskAndMargin(double sl_pips, ENUM_ORDER_TYPE orderType, double orderPrice)
{
   if(InpLotSize > 0.0) return NormalizeLot(InpLotSize);

   double riskPct = InpRiskPercent;
   if(InpSplitRiskBothSides) riskPct *= 0.5;

   double balance    = AccountInfoDouble(ACCOUNT_BALANCE);
   double risk_money = balance * (riskPct / 100.0);

   double pip           = PipSize();
   double sl_price_dist = sl_pips * pip;

   double tick_value = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tick_size  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tick_value <= 0 || tick_size <= 0 || sl_price_dist <= 0) return 0.0;

   double value_per_unit_per_lot = tick_value / tick_size;
   double loss_per_lot           = sl_price_dist * value_per_unit_per_lot;
   if(loss_per_lot <= 0) return 0.0;

   double lots_risk = NormalizeLot(risk_money / loss_per_lot);

   // FIX: use the actual order price for margin calc, not current ask/bid
   double freeMargin       = AccountInfoDouble(ACCOUNT_FREEMARGIN);
   double maxMarginAllowed = freeMargin * (InpMaxMarginUsePct / 100.0);

   double margin_per_lot = 0.0;
   if(!OrderCalcMargin(orderType, _Symbol, 1.0, orderPrice, margin_per_lot))
      margin_per_lot = 0.0;

   if(margin_per_lot > 0.0 && maxMarginAllowed > 0.0)
   {
      double lots_margin = NormalizeLot(maxMarginAllowed / margin_per_lot);
      return NormalizeLot(MathMin(lots_risk, lots_margin));
   }

   return lots_risk;
}

//---------------- Range ----------------
ENUM_TIMEFRAMES MapTFMins(const int mins)
{
   if(mins == 1)  return PERIOD_M1;
   if(mins == 5)  return PERIOD_M5;
   if(mins == 15) return PERIOD_M15;
   if(mins == 30) return PERIOD_M30;
   if(mins == 60) return PERIOD_H1;
   return PERIOD_M15;
}

bool BuildRange(double &hi, double &lo)
{
   hi = -DBL_MAX;
   lo =  DBL_MAX;

   datetime tStart = TodayAt(InpMonitoringStart);
   // FIX: use 1 second before entry time as the range end so that CopyRates
   // only returns fully closed bars — avoids including an in-progress bar
   // whose high/low is still moving.
   datetime tEnd = TodayAt(InpEntryTime) - 1;

   if(tStart == 0 || tEnd == 0 || tEnd <= tStart) return false;

   ENUM_TIMEFRAMES tf = MapTFMins(InpRangeTFMins);

   MqlRates rates[];
   // FIX: set as series FALSE — CopyRates(from, to) fills chronologically;
   // pairing with SetAsSeries(true) is misleading and unnecessary here.
   ArraySetAsSeries(rates, false);

   int copied = CopyRates(_Symbol, tf, tStart, tEnd, rates);
   if(copied <= 0)
   {
      if(InpDebugPrint)
         Print("BuildRange: no bars returned. tStart=", TimeToString(tStart),
               " tEnd=", TimeToString(tEnd), " TF=", EnumToString(tf));
      return false;
   }

   for(int i = 0; i < copied; i++)
   {
      hi = MathMax(hi, rates[i].high);
      lo = MathMin(lo, rates[i].low);
   }
   return (hi > lo);
}

//---------------- Order placement ----------------
bool PlaceBreakoutOrders()
{
   if(g_killswitch)          return false;
   if(g_orders_placed_today) return false;
   if(HasOpenOrPendingForMagic()) return false;
   if(IsTimeAfterOrEqual(InpExpirationTime)) return false;

   double hi, lo;
   if(!BuildRange(hi, lo)) return false;

   double pip    = PipSize();
   double offset = InpOffsetPips * pip;

   double buyPrice  = hi + offset;
   double sellPrice = lo - offset;

   int    stops_pts = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minDist   = stops_pts * _Point;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   if((buyPrice  - ask) < minDist) buyPrice  = ask + minDist;
   if((bid - sellPrice) < minDist) sellPrice = bid - minDist;

   // FIX: pass actual order price so margin estimate reflects fill price
   double lotBuy  = CalcLotByRiskAndMargin(InpStopLossPips, ORDER_TYPE_BUY_STOP,  buyPrice);
   double lotSell = CalcLotByRiskAndMargin(InpStopLossPips, ORDER_TYPE_SELL_STOP, sellPrice);

   if(lotBuy <= 0 && lotSell <= 0) return false;

   double slBuy  = NormalizeDouble(buyPrice  - (InpStopLossPips   * pip), _Digits);
   double tpBuy  = NormalizeDouble(buyPrice  + (InpTakeProfitPips * pip), _Digits);
   double slSell = NormalizeDouble(sellPrice + (InpStopLossPips   * pip), _Digits);
   double tpSell = NormalizeDouble(sellPrice - (InpTakeProfitPips * pip), _Digits);

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippagePoints);

   // FIX: ORDER_TIME_SPECIFIED with explicit expiry so orders auto-cancel
   // at InpExpirationTime instead of persisting across days as GTC orders.
   datetime expiry = TodayAt(InpExpirationTime);

   bool ok1 = false, ok2 = false;

   if(lotBuy > 0.0)
   {
      ok1 = trade.BuyStop(lotBuy, buyPrice, _Symbol, slBuy, tpBuy,
                          ORDER_TIME_SPECIFIED, expiry, "NY BuyStop");
      if(!ok1)
         Print("BuyStop failed. Err=", GetLastError(),
               " Price=", buyPrice, " Lots=", lotBuy,
               " SL=", slBuy, " TP=", tpBuy);
   }

   if(lotSell > 0.0)
   {
      ok2 = trade.SellStop(lotSell, sellPrice, _Symbol, slSell, tpSell,
                           ORDER_TIME_SPECIFIED, expiry, "NY SellStop");
      if(!ok2)
         Print("SellStop failed. Err=", GetLastError(),
               " Price=", sellPrice, " Lots=", lotSell,
               " SL=", slSell, " TP=", tpSell);
   }

   if(ok1 || ok2)
   {
      Print("Breakout orders placed. Range Hi=", hi, " Lo=", lo,
            " BuyStop=", buyPrice, " SellStop=", sellPrice,
            " Expiry=", TimeToString(expiry));
      g_orders_placed_today = true;
      SaveState();
      return true;
   }
   return false;
}

//---------------- Cancel opposing pending after one side fills ----------------
// Once a position is open (one breakout direction triggered), the other
// pending order is undesirable — cancel it to prevent a same-day
// double-loss scenario.
void CancelOppositeAfterFill()
{
   if(HasActivePosition() && HasPendingOrders())
      DeleteAllPendings();
}

//---------------- Trailing stop ----------------
void ApplyTrailing()
{
   if(!InpUseTrailing) return;

   double pip = PipSize();

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong pt = PositionGetTicket(i);
      if(pt == 0 || !PositionSelectByTicket(pt)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;

      long   type = PositionGetInteger(POSITION_TYPE);
      double open = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl   = PositionGetDouble(POSITION_SL);
      double tp   = PositionGetDouble(POSITION_TP);
      double bid  = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double ask  = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

      if(type == POSITION_TYPE_BUY)
      {
         double profit_pips = (bid - open) / pip;
         if(profit_pips < InpTrailStartPips) continue;

         double newSL = NormalizeDouble(bid - (InpTrailStepPips * pip), _Digits);
         if(sl != 0.0 && newSL <= sl) continue;

         // FIX: use ticket overload — symbol overload modifies a random position
         trade.PositionModify(pt, newSL, tp);
      }
      else if(type == POSITION_TYPE_SELL)
      {
         double profit_pips = (open - ask) / pip;
         if(profit_pips < InpTrailStartPips) continue;

         double newSL = NormalizeDouble(ask + (InpTrailStepPips * pip), _Digits);
         if(sl != 0.0 && newSL >= sl) continue;

         // FIX: use ticket overload
         trade.PositionModify(pt, newSL, tp);
      }
   }
}

//---------------- Consecutive loss tracking ----------------
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest     &request,
                        const MqlTradeResult      &result)
{
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;

   ulong deal = trans.deal;
   // Ensure deal is in history before selecting
   HistorySelect(0, TimeCurrent());
   if(!HistoryDealSelect(deal)) return;

   if(HistoryDealGetString(deal, DEAL_SYMBOL) != _Symbol) return;
   if((ulong)HistoryDealGetInteger(deal, DEAL_MAGIC) != InpMagic) return;

   ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(deal, DEAL_ENTRY);
   if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_INOUT) return;

   double profit = HistoryDealGetDouble(deal, DEAL_PROFIT)
                 + HistoryDealGetDouble(deal, DEAL_SWAP)
                 + HistoryDealGetDouble(deal, DEAL_COMMISSION);

   if(profit < 0.0)
   {
      g_consec_losses++;
      Print("Loss closed. Consecutive losses: ", g_consec_losses);
   }
   else
   {
      g_consec_losses = 0;
      Print("Win closed. Consecutive loss counter reset.");
   }
   SaveState();
}

//---------------- Debug ----------------
void DebugPrintMinute()
{
   if(!InpDebugPrint) return;
   static int lastMin = -1;
   MqlDateTime d;
   TimeToStruct(TimeCurrent(), d);
   if(d.min == lastMin) return;
   lastMin = d.min;

   Print("ServerTime=",  TimeToString(TimeCurrent(), TIME_SECONDS),
         " EntryAfter=", (IsTimeAfterOrEqual(InpEntryTime)      ? "YES" : "NO"),
         " Expired=",    (IsTimeAfterOrEqual(InpExpirationTime) ? "YES" : "NO"),
         " Placed=",     (g_orders_placed_today ? "YES" : "NO"),
         " KS=",         (g_killswitch          ? "YES" : "NO"),
         " ConsecLoss=", g_consec_losses,
         " Balance=",    AccountInfoDouble(ACCOUNT_BALANCE),
         " FreeMargin=", AccountInfoDouble(ACCOUNT_FREEMARGIN));
}

//---------------- Events ----------------
int OnInit()
{
   if(!sym.Name(_Symbol)) return INIT_FAILED;

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippagePoints);

   // Seed day key before LoadState so the comparison is valid
   g_day_key = iTime(_Symbol, PERIOD_D1, 0);

   // FIX: restore state if EA was restarted mid-session — prevents
   // re-entering the market on the same day after a restart
   LoadState();

   return INIT_SUCCEEDED;
}

void OnTick()
{
   if(IsNewDay())
      ResetDailyProtector();

   CheckEquityProtector();

   // FIX: when killswitch is active, keep retrying close + delete every tick
   // until the account is fully flat — a single failed close attempt no
   // longer silently leaves positions open
   if(g_killswitch)
   {
      if(HasActivePosition()) CloseAllPositions();
      if(HasPendingOrders())  DeleteAllPendings();
      return;
   }

   if(IsTimeAfterOrEqual(InpExpirationTime))
      DeleteAllPendings();

   if(!g_orders_placed_today && IsTimeAfterOrEqual(InpEntryTime))
      PlaceBreakoutOrders();

   // FIX: once one breakout direction fills, cancel the opposing pending
   // to prevent a second unintended trade on the same day
   CancelOppositeAfterFill();

   ApplyTrailing();
   DebugPrintMinute();
}
