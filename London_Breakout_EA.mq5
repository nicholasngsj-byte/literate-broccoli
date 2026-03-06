//+------------------------------------------------------------------+
//|  XAUUSD London ORB EA  —  FTMO Prop Firm Edition                 |
//|                                                                  |
//|  STRATEGY:                                                       |
//|  The Asian session (20:00-02:00 NY) accumulates a price range.   |
//|  At the London open (02:00 NY / 07:00 GMT), this EA places a     |
//|  BuyStop above the range high and a SellStop below the range     |
//|  low. Whichever side breaks, the other is cancelled.             |
//|                                                                  |
//|  SESSION PAIR-UP:                                                |
//|  Run alongside NY_Breakout_EA_Simple.mq5 on the same chart.     |
//|  Use a different InpMagic number so the two EAs track their      |
//|  own trades independently.  London positions are force-closed    |
//|  at InpSessionClose (default 06:30 NY) before the NY ORB EA     |
//|  starts its 07:00 NY monitoring window.                          |
//|                                                                  |
//|  TIME INPUTS: Enter all times in NEW YORK time (EST/EDT).        |
//|  Set InpBrokerUTCOffset to your broker's UTC offset and the      |
//|  EA converts to server time automatically (DST-aware).           |
//|                                                                  |
//|  HOW TO FIND YOUR BROKER UTC OFFSET:                             |
//|  1. Open worldtimeserver.com/current_time_in_UTC in a browser   |
//|  2. Compare the UTC time shown to your MT5 Market Watch clock    |
//|  3. Difference = your offset  (e.g. server 17:00, UTC 15:00     |
//|     → offset is +2)                                             |
//|                                                                  |
//|  PIP DEFINITION FOR XAUUSD:                                      |
//|  1 pip = $1.00 price move (e.g. 2345.00 → 2346.00).            |
//|                                                                  |
//|  RANGE SIZE NOTE:                                                |
//|  The Asian range on Gold is typically $8-18 (narrower than NY). |
//|  Default SL=30 pips / TP=60 pips suits this tighter range.      |
//+------------------------------------------------------------------+
#property strict
#include <Trade/Trade.mqh>
#include <Trade/SymbolInfo.mqh>

input group "=== TIMEZONE ==="
input int    InpBrokerUTCOffset = 2;        // Broker UTC offset (e.g. 2 = UTC+2). See header.

input group "=== STRATEGY SETTINGS  [all times in NY time] ==="
input string   InpEntryTime          = "02:00";  // London entry — NY time (= 07:00 GMT)
input string   InpExpirationTime     = "05:00";  // Cancel unfilled pending orders — NY time
input string   InpSessionClose       = "06:30";  // Force-close all positions — NY time (before NY ORB at 07:00)
input int      InpRangeHours         = 6;        // Asian session length in hours (range window before entry)
input int      InpRangeTFMins        = 15;       // Candle TF for range calculation (1/5/15/30/60)
input double   InpOffsetPips         = 5.0;      // Buffer above/below range extremes for stop entry

input group "=== RISK MANAGEMENT ==="
input double   InpLotSize            = 0.0;      // Fixed lot size (0 = auto risk-based)
input double   InpRiskPercent        = 0.75;     // Total risk % per setup (split across both sides)
input double   InpStopLossPips       = 30.0;     // SL distance in pips (1 pip = $1.00 for XAUUSD)
input double   InpTakeProfitPips     = 60.0;     // Fixed TP in pips (0 = use range × multiplier below)
input double   InpTPRangeMultiplier  = 2.0;      // TP = Asian range height × this (when TakeProfitPips = 0)
input double   InpMaxLots            = 5.0;      // Hard lot cap per order (0 = no cap)

input bool     InpUseTrailing        = true;
input double   InpTrailStartPips     = 30.0;     // Profit in pips before trailing activates
input double   InpTrailStepPips      = 20.0;     // Trail distance behind current price

