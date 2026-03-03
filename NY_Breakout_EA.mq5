//+------------------------------------------------------------------+
//|  XAUUSD NY Breakout EA  —  Fixed & Hardened for Prop Firms      |
//|                                                                  |
//|  TIME INPUTS: Enter all times in NEW YORK time (EST/EDT).       |
//|  Set InpBrokerUTCOffset to your broker's UTC offset and the     |
//|  EA converts to server time automatically.                       |
//|                                                                  |
//|  HOW TO FIND YOUR BROKER UTC OFFSET:                            |
//|  1. Open worldtimeserver.com/current_time_in_UTC in a browser   |
//|  2. Compare the UTC time shown to your MT5 Market Watch clock   |
//|  3. Difference = your offset  (e.g. server 17:00, UTC 15:00     |
//|     → offset is +2)                                             |
//|                                                                  |
//|  DST NOTE: NY DST is auto-detected. EDT (UTC-4) applies from    |
//|  2nd Sunday March to 1st Sunday November. No manual toggle      |
//|  needed — the EA adjusts its window automatically each day.     |
//|                                                                  |
//|  PIP DEFINITION FOR XAUUSD:                                      |
//|  1 pip = $1.00 price move (e.g. 2345.00 → 2346.00).            |
//|  InpStopLossPips=40 → $40 SL distance.                         |
//|                                                                  |
//|  NEWS FILTER:                                                    |
//|  Uses the MT5 built-in Economic Calendar. No external feed       |
//|  required. EA pauses order placement when a high-impact USD      |
//|  event is within InpNewsMinsBefore minutes, and resumes after    |
//|  InpNewsMinsAfter minutes have elapsed since that event.         |
//|  If the expiry window closes while news is pending the EA        |
//|  simply skips the day — exactly as it would for any other        |
//|  entry condition that is not met.                                |
//+------------------------------------------------------------------+
#property strict
#include <Trade/Trade.mqh>
#include <Trade/SymbolInfo.mqh>

input group "=== TIMEZONE ==="
input int    InpBrokerUTCOffset = 2;     // Broker UTC offset (e.g. 2 = UTC+2). See instructions above.

input group "=== STRATEGY SETTINGS  [all times in NY time] ==="
input string   InpMonitoringStart    = "07:00";   // Range build start  (NY time)
input string   InpMonitoringEnd      = "08:59";   // Range build end    (NY time)
input string   InpEntryTime          = "09:00";   // Earliest order placement (NY time, typically NY open)
input string   InpExpirationTime     = "13:00";   // Cancel pendings + stop trading (NY time)
input bool     InpUseHardClose       = true;       // Force-close open positions at SGT cutoff
input string   InpHardCloseTimeSGT   = "01:00";   // Hard close time (Singapore Time UTC+8). 01:00 SGT = 17:00 UTC.
input double   InpOffsetPips         = 5.0;        // Offset above/below range for stop entry
input int      InpRangeTFMins        = 15;         // Timeframe for range bars (1/5/15/30/60)

input group "=== RISK MANAGEMENT ==="
input double   InpLotSize            = 0.0;        // Fixed lot (0 = auto risk-based)
input double   InpRiskPercent        = 1.0;        // Total risk % per setup (split if both sides)
input double   InpStopLossPips       = 40.0;       // SL distance in pips (1 pip = $1.00 for XAUUSD)
input double   InpTakeProfitPips     = 80.0;       // Fixed TP in pips (0 = use range multiplier below)
input double   InpTPRangeMultiplier  = 2.0;        // TP = range_height × this (when InpTakeProfitPips = 0)
input double   InpMaxLots            = 5.0;        // Hard lot cap per order (0 = no cap)

input bool     InpUseTrailing        = true;
input double   InpTrailStartPips     = 40.0;       // Profit in pips before trailing starts
input double   InpTrailStepPips      = 25.0;       // Trail distance behind current price

