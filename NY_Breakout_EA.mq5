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
//|                                                                  |
//|  PULLBACK FILTER (InpUsePullbackEntry = true):                  |
//|  Instead of placing stop orders at 09:00, the EA watches for:   |
//|  1) price to TOUCH the breakout level (hi+offset / lo-offset),  |
//|  2) PULL BACK inside the range boundary (hi / lo),              |
//|  3) RE-BREAK above/below the level → market order placed.       |
//|  If no setup completes before expiry the day is skipped.        |
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
input double   InpRiskPercent        = 0.8;        // Total risk % per setup (split if both sides). 0.8 → 0.4% per side when split.
input double   InpRiskScaleAfterWin  = 1.0;        // Multiply risk after a winning trade (1.0=off, 1.25=+25%). Cap: 2× InpRiskPercent. Resets each new day.
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

input group "=== TREND FILTER ==="
// Before placing orders the EA reads the last completed candle of the monitoring
// period (on the range timeframe).  If its body-to-range ratio exceeds
// InpTrendMinBodyPct, the candle has a clear directional bias:
//   Bullish candle → only BuyStop is placed  (SellStop skipped)
//   Bearish candle → only SellStop is placed (BuyStop skipped)
//   Doji / small body → no clear bias → both stops are placed as normal
// Set InpUseTrendFilter = false to revert to the original both-sides behaviour.
input bool     InpUseTrendFilter     = true;        // Enable directional bias filter
input double   InpTrendMinBodyPct    = 0.35;        // Min body/range ratio to count as directional (0.35 = 35%)

input group "=== PULLBACK ENTRY FILTER ==="
// When enabled, the EA does NOT place stop orders at the range boundary.
// Instead it runs a 3-step state machine on every tick:
//   Step 1 TOUCH   — price reaches the breakout level (hi+offset / lo-offset)
//   Step 2 RETRACE — price pulls back inside the range boundary (hi / lo)
//   Step 3 RE-BREAK — price breaks the level again → market order placed
// If the expiry window closes before all 3 steps complete, no trade is taken.
// Works with the trend filter: only the bias side is monitored.
input bool     InpUsePullbackEntry   = false;       // Wait for pullback + re-break before entering (false = normal stop orders)

input group "=== BREAK-EVEN STOP ==="
input double   InpBreakEvenPips      = 20.0;        // Move SL to entry+buffer when profit reaches this many pips (0 = disabled)
input double   InpBreakEvenBuffer    = 3.0;         // Extra pips beyond entry for the BE SL (absorbs spread on exit)

input group "=== SESSION CLOSE ==="
input string   InpNYSessionClose     = "17:00";    // Close all positions at this NY time (e.g. "17:00" = 5 pm NY). "" = off

input group "=== TECH ==="
input ulong    InpMagic              = 123456;
input int      InpSlippagePoints     = 20;
input bool     InpDebugPrint         = false;

CTrade      trade;
CSymbolInfo sym;

//---------------- Cached server-time strings ----------------
// Computed once at OnInit (and each new day).  All internal logic uses these.
string   g_svr_mon_start  = "";
string   g_svr_mon_end    = "";
string   g_svr_entry      = "";
string   g_svr_expiry     = "";
string   g_svr_hard_close = "";   // computed from InpHardCloseTimeSGT
string   g_svr_ny_close   = "";   // computed from InpNYSessionClose

//---------------- Persisted daily state ----------------
double   g_daily_start_balance = 0.0;
datetime g_day_key             = 0;
bool     g_killswitch          = false;
bool     g_orders_placed_today = false;
int      g_consec_losses       = 0;
int      g_consec_wins         = 0;    // resets on loss only, not daily
int      g_total_wins_today    = 0;    // resets each new day
int      g_total_losses_today  = 0;    // resets each new day
double   g_risk_scale          = 1.0;  // current risk multiplier; win→scale up (cap 2×); loss/new day→reset