input group "=== PROP FIRM PROTECTION ==="
input double   InpMaxDailyLossPct    = 3.5;      // Daily loss limit % of start-of-day balance
input int      InpMaxConsecLosses    = 3;         // Halt after N consecutive losses (0 = disabled)

input group "=== MARGIN SAFETY ==="
input bool     InpSplitRiskBothSides = true;      // Split InpRiskPercent evenly between buy + sell
input double   InpMaxMarginUsePct    = 30.0;      // Max % of free margin to commit per order

input group "=== NEWS FILTER ==="
// Uses MT5 built-in Economic Calendar — no external feed needed.
// High-impact USD events (NFP, CPI, FOMC etc.) are filtered automatically.
input bool     InpUseNewsFilter      = true;      // Pause near high-impact USD news events
input int      InpNewsMinsBefore     = 60;        // Skip entry if news is within this many minutes
input int      InpNewsMinsAfter      = 30;        // Resume this many minutes after the news release

input group "=== TECH ==="
input ulong    InpMagic              = 234567;    // Unique magic — MUST differ from NY ORB EA
input int      InpSlippagePoints     = 20;
input bool     InpDebugPrint         = false;

CTrade      trade;
CSymbolInfo sym;

// Cached server-time strings — recomputed at OnInit and each new day (DST adjustment).
string   g_svr_entry         = "";
string   g_svr_expiry        = "";
string   g_svr_session_close = "";

double   g_daily_start_balance = 0.0;
datetime g_day_key             = 0;
bool     g_killswitch          = false;
bool     g_orders_placed_today = false;
int      g_consec_losses       = 0;

//---------------- GlobalVariable persistence keys ----------------
string GVKey_KillSwitch()   { return "KS_" + _Symbol + "_" + (string)InpMagic; }
string GVKey_PlacedToday()  { return "PT_" + _Symbol + "_" + (string)InpMagic; }
string GVKey_DayKey()       { return "DK_" + _Symbol + "_" + (string)InpMagic; }
string GVKey_StartBalance() { return "SB_" + _Symbol + "_" + (string)InpMagic; }
string GVKey_ConsecLosses() { return "CL_" + _Symbol + "_" + (string)InpMagic; }

void SaveState()
{
   GlobalVariableSet(GVKey_DayKey(),       (double)g_day_key);
   GlobalVariableSet(GVKey_KillSwitch(),   g_killswitch          ? 1.0 : 0.0);
   GlobalVariableSet(GVKey_PlacedToday(),  g_orders_placed_today ? 1.0 : 0.0);
   GlobalVariableSet(GVKey_StartBalance(), g_daily_start_balance);
   GlobalVariableSet(GVKey_ConsecLosses(), (double)g_consec_losses);
}

void LoadState()
{
   datetime today = iTime(_Symbol, PERIOD_D1, 0);
   if(today == 0) return;

   datetime stored_day = (datetime)(long)GlobalVariableGet(GVKey_DayKey());

   if(stored_day == today)
   {
      g_killswitch          = GlobalVariableGet(GVKey_KillSwitch())  > 0.0;
      g_orders_placed_today = GlobalVariableGet(GVKey_PlacedToday()) > 0.0;
      g_daily_start_balance = GlobalVariableGet(GVKey_StartBalance());
      g_consec_losses       = (int)GlobalVariableGet(GVKey_ConsecLosses());
      Print("LDN State restored: KS=", g_killswitch, " Placed=", g_orders_placed_today,
            " Balance=", g_daily_start_balance, " ConsecLoss=", g_consec_losses);
   }
   else
   {
      g_day_key = today;
      ResetDailyProtector();
   }
}