input group "=== PROP FIRM PROTECTION ==="
input double   InpMaxDailyLossPct    = 3.5;        // Daily loss limit % of start balance (keep < 5% for FTMO)
input int      InpMaxConsecLosses    = 3;           // Halt after N consecutive losses (0 = disabled)

input group "=== MARGIN SAFETY ==="
input bool     InpSplitRiskBothSides = true;        // Split InpRiskPercent between buy + sell
input double   InpMaxMarginUsePct    = 30.0;        // Max % of free margin to use per order

input group "=== NEWS FILTER ==="
// The EA uses the MT5 built-in Economic Calendar — no external data feed needed.
// It checks all high-impact USD events shown in your MT5 calendar panel.
// Events from other currencies (EUR, GBP, etc.) are not filtered by default
// because XAUUSD reacts most strongly to USD surprises.
// Adjust InpNewsMinsBefore/After to suit your risk appetite.
input bool     InpUseNewsFilter      = true;        // Pause near high-impact USD news
input int      InpNewsMinsBefore     = 60;          // Don't place orders if news is within this many minutes
input int      InpNewsMinsAfter      = 30;          // Resume this many minutes AFTER the news event time
// TIP: InpNewsMinsBefore=60 + InpNewsMinsAfter=30 means the EA avoids a 90-minute window
//      centred around each high-impact release.  For NFP or CPI you may want wider gaps.

input group "=== TECH ==="
input ulong    InpMagic              = 123456;
input int      InpSlippagePoints     = 20;
input bool     InpDebugPrint         = false;

input group "=== BREAK-EVEN STOP ==="
input double   InpBreakEvenPips      = 20.0;       // Move SL to entry+buffer when profit reaches this many pips (0 = disabled)
input double   InpBreakEvenBuffer    = 3.0;         // Extra pips beyond entry for the BE SL (absorbs spread on exit)

input group "=== SESSION CLOSE ==="
input string   InpNYSessionClose     = "17:00";    // Close all positions at this NY time — e.g. "17:00" = 5 pm NY (end of session). "" = off

CTrade      trade;
CSymbolInfo sym;

// Cached server-time strings, computed once at OnInit from NY inputs + offset.
// All internal logic uses these — never the raw Inp*Time strings directly.
string   g_svr_mon_start  = "";
string   g_svr_mon_end    = "";
string   g_svr_entry      = "";
string   g_svr_expiry     = "";
string   g_svr_hard_close    = "";   // computed from InpHardCloseTimeSGT
string   g_svr_ny_close      = "";   // computed from InpNYSessionClose
bool     g_ny_close_next_day = false; // true when NY close converts to a next-day server time

double   g_daily_start_balance = 0.0;
datetime g_day_key             = 0;
bool     g_killswitch          = false;
bool     g_orders_placed_today = false;
int      g_consec_losses       = 0;

//---------------- GlobalVariable persistence keys ----------------
string GVKey_KillSwitch()    { return "KS_" + _Symbol + "_" + (string)InpMagic; }
string GVKey_PlacedToday()   { return "PT_" + _Symbol + "_" + (string)InpMagic; }
string GVKey_DayKey()        { return "DK_" + _Symbol + "_" + (string)InpMagic; }
string GVKey_StartBalance()  { return "SB_" + _Symbol + "_" + (string)InpMagic; }
string GVKey_ConsecLosses()  { return "CL_" + _Symbol + "_" + (string)InpMagic; }

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
      Print("State restored: KS=", g_killswitch, " Placed=", g_orders_placed_today,
            " Balance=", g_daily_start_balance, " ConsecLoss=", g_consec_losses);
   }
   else
   {
      g_day_key = today;
      ResetDailyProtector();
   }
}