//---------------- Pullback entry state (RAM only — not persisted) ----------------
bool     g_pb_setup_done   = false;   // range computed and levels ready for monitoring
double   g_pb_buy_lvl      = 0.0;     // level price must touch for buy (range hi + offset)
double   g_pb_sell_lvl     = 0.0;     // level price must touch for sell (range lo − offset)
double   g_pb_inner_hi     = 0.0;     // range high — pullback boundary for buy side
double   g_pb_inner_lo     = 0.0;     // range low  — pullback boundary for sell side
bool     g_pb_buy_touched  = false;   // buy level has been touched at least once
bool     g_pb_buy_retrace  = false;   // price pulled back inside range after buy touch
bool     g_pb_sell_touched = false;   // sell level has been touched at least once
bool     g_pb_sell_retrace = false;   // price pulled back inside range after sell touch
int      g_pb_bias         = 0;       // directional bias saved when range was built
double   g_pb_tp_pips      = 0.0;     // TP in pips saved when range was built

//---------------- GlobalVariable persistence keys ----------------
string GVKey_KillSwitch()    { return "KS_" + _Symbol + "_" + (string)InpMagic; }
string GVKey_PlacedToday()   { return "PT_" + _Symbol + "_" + (string)InpMagic; }
string GVKey_DayKey()        { return "DK_" + _Symbol + "_" + (string)InpMagic; }
string GVKey_StartBalance()  { return "SB_" + _Symbol + "_" + (string)InpMagic; }
string GVKey_ConsecLosses()  { return "CL_" + _Symbol + "_" + (string)InpMagic; }
string GVKey_ConsecWins()    { return "CW_" + _Symbol + "_" + (string)InpMagic; }
string GVKey_WinsToday()     { return "WT_" + _Symbol + "_" + (string)InpMagic; }
string GVKey_LossesToday()   { return "LT_" + _Symbol + "_" + (string)InpMagic; }
string GVKey_RiskScale()     { return "RS_" + _Symbol + "_" + (string)InpMagic; }