//---------------- Timezone helpers ----------------
// Returns true when t falls inside US EDT (2nd Sunday March → 1st Sunday November).
bool IsNYSummerTime(datetime t)
{
   MqlDateTime dt;
   TimeToStruct(t, dt);
   int y = dt.year;

   MqlDateTime tmp;
   ZeroMemory(tmp);
   tmp.year = y; tmp.mon = 3; tmp.day = 1; tmp.hour = 2;
   datetime mar1 = StructToTime(tmp);
   MqlDateTime m1;
   TimeToStruct(mar1, m1);
   int to_first_sun_mar = (m1.day_of_week == 0) ? 0 : (7 - m1.day_of_week);
   datetime edt_start = mar1 + (datetime)((to_first_sun_mar + 7) * 86400);

   ZeroMemory(tmp);
   tmp.year = y; tmp.mon = 11; tmp.day = 1; tmp.hour = 2;
   datetime nov1 = StructToTime(tmp);
   MqlDateTime n1;
   TimeToStruct(nov1, n1);
   int to_first_sun_nov = (n1.day_of_week == 0) ? 0 : (7 - n1.day_of_week);
   datetime edt_end = nov1 + (datetime)(to_first_sun_nov * 86400);

   return (t >= edt_start && t < edt_end);
}

// Convert a NY time string "HH:MM" to broker server time "HH:MM". DST-aware.
string NYToServer(const string nyHHMM)
{
   int hh, mm;
   int colon = StringFind(nyHHMM, ":");
   if(colon <= 0) return nyHHMM;
   hh = (int)StringToInteger(StringSubstr(nyHHMM, 0, colon));
   mm = (int)StringToInteger(StringSubstr(nyHHMM, colon + 1));

   int ny_utc = IsNYSummerTime(TimeCurrent()) ? -4 : -5;
   int shift   = (InpBrokerUTCOffset - ny_utc) * 60;

   int total = hh * 60 + mm + shift;
   total = ((total % 1440) + 1440) % 1440;

   return StringFormat("%02d:%02d", total / 60, total % 60);
}