//---------------- Timezone conversion ----------------
// Returns true when t falls inside US EDT (2nd Sunday of March → 1st Sunday of November).
bool IsNYSummerTime(datetime t)
{
   MqlDateTime dt;
   TimeToStruct(t, dt);
   int y = dt.year;

   // 2nd Sunday of March at 02:00
   MqlDateTime tmp;
   ZeroMemory(tmp);
   tmp.year = y; tmp.mon = 3; tmp.day = 1; tmp.hour = 2;
   datetime mar1 = StructToTime(tmp);
   MqlDateTime m1;
   TimeToStruct(mar1, m1);
   int to_first_sun_mar = (m1.day_of_week == 0) ? 0 : (7 - m1.day_of_week);
   datetime edt_start = mar1 + (datetime)((to_first_sun_mar + 7) * 86400);

   // 1st Sunday of November at 02:00
   ZeroMemory(tmp);
   tmp.year = y; tmp.mon = 11; tmp.day = 1; tmp.hour = 2;
   datetime nov1 = StructToTime(tmp);
   MqlDateTime n1;
   TimeToStruct(nov1, n1);
   int to_first_sun_nov = (n1.day_of_week == 0) ? 0 : (7 - n1.day_of_week);
   datetime edt_end = nov1 + (datetime)(to_first_sun_nov * 86400);

   return (t >= edt_start && t < edt_end);
}

// Convert a NY time string "HH:MM" to a broker server time string "HH:MM".
// NY EST = UTC-5, NY EDT = UTC-4.
// Handles midnight wrap in both directions.
string NYToServer(const string nyHHMM)
{
   int hh, mm;
   int colon = StringFind(nyHHMM, ":");
   if(colon <= 0) return nyHHMM;
   hh = (int)StringToInteger(StringSubstr(nyHHMM, 0, colon));
   mm = (int)StringToInteger(StringSubstr(nyHHMM, colon + 1));

   int ny_utc = IsNYSummerTime(TimeCurrent()) ? -4 : -5; // NY UTC offset (auto-detected)
   int shift   = (InpBrokerUTCOffset - ny_utc) * 60;    // minutes to add

   int total = hh * 60 + mm + shift;
   total = ((total % 1440) + 1440) % 1440;            // wrap into 0-1439

   return StringFormat("%02d:%02d", total / 60, total % 60);
}

// Convert a SGT time "HH:MM" (UTC+8) to broker server time "HH:MM".
// DST-independent: SGT is fixed UTC+8 year-round.
string SGTToServer(const string sgtHHMM)
{
   int hh, mm;
   int colon = StringFind(sgtHHMM, ":");
   if(colon <= 0) return sgtHHMM;
   hh = (int)StringToInteger(StringSubstr(sgtHHMM, 0, colon));
   mm = (int)StringToInteger(StringSubstr(sgtHHMM, colon + 1));

   int shift = (InpBrokerUTCOffset - 8) * 60;   // SGT = UTC+8
   int total = hh * 60 + mm + shift;
   total = ((total % 1440) + 1440) % 1440;

   return StringFormat("%02d:%02d", total / 60, total % 60);
}