void SaveState()
{
   GlobalVariableSet(GVKey_DayKey(),       (double)g_day_key);
   GlobalVariableSet(GVKey_KillSwitch(),   g_killswitch          ? 1.0 : 0.0);
   GlobalVariableSet(GVKey_PlacedToday(),  g_orders_placed_today ? 1.0 : 0.0);
   GlobalVariableSet(GVKey_StartBalance(), g_daily_start_balance);
   GlobalVariableSet(GVKey_ConsecLosses(), (double)g_consec_losses);
   GlobalVariableSet(GVKey_ConsecWins(),   (double)g_consec_wins);
   GlobalVariableSet(GVKey_WinsToday(),    (double)g_total_wins_today);
   GlobalVariableSet(GVKey_LossesToday(),  (double)g_total_losses_today);
   GlobalVariableSet(GVKey_RiskScale(),    g_risk_scale);
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
      g_consec_wins         = (int)GlobalVariableGet(GVKey_ConsecWins());
      g_total_wins_today    = (int)GlobalVariableGet(GVKey_WinsToday());
      g_total_losses_today  = (int)GlobalVariableGet(GVKey_LossesToday());
      g_risk_scale          = GlobalVariableGet(GVKey_RiskScale());
      if(g_risk_scale <= 0.0) g_risk_scale = 1.0;   // safety guard

      Print("State restored: KS=", g_killswitch, " Placed=", g_orders_placed_today,
            " Balance=", g_daily_start_balance,
            " ConsecL=", g_consec_losses, " ConsecW=", g_consec_wins,
            " W/L today=", g_total_wins_today, "/", g_total_losses_today,
            " RiskScale=", DoubleToString(g_risk_scale, 3));
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
// NY EST = UTC-5, NY EDT = UTC-4.  Handles midnight wrap in both directions.
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

// Convert a SGT time "HH:MM" (UTC+8) to broker server time "HH:MM".
// DST-independent: SGT is fixed UTC+8 year-round.
string SGTToServer(const string sgtHHMM)
{
   int hh, mm;
   int colon = StringFind(sgtHHMM, ":");
   if(colon <= 0) return sgtHHMM;
   hh = (int)StringToInteger(StringSubstr(sgtHHMM, 0, colon));
   mm = (int)StringToInteger(StringSubstr(sgtHHMM, colon + 1));

   int shift = (InpBrokerUTCOffset - 8) * 60;
   int total = hh * 60 + mm + shift;
   total = ((total % 1440) + 1440) % 1440;

   return StringFormat("%02d:%02d", total / 60, total % 60);
}

// Convenience: returns current NY time as "HH:MM" for debug display.
string CurrentNYTime()
{
   int ny_utc  = IsNYSummerTime(TimeCurrent()) ? -4 : -5;
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

//---------------- Order comment builder ----------------
// Format: "NY BuyStop | W:2 L:0 | Risk:0.80%"
// Shows total effective risk % (base × scale, capped at 2×, before split).
string BuildOrderComment(const string label)
{
   double effectivePct = MathMin(InpRiskPercent * g_risk_scale, InpRiskPercent * 2.0);
   return StringFormat("NY %s | W:%d L:%d | Risk:%.2f%%",
                       label, g_total_wins_today, g_total_losses_today, effectivePct);
}

//---------------- News Filter ----------------
// Queries the MT5 built-in Economic Calendar for high-impact USD events.
// Returns true  → a high-impact event falls inside the avoidance window.
// Returns false → window is clear, proceed normally.
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
         PrintFormat("NEWS FILTER: High-impact USD event '%s' at %s — "
                     "order placement deferred (%d min before / %d min after window).",
                     ev.name, TimeToString(ev_time, TIME_DATE | TIME_MINUTES),
                     InpNewsMinsBefore, InpNewsMinsAfter);

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
   g_consec_losses       = 0;    // consecutive loss counter resets daily
   // g_consec_wins is NOT reset daily — persists until a loss clears it
   g_total_wins_today    = 0;
   g_total_losses_today  = 0;
   g_risk_scale          = 1.0;  // risk scaling resets each day (per spec)

   // Pullback state reset (RAM only — no GV needed)
   g_pb_setup_done   = false;
   g_pb_buy_touched  = false;
   g_pb_buy_retrace  = false;
   g_pb_sell_touched = false;
   g_pb_sell_retrace = false;

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

   // Apply win-scaling, capped at 2× base risk
   double riskPct = MathMin(InpRiskPercent * g_risk_scale, InpRiskPercent * 2.0);
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
   return PERIOD_M15;   // fallback — OnInit warns if InpRangeTFMins is invalid
}

bool BuildRange(double &hi, double &lo)
{
   hi = -DBL_MAX;
   lo =  DBL_MAX;

   ENUM_TIMEFRAMES tf = MapTFMins(InpRangeTFMins);
   datetime tStart = TodayAt(g_svr_mon_start);
   datetime tEnd   = TodayAt(g_svr_entry) - 1;

   if(tStart == 0 || tEnd == 0 || tEnd <= tStart) return false;

   int sh_start = iBarShift(_Symbol, tf, tStart, false);
   int sh_end   = iBarShift(_Symbol, tf, tEnd,   false);

   if(sh_start < 0 || sh_end < 0)
   {
      Print("BuildRange: iBarShift failed. tStart=", TimeToString(tStart),
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

//---------------- Directional bias from last monitoring candle ----------------
// Returns:
//  +1 → bullish conviction  → place BuyStop only
//  -1 → bearish conviction  → place SellStop only
//   0 → indecision / filter off → place both stops
int GetRangeBias()
{
   if(!InpUseTrendFilter) return 0;

   ENUM_TIMEFRAMES tf = MapTFMins(InpRangeTFMins);
   datetime tEnd = TodayAt(g_svr_entry) - 1;

   int sh = iBarShift(_Symbol, tf, tEnd, false);
   if(sh < 0) return 0;

   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   if(CopyRates(_Symbol, tf, sh, 1, rates) != 1) return 0;

   double o     = rates[0].open;
   double c     = rates[0].close;
   double range = rates[0].high - rates[0].low;
   if(range <= 0.0) return 0;

   double bodyPct = MathAbs(c - o) / range;
   if(bodyPct < InpTrendMinBodyPct) return 0;

   return (c > o) ? 1 : -1;
}

//---------------- Order placement (normal stop-order mode) ----------------
bool PlaceBreakoutOrders()
{
   // Per-minute gate-log throttle: logs every gate at most once per minute.
   // This prevents flooding Experts tab every tick while still giving a full
   // diagnostic snapshot of what is blocking or passing at entry time.
   static int _gateMin = -1;
   MqlDateTime _gd; TimeToStruct(TimeCurrent(), _gd);
   bool doLog = InpDebugPrint && (_gd.min != _gateMin);
   if(doLog) _gateMin = _gd.min;

   // GATE 1: Killswitch
   if(doLog) PrintFormat("[GATE] KILLSWITCH    val=%-5s  req=false  → %s",
                         g_killswitch ? "true" : "false",
                         g_killswitch ? "FAIL" : "PASS");
   if(g_killswitch) return false;

   // GATE 2: Already placed today
   if(doLog) PrintFormat("[GATE] PLACED_TODAY  val=%-5s  req=false  → %s",
                         g_orders_placed_today ? "true" : "false",
                         g_orders_placed_today ? "FAIL" : "PASS");
   if(g_orders_placed_today) return false;

   // GATE 3: Open or pending orders for this magic
   bool hasMagicOrders = HasOpenOrPendingForMagic();
   if(doLog) PrintFormat("[GATE] HAS_ORDERS    val=%-5s  req=false  → %s",
                         hasMagicOrders ? "true" : "false",
                         hasMagicOrders ? "FAIL" : "PASS");
   if(hasMagicOrders) return false;

   // GATE 4: Expiry
   bool isExpired = IsTimeAfterOrEqual(g_svr_expiry);
   if(doLog) PrintFormat("[GATE] EXPIRY        time=%s  expiresAt=%s  → %s",
                         TimeToString(TimeCurrent(), TIME_MINUTES), g_svr_expiry,
                         isExpired ? "FAIL(expired)" : "PASS");
   if(isExpired) return false;

   // GATE 5: News filter
   bool newsBlocked = IsHighImpactNewsNearby();
   if(doLog) PrintFormat("[GATE] NEWS_FILTER   blocked=%-5s  req=false  → %s",
                         newsBlocked ? "true" : "false",
                         newsBlocked ? "FAIL(deferred)" : "PASS");
   if(newsBlocked) return false;

   // GATE 6: Range
   double hi, lo;
   bool rangeOk = BuildRange(hi, lo);
   if(doLog) PrintFormat("[GATE] BUILD_RANGE   ok=%-5s  hi=%.2f  lo=%.2f  height=%.1fpip  → %s",
                         rangeOk ? "true" : "false",
                         (hi > -DBL_MAX) ? hi : 0.0, (lo < DBL_MAX) ? lo : 0.0,
                         rangeOk ? (hi - lo) / PipSize() : 0.0,
                         rangeOk ? "PASS" : "FAIL(no bars)");
   if(!rangeOk) return false;

   // Directional bias (informational — gates lot sizes below)
   int bias = GetRangeBias();
   if(doLog) PrintFormat("[GATE] TREND_BIAS    val=%-2d  filter=%s  side=%s",
                         bias, InpUseTrendFilter ? "ON" : "OFF",
                         bias > 0 ? "BUY-ONLY" : bias < 0 ? "SELL-ONLY" : "BOTH");

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

   // Gate each side on bias: skip the side that contradicts the candle direction
   double lotBuy  = (bias >= 0) ? CalcLotByRiskAndMargin(InpStopLossPips, ORDER_TYPE_BUY_STOP,  buyPrice)  : 0.0;
   double lotSell = (bias <= 0) ? CalcLotByRiskAndMargin(InpStopLossPips, ORDER_TYPE_SELL_STOP, sellPrice) : 0.0;

   // GATE 7: Lot sizes
   if(doLog) PrintFormat("[GATE] LOT_SIZES     lotBuy=%.2f  lotSell=%.2f  req=at-least-one>0  → %s",
                         lotBuy, lotSell,
                         (lotBuy <= 0 && lotSell <= 0) ? "FAIL(zero lots)" : "PASS");
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
                          ORDER_TIME_SPECIFIED, expiry, BuildOrderComment("BuyStop"));
      if(!ok1)
         Print("BuyStop failed. Err=", GetLastError(),
               " Price=", buyPrice, " Lots=", lotBuy, " SL=", slBuy, " TP=", tpBuy);
   }

   if(lotSell > 0.0)
   {
      ok2 = trade.SellStop(lotSell, sellPrice, _Symbol, slSell, tpSell,
                           ORDER_TIME_SPECIFIED, expiry, BuildOrderComment("SellStop"));
      if(!ok2)
         Print("SellStop failed. Err=", GetLastError(),
               " Price=", sellPrice, " Lots=", lotSell, " SL=", slSell, " TP=", tpSell);
   }

   if(ok1 || ok2)
   {
      Print("Orders placed. Bias=", (bias > 0 ? "BUY-ONLY" : bias < 0 ? "SELL-ONLY" : "BOTH"),
            " Range Hi=", hi, " Lo=", lo,
            " RangeH=", DoubleToString((hi-lo)/pip, 1), "pip  TP=", DoubleToString(tp_pips, 1), "pip",
            " BuyStop=", buyPrice, " SellStop=", sellPrice,
            " Expiry(server)=", TimeToString(expiry),
            " RiskScale=", DoubleToString(g_risk_scale, 2));
      g_orders_placed_today = true;
      SaveState();
      return true;
   }
   return false;
}

//---------------- Pullback entry: range setup ----------------
// Computes the range and stores breakout levels.  Called once after InpEntryTime
// when InpUsePullbackEntry = true.  No orders are placed here.
void SetupPullback()
{
   if(g_killswitch) return;
   if(IsTimeAfterOrEqual(g_svr_expiry)) return;
   if(IsHighImpactNewsNearby()) return;

   double hi, lo;
   if(!BuildRange(hi, lo)) return;

   double pip    = PipSize();
   double tp_pips = InpTakeProfitPips > 0.0
                    ? InpTakeProfitPips
                    : ((hi - lo) / pip) * InpTPRangeMultiplier;

   g_pb_buy_lvl   = hi + InpOffsetPips * pip;
   g_pb_sell_lvl  = lo - InpOffsetPips * pip;
   g_pb_inner_hi  = hi;
   g_pb_inner_lo  = lo;
   g_pb_bias      = GetRangeBias();
   g_pb_tp_pips   = tp_pips;
   g_pb_setup_done = true;

   Print("PULLBACK SETUP: Range Hi=", hi, " Lo=", lo,
         " BuyLvl=", g_pb_buy_lvl, " SellLvl=", g_pb_sell_lvl,
         " Bias=", (g_pb_bias > 0 ? "BUY-ONLY" : g_pb_bias < 0 ? "SELL-ONLY" : "BOTH"),
         " TP=", DoubleToString(tp_pips, 1), "pip");
}

//---------------- Pullback entry: tick-level state machine ----------------
// Runs on every tick after SetupPullback().  Monitors touch → retrace → re-break.
// On confirmed re-break places a market order.
void CheckPullbackEntry()
{
   if(!g_pb_setup_done || g_orders_placed_today || HasActivePosition()) return;
   if(IsTimeAfterOrEqual(g_svr_expiry)) return;
   if(IsHighImpactNewsNearby()) return;

   double pip = PipSize();
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   // ---- BUY SIDE (only if bias is neutral or bullish) ----
   if(g_pb_bias >= 0)
   {
      // Step 1: Touch — ask reaches or exceeds buy level
      if(!g_pb_buy_touched && ask >= g_pb_buy_lvl)
      {
         g_pb_buy_touched = true;
         if(InpDebugPrint)
            PrintFormat("[PULLBACK] BUY TOUCH: ask=%.2f >= buyLvl=%.2f", ask, g_pb_buy_lvl);
      }

      // Step 2: Retrace — after touch, bid drops back below range high (inside range)
      if(g_pb_buy_touched && !g_pb_buy_retrace && bid < g_pb_inner_hi)
      {
         g_pb_buy_retrace = true;
         if(InpDebugPrint)
            PrintFormat("[PULLBACK] BUY RETRACE: bid=%.2f < innerHi=%.2f", bid, g_pb_inner_hi);
      }

      // Step 3: Re-break — after retrace, ask breaks above buy level again → market buy
      if(g_pb_buy_retrace && ask >= g_pb_buy_lvl)
      {
         double entry = ask;
         double sl    = NormalizeDouble(entry - (InpStopLossPips * pip), _Digits);
         double tp    = NormalizeDouble(entry + (g_pb_tp_pips    * pip), _Digits);
         double lots  = CalcLotByRiskAndMargin(InpStopLossPips, ORDER_TYPE_BUY, entry);

         if(lots > 0.0)
         {
            trade.SetExpertMagicNumber(InpMagic);
            trade.SetDeviationInPoints(InpSlippagePoints);
            if(trade.Buy(lots, _Symbol, 0.0, sl, tp, BuildOrderComment("PB Buy")))
            {
               Print("PULLBACK BUY executed. entry≈", entry, " SL=", sl,
                     " TP=", tp, " Lots=", lots);
               g_orders_placed_today = true;
               SaveState();
               return;
            }
            else
               Print("PULLBACK BUY failed. Err=", GetLastError());
         }
         // Reset to prevent immediate re-fire if price stays above level
         g_pb_buy_retrace = false;
         g_pb_buy_touched = false;
      }
   }

   // ---- SELL SIDE (only if bias is neutral or bearish, and no buy trade placed) ----
   if(g_pb_bias <= 0 && !g_orders_placed_today)
   {
      // Step 1: Touch — bid reaches or drops below sell level
      if(!g_pb_sell_touched && bid <= g_pb_sell_lvl)
      {
         g_pb_sell_touched = true;
         if(InpDebugPrint)
            PrintFormat("[PULLBACK] SELL TOUCH: bid=%.2f <= sellLvl=%.2f", bid, g_pb_sell_lvl);
      }

      // Step 2: Retrace — after touch, ask rises back above range low (inside range)
      if(g_pb_sell_touched && !g_pb_sell_retrace && ask > g_pb_inner_lo)
      {
         g_pb_sell_retrace = true;
         if(InpDebugPrint)
            PrintFormat("[PULLBACK] SELL RETRACE: ask=%.2f > innerLo=%.2f", ask, g_pb_inner_lo);
      }

      // Step 3: Re-break — after retrace, bid drops below sell level again → market sell
      if(g_pb_sell_retrace && bid <= g_pb_sell_lvl)
      {
         double entry = bid;
         double sl    = NormalizeDouble(entry + (InpStopLossPips * pip), _Digits);
         double tp    = NormalizeDouble(entry - (g_pb_tp_pips    * pip), _Digits);
         double lots  = CalcLotByRiskAndMargin(InpStopLossPips, ORDER_TYPE_SELL, entry);

         if(lots > 0.0)
         {
            trade.SetExpertMagicNumber(InpMagic);
            trade.SetDeviationInPoints(InpSlippagePoints);
            if(trade.Sell(lots, _Symbol, 0.0, sl, tp, BuildOrderComment("PB Sell")))
            {
               Print("PULLBACK SELL executed. entry≈", entry, " SL=", sl,
                     " TP=", tp, " Lots=", lots);
               g_orders_placed_today = true;
               SaveState();
               return;
            }
            else
               Print("PULLBACK SELL failed. Err=", GetLastError());
         }
         g_pb_sell_retrace = false;
         g_pb_sell_touched = false;
      }
   }
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
         if(sl >= beSL) continue;
         if(InpDebugPrint)
            PrintFormat("BREAK-EVEN BUY: profit=%.1fpip  SL %.5f → %.5f", profit_pips, sl, beSL);
         trade.PositionModify(pt, beSL, tp);
      }
      else if(type == POSITION_TYPE_SELL)
      {
         double profit_pips = (open - ask) / pip;
         if(profit_pips < InpBreakEvenPips) continue;
         double beSL = NormalizeDouble(open - (InpBreakEvenBuffer * pip), _Digits);
         if(sl != 0.0 && sl <= beSL) continue;
         if(InpDebugPrint)
            PrintFormat("BREAK-EVEN SELL: profit=%.1fpip  SL %.5f → %.5f", profit_pips, sl, beSL);
         trade.PositionModify(pt, beSL, tp);
      }
   }
}