string CurrentNYTime()
{
   int ny_utc = IsNYSummerTime(TimeCurrent()) ? -4 : -5;
   int shift   = (ny_utc - InpBrokerUTCOffset) * 60;
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int total = dt.hour * 60 + dt.min + shift;
   total = ((total % 1440) + 1440) % 1440;
   return StringFormat("%02d:%02d", total / 60, total % 60);
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

datetime TodayAt(const string serverHHMM)
{
   int hh, mm;
   if(!ParseHHMM(serverHHMM, hh, mm)) return 0;
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

bool IsTimeAfterOrEqual(const string targetServerHHMM)
{
   int th, tm;
   if(!ParseHHMM(targetServerHHMM, th, tm)) return false;
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   return (dt.hour * 60 + dt.min) >= (th * 60 + tm);
}

//---------------- Pip helper ----------------
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

//---------------- News Filter ----------------
bool IsHighImpactNewsNearby()
{
   if(!InpUseNewsFilter) return false;

   datetime from = TimeCurrent() - (datetime)(InpNewsMinsAfter  * 60);
   datetime to   = TimeCurrent() + (datetime)(InpNewsMinsBefore * 60);

   MqlCalendarValue values[];
   int count = CalendarValueHistory(values, from, to, "US");
   if(count <= 0) return false;

   for(int i = 0; i < count; i++)
   {
      MqlCalendarEvent ev;
      if(!CalendarEventById(values[i].event_id, ev)) continue;
      if(ev.importance != CALENDAR_IMPORTANCE_HIGH) continue;

      datetime ev_time = values[i].time;
      if(ev_time < from || ev_time > to) continue;

      if(InpDebugPrint)
         PrintFormat("LDN NEWS FILTER: High-impact USD event '%s' at %s — deferred.",
                     ev.name, TimeToString(ev_time, TIME_DATE | TIME_MINUTES));

      return true;
   }
   return false;
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

bool HasOpenOrPendingForMagic() { return HasActivePosition() || HasPendingOrders(); }

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
      trade.PositionClose(pt);
   }
}

//---------------- Daily protector ----------------
void ResetDailyProtector()
{
   g_daily_start_balance = AccountInfoDouble(ACCOUNT_BALANCE);
   g_killswitch          = false;
   g_orders_placed_today = false;
   g_consec_losses       = 0;
   SaveState();
}

void CheckEquityProtector()
{
   if(g_daily_start_balance <= 0) return;

   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
   double current = MathMin(balance, equity);
   double dd      = g_daily_start_balance - current;
   double maxdd   = g_daily_start_balance * (InpMaxDailyLossPct / 100.0);

   if(dd >= maxdd && !g_killswitch)
   {
      Print("LDN KILLSWITCH: Daily loss limit reached. DD=$", DoubleToString(dd, 2),
            " Limit=$", DoubleToString(maxdd, 2));
      g_killswitch = true;
      SaveState();
   }

   if(InpMaxConsecLosses > 0 && g_consec_losses >= InpMaxConsecLosses && !g_killswitch)
   {
      Print("LDN KILLSWITCH: ", g_consec_losses, " consecutive losses — halting for the day.");
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

   if(InpMaxLots > 0.0) maxLot = MathMin(maxLot, InpMaxLots);

   lots = MathMax(minLot, MathMin(maxLot, lots));
   lots = MathFloor(lots / step) * step;

   int dp = (step < 0.0099) ? 3 : (step < 0.099) ? 2 : 1;
   return NormalizeDouble(lots, dp);
}

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

   double freeMargin       = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
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

// Builds the Asian session range by looking back InpRangeHours before the entry time.
// Uses bar-shift + position-based CopyRates for Strategy Tester compatibility.
bool BuildRange(double &hi, double &lo)
{
   hi = -DBL_MAX;
   lo =  DBL_MAX;

   ENUM_TIMEFRAMES tf = MapTFMins(InpRangeTFMins);

   // Asian range = [entry - RangeHours, entry - 1 sec]
   // tStart can fall on the previous calendar day (e.g. entry 09:00 server - 6h = 03:00 server).
   // iBarShift handles absolute datetimes correctly across day boundaries.
   datetime tEnd   = TodayAt(g_svr_entry) - 1;
   datetime tStart = TodayAt(g_svr_entry) - (datetime)(InpRangeHours * 3600);

   if(tStart == 0 || tEnd == 0 || tEnd <= tStart) return false;

   int sh_start = iBarShift(_Symbol, tf, tStart, false);
   int sh_end   = iBarShift(_Symbol, tf, tEnd,   false);

   if(sh_start < 0 || sh_end < 0)
   {
      Print("LDN BuildRange: iBarShift failed. tStart=", TimeToString(tStart),
            " tEnd=", TimeToString(tEnd));
      return false;
   }

   if(sh_start < sh_end) { int t = sh_start; sh_start = sh_end; sh_end = t; }

   int count = sh_start - sh_end + 1;
   if(count <= 0) return false;

   MqlRates rates[];
   ArraySetAsSeries(rates, false);
   int copied = CopyRates(_Symbol, tf, sh_end, count, rates);
   if(copied <= 0)
   {
      Print("LDN BuildRange: CopyRates returned 0. sh_start=", sh_start,
            " sh_end=", sh_end, " count=", count);
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
   if(g_killswitch)              return false;
   if(g_orders_placed_today)     return false;
   if(HasOpenOrPendingForMagic()) return false;
   if(IsTimeAfterOrEqual(g_svr_expiry)) return false;
   if(IsHighImpactNewsNearby())  return false;

   double hi, lo;
   if(!BuildRange(hi, lo)) return false;

   double pip    = PipSize();
   double tp_pips = InpTakeProfitPips > 0.0
                    ? InpTakeProfitPips
                    : ((hi - lo) / pip) * InpTPRangeMultiplier;
   double offset  = InpOffsetPips * pip;

   double buyPrice  = hi + offset;
   double sellPrice = lo - offset;

   int    stops_pts = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minDist   = stops_pts * _Point;
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   if((buyPrice  - ask) < minDist) buyPrice  = ask + minDist;
   if((bid - sellPrice) < minDist) sellPrice = bid - minDist;

   double lotBuy  = CalcLotByRiskAndMargin(InpStopLossPips, ORDER_TYPE_BUY_STOP,  buyPrice);
   double lotSell = CalcLotByRiskAndMargin(InpStopLossPips, ORDER_TYPE_SELL_STOP, sellPrice);

   if(lotBuy <= 0 && lotSell <= 0) return false;

   double slBuy  = NormalizeDouble(buyPrice  - (InpStopLossPips * pip), _Digits);
   double tpBuy  = NormalizeDouble(buyPrice  + (tp_pips         * pip), _Digits);
   double slSell = NormalizeDouble(sellPrice + (InpStopLossPips * pip), _Digits);
   double tpSell = NormalizeDouble(sellPrice - (tp_pips         * pip), _Digits);

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippagePoints);

   datetime expiry = TodayAt(g_svr_expiry);

   bool ok1 = false, ok2 = false;

   if(lotBuy > 0.0)
   {
      ok1 = trade.BuyStop(lotBuy, buyPrice, _Symbol, slBuy, tpBuy,
                          ORDER_TIME_SPECIFIED, expiry, "LDN BuyStop");
      if(!ok1)
         Print("LDN BuyStop failed. Err=", GetLastError(),
               " Price=", buyPrice, " Lots=", lotBuy, " SL=", slBuy, " TP=", tpBuy);
   }

   if(lotSell > 0.0)
   {
      ok2 = trade.SellStop(lotSell, sellPrice, _Symbol, slSell, tpSell,
                           ORDER_TIME_SPECIFIED, expiry, "LDN SellStop");
      if(!ok2)
         Print("LDN SellStop failed. Err=", GetLastError(),
               " Price=", sellPrice, " Lots=", lotSell, " SL=", slSell, " TP=", tpSell);
   }

   if(ok1 || ok2)
   {
      Print("LDN Orders placed. Asian range Hi=", hi, " Lo=", lo,
            " RangeH=", DoubleToString((hi - lo) / pip, 1), "pip  TP=", DoubleToString(tp_pips, 1), "pip",
            " BuyStop=", buyPrice, " SellStop=", sellPrice,
            " Expiry(server)=", TimeToString(expiry));
      g_orders_placed_today = true;
      SaveState();
      return true;
   }
   return false;
}

//---------------- Cancel opposing pending after fill ----------------
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
         trade.PositionModify(pt, newSL, tp);
      }
      else if(type == POSITION_TYPE_SELL)
      {
         double profit_pips = (open - ask) / pip;
         if(profit_pips < InpTrailStartPips) continue;
         double newSL = NormalizeDouble(ask + (InpTrailStepPips * pip), _Digits);
         if(sl != 0.0 && newSL >= sl) continue;
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
      Print("LDN Loss closed. Consecutive losses: ", g_consec_losses);
   }
   else
   {
      g_consec_losses = 0;
      Print("LDN Win closed. Consecutive loss counter reset.");
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

   Print("LDN ServerTime=", TimeToString(TimeCurrent(), TIME_SECONDS),
         " NYTime=",     CurrentNYTime(),
         " EntryAfter=", (IsTimeAfterOrEqual(g_svr_entry)         ? "YES" : "NO"),
         " Expired=",    (IsTimeAfterOrEqual(g_svr_expiry)        ? "YES" : "NO"),
         " SessClose=",  (IsTimeAfterOrEqual(g_svr_session_close) ? "YES" : "NO"),
         " Placed=",     (g_orders_placed_today ? "YES" : "NO"),
         " KS=",         (g_killswitch          ? "YES" : "NO"),
         " ConsecLoss=", g_consec_losses,
         " Balance=",    AccountInfoDouble(ACCOUNT_BALANCE),
         " FreeMargin=", AccountInfoDouble(ACCOUNT_MARGIN_FREE));
}

//---------------- Server-time refresh ----------------
void RefreshServerTimes()
{
   g_svr_entry         = NYToServer(InpEntryTime);
   g_svr_expiry        = NYToServer(InpExpirationTime);
   g_svr_session_close = NYToServer(InpSessionClose);

   string zone = IsNYSummerTime(TimeCurrent()) ? "EDT (UTC-4)" : "EST (UTC-5)";
   Print("LDN zone: auto (", zone, ")",
         "  Entry(server): ",        g_svr_entry,
         "  Expiry(server): ",       g_svr_expiry,
         "  SessionClose(server): ", g_svr_session_close,
         "  RangeHours: ",           InpRangeHours);
}

//---------------- Events ----------------
int OnInit()
{
   if(!sym.Name(_Symbol)) return INIT_FAILED;

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippagePoints);

   RefreshServerTimes();

   Print("=== London ORB EA initialised ===");
   Print("Broker UTC offset: +", InpBrokerUTCOffset,
         "  Magic: ", InpMagic,
         "  News filter: ", (InpUseNewsFilter ? "ON" : "OFF"),
         " | Before=", InpNewsMinsBefore, "min | After=", InpNewsMinsAfter, "min");

   // Validate server-time ordering: entry < expiry < session_close.
   // If any conversion crosses midnight the sequence breaks and entries would be skipped.
   int hh_ent,  mm_ent,  hh_exp,  mm_exp,  hh_cls,  mm_cls;
   ParseHHMM(g_svr_entry,         hh_ent,  mm_ent);
   ParseHHMM(g_svr_expiry,        hh_exp,  mm_exp);
   ParseHHMM(g_svr_session_close, hh_cls,  mm_cls);
   int min_ent = hh_ent * 60 + mm_ent;
   int min_exp = hh_exp * 60 + mm_exp;
   int min_cls = hh_cls * 60 + mm_cls;

   if(min_exp <= min_ent)
   {
      Print("CONFIG ERROR: Expiry (server ", g_svr_expiry,
            ") must be after entry (server ", g_svr_entry, ").");
      Print("  Check: are you entering times in NY time, not server time?");
      Print("  Recommended NY times: Entry 02:00, Expiry 05:00, SessionClose 06:30");
      return INIT_FAILED;
   }
   if(min_cls <= min_exp)
   {
      Print("CONFIG ERROR: SessionClose (server ", g_svr_session_close,
            ") must be after expiry (server ", g_svr_expiry, ").");
      Print("  Recommended NY times: Entry 02:00, Expiry 05:00, SessionClose 06:30");
      return INIT_FAILED;
   }

   g_day_key = iTime(_Symbol, PERIOD_D1, 0);
   LoadState();

   return INIT_SUCCEEDED;
}