// Convenience: returns current NY time as "HH:MM" for debug display.
string CurrentNYTime()
{
   int ny_utc  = IsNYSummerTime(TimeCurrent()) ? -4 : -5; // auto-detected
   int shift   = (ny_utc - InpBrokerUTCOffset) * 60;     // subtract offset to go from server→NY
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

// Returns a datetime for today at the given server-time "HH:MM".
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

// targetServerHHMM must already be in server time (use g_svr_* cached strings).
bool IsTimeAfterOrEqual(const string targetServerHHMM)
{
   int th, tm;
   if(!ParseHHMM(targetServerHHMM, th, tm)) return false;
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   return (dt.hour * 60 + dt.min) >= (th * 60 + tm);
}

//---------------- Pip helper ----------------
// XAUUSD: 1 pip = $1.00 (price moves from 2345 → 2346).
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

//---------------- News Filter ----------------
// Queries the MT5 built-in Economic Calendar for high-impact USD events.
// Returns true  → a high-impact event falls inside the avoidance window,
//                 so order placement should be deferred.
// Returns false → window is clear, proceed normally.
//
// The avoidance window around each event T is:
//   [T - InpNewsMinsAfter * 60 ,  T + InpNewsMinsBefore * 60]
// which is equivalent to checking whether TimeCurrent() falls inside:
//   [T - InpNewsMinsBefore * 60 ,  T + InpNewsMinsAfter * 60]   ← event-centric view
//
// Implementation uses the calendar value's own time field so that
// events are matched by their scheduled release time, not by an
// arbitrary server-time window that would drift with DST changes.
bool IsHighImpactNewsNearby()
{
   if(!InpUseNewsFilter) return false;

   // Fetch events that could overlap [now - After, now + Before].
   datetime from = TimeCurrent() - (datetime)(InpNewsMinsAfter  * 60);
   datetime to   = TimeCurrent() + (datetime)(InpNewsMinsBefore * 60);

   MqlCalendarValue values[];
   // "US" = USD events (NFP, CPI, Fed, JOLTS, ISM, GDP …).
   // These dominate XAUUSD price action.  Change to "" to catch all
   // countries (adds noise from minor releases).
   int count = CalendarValueHistory(values, from, to, "US");

   if(count <= 0) return false;

   for(int i = 0; i < count; i++)
   {
      MqlCalendarEvent ev;
      if(!CalendarEventById(values[i].event_id, ev)) continue;

      // Only block on HIGH importance — moderate/low releases are noise
      // for a breakout strategy that trades the NY open range.
      if(ev.importance != CALENDAR_IMPORTANCE_HIGH) continue;

      // Confirm the scheduled time is truly inside our avoidance window.
      datetime ev_time = values[i].time;
      if(ev_time < from || ev_time > to) continue;

      if(InpDebugPrint)
         PrintFormat("NEWS FILTER: High-impact USD event '%s' at %s — "
                     "order placement deferred (within %d min before / %d min after window).",
                     ev.name, TimeToString(ev_time, TIME_DATE | TIME_MINUTES),
                     InpNewsMinsBefore, InpNewsMinsAfter);

      return true;   // One match is enough to block entry
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
      trade.PositionClose(pt);
   }
}

//---------------- Daily protector ----------------
void ResetDailyProtector()
{
   g_daily_start_balance = AccountInfoDouble(ACCOUNT_BALANCE);
   g_killswitch          = false;
   g_orders_placed_today = false;
   g_consec_losses       = 0;   // reset daily — day limit, not permanent halt
   SaveState();
}

void CheckEquityProtector()
{
   if(g_daily_start_balance <= 0) return;

   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
   double current = MathMin(balance, equity);   // lower of both, matches FTMO methodology
   double dd      = g_daily_start_balance - current;
   double maxdd   = g_daily_start_balance * (InpMaxDailyLossPct / 100.0);

   if(dd >= maxdd && !g_killswitch)
   {
      Print("KILLSWITCH: Daily loss limit reached. DrawDown=$", DoubleToString(dd, 2),
            " Limit=$", DoubleToString(maxdd, 2));
      g_killswitch = true;
      SaveState();
   }

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

bool BuildRange(double &hi, double &lo)
{
   hi = -DBL_MAX;
   lo =  DBL_MAX;

   ENUM_TIMEFRAMES tf = MapTFMins(InpRangeTFMins);
   datetime tStart = TodayAt(g_svr_mon_start);
   datetime tEnd   = TodayAt(g_svr_entry) - 1;  // 1 sec before entry = only fully closed bars

   if(tStart == 0 || tEnd == 0 || tEnd <= tStart) return false;

   // Use bar-shift lookup + position-based CopyRates.
   // The datetime-range overload of CopyRates can silently return 0 bars
   // inside the MT5 Strategy Tester even when the data exists; the
   // position-based overload is reliable in both live and backtesting.
   int sh_start = iBarShift(_Symbol, tf, tStart, false); // older  → higher shift
   int sh_end   = iBarShift(_Symbol, tf, tEnd,   false); // newer  → lower  shift

   if(sh_start < 0 || sh_end < 0)
   {
      Print("BuildRange: iBarShift failed. tStart=", TimeToString(tStart),
            " tEnd=", TimeToString(tEnd));
      return false;
   }

   // Guard against unexpected reversal
   if(sh_start < sh_end) { int t = sh_start; sh_start = sh_end; sh_end = t; }

   int count = sh_start - sh_end + 1;
   if(count <= 0) return false;

   MqlRates rates[];
   ArraySetAsSeries(rates, false);
   // start_pos = sh_end (most-recent bar in our window); copies count bars back in time
   int copied = CopyRates(_Symbol, tf, sh_end, count, rates);
   if(copied <= 0)
   {
      Print("BuildRange: CopyRates returned 0. sh_start=", sh_start,
            " sh_end=", sh_end, " count=", count, " TF=", EnumToString(tf));
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

   // ---- News filter -------------------------------------------------------
   // If a high-impact USD event is approaching or has just passed, wait.
   // The EA will retry on every tick until the window clears OR the expiry
   // time is reached (in which case the day is skipped — safer for prop
   // firms than trading into a news spike).
   if(IsHighImpactNewsNearby()) return false;
   // ------------------------------------------------------------------------

   double hi, lo;
   if(!BuildRange(hi, lo)) return false;

   double pip    = PipSize();
   double tp_pips = InpTakeProfitPips > 0.0
                    ? InpTakeProfitPips
                    : ((hi - lo) / pip) * InpTPRangeMultiplier;
   double offset = InpOffsetPips * pip;

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
                          ORDER_TIME_SPECIFIED, expiry, "NY BuyStop");
      if(!ok1)
         Print("BuyStop failed. Err=", GetLastError(),
               " Price=", buyPrice, " Lots=", lotBuy, " SL=", slBuy, " TP=", tpBuy);
   }

   if(lotSell > 0.0)
   {
      ok2 = trade.SellStop(lotSell, sellPrice, _Symbol, slSell, tpSell,
                           ORDER_TIME_SPECIFIED, expiry, "NY SellStop");
      if(!ok2)
         Print("SellStop failed. Err=", GetLastError(),
               " Price=", sellPrice, " Lots=", lotSell, " SL=", slSell, " TP=", tpSell);
   }

   if(ok1 || ok2)
   {
      Print("Orders placed. Range Hi=", hi, " Lo=", lo,
            " RangeH=", DoubleToString((hi-lo)/pip,1), "pip  TP=", DoubleToString(tp_pips,1), "pip",
            " BuyStop=", buyPrice, " SellStop=", sellPrice,
            " Expiry(server)=", TimeToString(expiry));
      g_orders_placed_today = true;
      SaveState();
      return true;
   }
   return false;
}

//---------------- Cancel opposing pending after one side fills ----------------
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

//---------------- Break-even stop ----------------
// Called on every tick. Once a position's floating profit crosses InpBreakEvenPips,
// the SL is moved to entry price + InpBreakEvenBuffer pips.  This guarantees that a
// position that "goes green" can never turn into a full SL loss — worst case it exits
// at a small gain (buffer) covering the spread.  The trailing stop then takes over
// and tightens from there.
void ApplyBreakEven()
{
   if(InpBreakEvenPips <= 0.0) return;

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
         if(profit_pips < InpBreakEvenPips) continue;

         double beSL = NormalizeDouble(open + (InpBreakEvenBuffer * pip), _Digits);
         if(sl >= beSL) continue;   // already at or above BE level — do nothing

         if(InpDebugPrint)
            PrintFormat("BREAK-EVEN BUY: profit=%.1f pip  SL %.5f → %.5f (entry + %.0f pip buffer)",
                        profit_pips, sl, beSL, InpBreakEvenBuffer);
         trade.PositionModify(pt, beSL, tp);
      }
      else if(type == POSITION_TYPE_SELL)
      {
         double profit_pips = (open - ask) / pip;
         if(profit_pips < InpBreakEvenPips) continue;

         double beSL = NormalizeDouble(open - (InpBreakEvenBuffer * pip), _Digits);
         if(sl != 0.0 && sl <= beSL) continue;   // already at or below BE level — do nothing

         if(InpDebugPrint)
            PrintFormat("BREAK-EVEN SELL: profit=%.1f pip  SL %.5f → %.5f (entry - %.0f pip buffer)",
                        profit_pips, sl, beSL, InpBreakEvenBuffer);
         trade.PositionModify(pt, beSL, tp);
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

   bool newsBlock = IsHighImpactNewsNearby();

   Print("ServerTime=",  TimeToString(TimeCurrent(), TIME_SECONDS),
         " NYTime=",     CurrentNYTime(),
         " EntryAfter=", (IsTimeAfterOrEqual(g_svr_entry)  ? "YES" : "NO"),
         " Expired=",    (IsTimeAfterOrEqual(g_svr_expiry) ? "YES" : "NO"),
         " Placed=",     (g_orders_placed_today ? "YES" : "NO"),
         " KS=",         (g_killswitch          ? "YES" : "NO"),
         " NewsBlock=",  (newsBlock             ? "YES" : "NO"),
         " ConsecLoss=", g_consec_losses,
         " Balance=",    AccountInfoDouble(ACCOUNT_BALANCE),
         " FreeMargin=", AccountInfoDouble(ACCOUNT_MARGIN_FREE));
}

//---------------- Server-time refresh (must be called at OnInit and each new day) ----------------
void RefreshServerTimes()
{
   g_svr_mon_start  = NYToServer(InpMonitoringStart);
   g_svr_mon_end    = NYToServer(InpMonitoringEnd);
   g_svr_entry      = NYToServer(InpEntryTime);
   g_svr_expiry     = NYToServer(InpExpirationTime);
   g_svr_hard_close = InpUseHardClose ? SGTToServer(InpHardCloseTimeSGT) : "";
   g_svr_ny_close   = (InpNYSessionClose != "") ? NYToServer(InpNYSessionClose) : "";

   // Detect midnight wrap: e.g. 17:00 NY EST + UTC+2 broker = "00:00" server.
   // IsTimeAfterOrEqual("00:00") is always true, which would block all order
   // placement.  Flag it so OnTick can skip the check on the same calendar day.
   if(g_svr_ny_close != "")
   {
      int nhh = 0, nmm = 0, ehh = 0, emm = 0;
      ParseHHMM(g_svr_ny_close, nhh, nmm);
      ParseHHMM(g_svr_entry,    ehh, emm);
      g_ny_close_next_day = (nhh * 60 + nmm) <= (ehh * 60 + emm);
   }
   else
      g_ny_close_next_day = false;

   string zone      = IsNYSummerTime(TimeCurrent()) ? "EDT (UTC-4)" : "EST (UTC-5)";
   string hc_str    = g_svr_hard_close != "" ? g_svr_hard_close : "off";
   string nyc_str   = g_svr_ny_close   != "" ? g_svr_ny_close   : "off";
   if(g_ny_close_next_day) nyc_str = nyc_str + " (+1d)";
   Print("NY zone: auto (", zone, ")  Monitor: Server ", g_svr_mon_start, "-", g_svr_mon_end,
         "  Entry: ", g_svr_entry, "  Expiry: ", g_svr_expiry,
         "  HardClose(server): ", hc_str,
         "  NYClose(server): ",   nyc_str);
}

//---------------- Events ----------------
int OnInit()
{
   if(!sym.Name(_Symbol)) return INIT_FAILED;

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippagePoints);

   RefreshServerTimes();

   Print("=== NY Breakout EA initialised ===");
   Print("Broker UTC offset: +", InpBrokerUTCOffset);
   Print("News filter: ", (InpUseNewsFilter ? "ON" : "OFF"),
         " | Before=", InpNewsMinsBefore, "min | After=", InpNewsMinsAfter, "min");
   Print("Break-even: ", (InpBreakEvenPips > 0.0
         ? StringFormat("%.0f pip profit → SL to entry + %.0f pip buffer", InpBreakEvenPips, InpBreakEvenBuffer)
         : "OFF"));
   Print("NY session close: ", (g_svr_ny_close != ""
         ? "server " + g_svr_ny_close + "  (NY " + InpNYSessionClose + ")"
         : "OFF"));

   // Validate that the converted server times are logically ordered.
   // Cross-midnight expiry (e.g. NY 19:00 + UTC+7 = server 02:00) makes
   // IsTimeAfterOrEqual(expiry) permanently true during normal hours, silently
   // blocking all order placement.
   int hh_mon, mm_mon, hh_entry, mm_entry, hh_expiry, mm_expiry;
   ParseHHMM(g_svr_mon_start, hh_mon,    mm_mon);
   ParseHHMM(g_svr_entry,     hh_entry,  mm_entry);
   ParseHHMM(g_svr_expiry,    hh_expiry, mm_expiry);
   int min_mon    = hh_mon    * 60 + mm_mon;
   int min_entry  = hh_entry  * 60 + mm_entry;
   int min_expiry = hh_expiry * 60 + mm_expiry;

   if(min_mon >= min_entry)
   {
      Print("CONFIG ERROR: Monitoring start (server ", g_svr_mon_start,
            ") must be BEFORE entry time (server ", g_svr_entry, ").");
      Print("  Check: are you entering times in NY time, not server time?");
      Print("  Recommended NY times: Monitor 07:00, Entry 09:00, Expiry 13:00");
      return INIT_FAILED;
   }
   if(min_expiry <= min_entry)
   {
      Print("CONFIG ERROR: Expiry server time (", g_svr_expiry,
            ") is not after entry server time (", g_svr_entry, ").");
      Print("  The NY→server conversion has crossed midnight.");
      Print("  You may have entered old server times into the NY time fields.");
      Print("  Recommended NY times: Monitor 07:00, Entry 09:00, Expiry 13:00");
      return INIT_FAILED;
   }

   g_day_key = iTime(_Symbol, PERIOD_D1, 0);
   LoadState();

   return INIT_SUCCEEDED;
}