//---------------- Win / loss tracking ----------------
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
      g_consec_wins = 0;          // win streak broken
      g_total_losses_today++;
      g_risk_scale = 1.0;         // loss resets the scale
      Print("Trade CLOSED LOSS. ConsecL=", g_consec_losses,
            " W/L today=", g_total_wins_today, "/", g_total_losses_today,
            " RiskScale reset to 1.0");
   }
   else
   {
      g_consec_losses = 0;
      g_consec_wins++;
      g_total_wins_today++;
      // Scale up for next trade, capped at 2× base
      g_risk_scale = MathMin(g_risk_scale * InpRiskScaleAfterWin, 2.0);
      Print("Trade CLOSED WIN. ConsecW=", g_consec_wins,
            " W/L today=", g_total_wins_today, "/", g_total_losses_today,
            " RiskScale now=", DoubleToString(g_risk_scale, 3));
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

   // Gate status snapshot — shows which OnTick() conditions are active this minute
   bool entryOpen  = IsTimeAfterOrEqual(g_svr_entry);
   bool isExpired  = IsTimeAfterOrEqual(g_svr_expiry);
   bool newsBlock  = IsHighImpactNewsNearby();
   bool sgtFiring  = (g_svr_hard_close != "" && IsTimeAfterOrEqual(g_svr_hard_close));
   bool nyClosing  = (g_svr_ny_close   != "" && IsTimeAfterOrEqual(g_svr_ny_close));

   PrintFormat("[STATUS] %s NY=%s | EntryOpen:%s Expired:%s | Placed:%s KS:%s | News:%s NYClose:%s SGT:%s",
               TimeToString(TimeCurrent(), TIME_SECONDS), CurrentNYTime(),
               entryOpen ? "Y" : "N", isExpired ? "Y" : "N",
               g_orders_placed_today ? "Y" : "N", g_killswitch ? "Y" : "N",
               newsBlock ? "BLOCK" : "clear", nyClosing ? "Y" : "N", sgtFiring ? "Y" : "N");

   PrintFormat("[STATS]  W:%d L:%d | ConsecW:%d ConsecL:%d | RiskScale:%.2f | Bal:%.2f Margin:%.2f",
               g_total_wins_today, g_total_losses_today,
               g_consec_wins, g_consec_losses,
               g_risk_scale,
               AccountInfoDouble(ACCOUNT_BALANCE),
               AccountInfoDouble(ACCOUNT_MARGIN_FREE));

   if(InpUsePullbackEntry)
      PrintFormat("[PULLBK] Setup:%s Bias:%+d | Buy: Touch:%s Retrace:%s | Sell: Touch:%s Retrace:%s",
                  g_pb_setup_done ? "Y" : "N", g_pb_bias,
                  g_pb_buy_touched  ? "Y" : "N", g_pb_buy_retrace  ? "Y" : "N",
                  g_pb_sell_touched ? "Y" : "N", g_pb_sell_retrace ? "Y" : "N");
}