void OnTick()
{
   // Skip weekends — no Asian/London session
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   if(dt.day_of_week == 0 || dt.day_of_week == 6) return;

   if(IsNewDay())
   {
      RefreshServerTimes();   // Re-compute in case DST changed overnight
      ResetDailyProtector();
   }

   CheckEquityProtector();

   // Session close — force-close all London positions before the NY ORB session opens.
   // This prevents open London positions from conflicting with the NY breakout EA.
   if(IsTimeAfterOrEqual(g_svr_session_close))
   {
      if(HasActivePosition())
      {
         Print("LDN SESSION CLOSE (server ", g_svr_session_close, "): closing all positions.");
         CloseAllPositions();
      }
      if(HasPendingOrders()) DeleteAllPendings();
      if(!g_killswitch) { g_killswitch = true; SaveState(); }
      return;
   }

   if(g_killswitch)
   {
      if(HasActivePosition()) CloseAllPositions();
      if(HasPendingOrders())  DeleteAllPendings();
      return;
   }

   if(IsTimeAfterOrEqual(g_svr_expiry))
      DeleteAllPendings();

   if(!g_orders_placed_today && IsTimeAfterOrEqual(g_svr_entry))
      PlaceBreakoutOrders();

   CancelOppositeAfterFill();

   ApplyTrailing();
   DebugPrintMinute();
}