void OnTick()
{
   // Skip Saturday (6) and Sunday (0) — no NY session, no point checking windows
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   if(dt.day_of_week == 0 || dt.day_of_week == 6) return;

   if(IsNewDay())
   {
      RefreshServerTimes();   // DST may have changed overnight
      ResetDailyProtector();
   }

   CheckEquityProtector();

   // Hard SGT close — DST-independent cutoff (e.g. 01:00 SGT = 19:00 server for UTC+2).
   // Fires regardless of killswitch state to guarantee position is flat by the configured time.
   if(g_svr_hard_close != "" && IsTimeAfterOrEqual(g_svr_hard_close))
   {
      if(HasActivePosition())
      {
         Print("HARD CLOSE: SGT cutoff (server ", g_svr_hard_close, ") — force-closing all positions.");
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

   // NY session close — exit all positions at end of the NY trading session.
   // Uses DST-aware NY time (via NYToServer) so it auto-adjusts for EDT/EST.
   // This prevents positions from drifting into the quiet Asian session where
   // the original SL would otherwise be hit on a random overnight reversal.
   if(g_svr_ny_close != "" && !g_ny_close_next_day && IsTimeAfterOrEqual(g_svr_ny_close))
   {
      if(HasActivePosition())
      {
         Print("NY SESSION CLOSE (server ", g_svr_ny_close, "): closing all positions.");
         CloseAllPositions();
      }
      if(HasPendingOrders()) DeleteAllPendings();
      return;   // skip order placement — expiry has passed anyway
   }

   if(!g_orders_placed_today && IsTimeAfterOrEqual(g_svr_entry))
      PlaceBreakoutOrders();

   CancelOppositeAfterFill();

   ApplyBreakEven();   // lock in trade at entry once profit threshold reached
   ApplyTrailing();    // trail SL once trade is well in profit
   DebugPrintMinute();
}