//---------------- Server-time refresh (called at OnInit and each new day) ----------------
void RefreshServerTimes()
{
   g_svr_mon_start  = NYToServer(InpMonitoringStart);
   g_svr_mon_end    = NYToServer(InpMonitoringEnd);
   g_svr_entry      = NYToServer(InpEntryTime);
   g_svr_expiry     = NYToServer(InpExpirationTime);
   g_svr_hard_close = InpUseHardClose ? SGTToServer(InpHardCloseTimeSGT) : "";
   g_svr_ny_close   = (InpNYSessionClose != "") ? NYToServer(InpNYSessionClose) : "";

   string zone    = IsNYSummerTime(TimeCurrent()) ? "EDT (UTC-4)" : "EST (UTC-5)";
   string hc_str  = g_svr_hard_close != "" ? g_svr_hard_close : "off";
   string nyc_str = g_svr_ny_close   != "" ? g_svr_ny_close   : "off";
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
   Print("Risk: base=", InpRiskPercent, "%  scaleAfterWin=", InpRiskScaleAfterWin,
         "  (split=", InpSplitRiskBothSides ? "YES" : "NO", ")");
   Print("News filter: ", (InpUseNewsFilter ? "ON" : "OFF"),
         " | Before=", InpNewsMinsBefore, "min | After=", InpNewsMinsAfter, "min");
   Print("Trend filter: ", (InpUseTrendFilter ? "ON" : "OFF"),
         " | MinBodyPct=", InpTrendMinBodyPct);
   Print("Entry mode: ", (InpUsePullbackEntry ? "PULLBACK (market order on re-break)" : "STOP ORDERS"));
   Print("Break-even: ", (InpBreakEvenPips > 0.0
         ? StringFormat("%.0fpip profit → SL to entry + %.0fpip buffer", InpBreakEvenPips, InpBreakEvenBuffer)
         : "OFF"));
   Print("NY session close: ", (g_svr_ny_close != ""
         ? "server " + g_svr_ny_close + "  (NY " + InpNYSessionClose + ")"
         : "OFF"));

   // InpRangeTFMins validation (warn only — does not fail init)
   bool tfValid = (InpRangeTFMins == 1  || InpRangeTFMins == 5  || InpRangeTFMins == 15 ||
                   InpRangeTFMins == 30 || InpRangeTFMins == 60);
   if(!tfValid)
      Print("CONFIG WARNING: InpRangeTFMins=", InpRangeTFMins,
            " is not one of 1/5/15/30/60 — EA will default to M15 bars. Please correct.");

   // Validate server-time ordering
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
   // GATE: Weekend — no NY session
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   if(dt.day_of_week == 0 || dt.day_of_week == 6) return;

   if(IsNewDay())
   {
      RefreshServerTimes();   // DST may have changed overnight
      ResetDailyProtector();
   }

   CheckEquityProtector();

   // GATE: Hard SGT close — DST-independent cutoff; fires regardless of killswitch.
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

   // GATE: Killswitch
   if(g_killswitch)
   {
      if(InpDebugPrint) Print("[GATE] KILLSWITCH active — closing all and halting.");
      if(HasActivePosition()) CloseAllPositions();
      if(HasPendingOrders())  DeleteAllPendings();
      return;
   }

   // Past expiry: cancel any pending stop orders still open
   if(IsTimeAfterOrEqual(g_svr_expiry))
      DeleteAllPendings();

   // GATE: NY session close — exit positions at end of NY session (DST-aware).
   if(g_svr_ny_close != "" && IsTimeAfterOrEqual(g_svr_ny_close))
   {
      if(HasActivePosition())
      {
         Print("NY SESSION CLOSE (server ", g_svr_ny_close, "): closing all positions.");
         CloseAllPositions();
      }
      if(HasPendingOrders()) DeleteAllPendings();
      return;
   }

   // GATE: Entry time — gate for order placement
   bool entryWindowOpen = IsTimeAfterOrEqual(g_svr_entry);

   if(InpUsePullbackEntry)
   {
      // Pullback mode: two-step process
      // Step A: compute range and store levels (once per day)
      if(!g_pb_setup_done && !g_orders_placed_today && entryWindowOpen)
         SetupPullback();

      // Step B: watch for touch → retrace → re-break on every tick
      if(g_pb_setup_done && !g_orders_placed_today)
         CheckPullbackEntry();
   }
   else
   {
      // Normal mode: place stop orders as soon as entry window opens
      if(!g_orders_placed_today && entryWindowOpen)
         PlaceBreakoutOrders();

      CancelOppositeAfterFill();
   }

   ApplyBreakEven();   // lock in a trade that has gone into profit
   ApplyTrailing();    // trail SL once trade is well in profit
   DebugPrintMinute();
}
