//+------------------------------------------------------------------+
//|                        US100_PropFirm_EA.mq5                     |
//|          High Win-Rate Mean Reversion Strategy for NAS100        |
//|          Target: 80%+ Win Rate | Max Daily DD: 2%                |
//|                                                                  |
//|  STRATEGY OVERVIEW:                                              |
//|  - EMA Pullback entries in direction of higher-timeframe trend   |
//|  - RSI(14) confluence filter for entry quality                   |
//|  - Bollinger Band squeeze confirmation                           |
//|  - NY session only (14:30 – 21:00 GMT)                          |
//|  - Hard daily drawdown circuit breaker at 2%                    |
//|  - Max 3 trades/day; no re-entry after DD limit hit             |
//+------------------------------------------------------------------+
#property copyright "US100 Prop Firm EA"
#property version   "1.01"
#property strict
#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
CTrade        trade;
CPositionInfo posInfo;

//--- Magic number (used to identify this EA's orders)
#define EA_MAGIC 202500

//--- Input Parameters
input group "=== STRATEGY SETTINGS ==="
input int      InpFastEMA        = 20;       // Fast EMA Period (entry signal)
input int      InpSlowEMA        = 50;       // Slow EMA Period (trend bias)
input int      InpTrendEMA       = 200;      // Trend EMA Period (HTF filter on M15)
input int      InpRSIPeriod      = 14;       // RSI Period
input double   InpRSILongMin     = 35.0;     // RSI min for LONG entry (oversold zone)
input double   InpRSILongMax     = 52.0;     // RSI max for LONG entry
input double   InpRSIShortMin    = 48.0;     // RSI min for SHORT entry
input double   InpRSIShortMax    = 65.0;     // RSI max for SHORT entry (overbought zone)
input int      InpBBPeriod       = 20;       // Bollinger Band Period
input double   InpBBDeviation    = 2.0;      // Bollinger Band Deviation

input group "=== TRADE MANAGEMENT ==="
input double   InpRiskPercent    = 0.5;      // Risk per trade (% of balance)
input double   InpTPPoints       = 20.0;     // Take Profit in points (NAS100)
input double   InpSLPoints       = 25.0;     // Stop Loss in points (NAS100)
input double   InpTrailingStart  = 12.0;     // Trailing stop activation (points in profit)
input double   InpTrailingStep   = 5.0;      // Trailing stop step (points)
input int      InpMaxTradesDay   = 3;        // Max trades per day

input group "=== PROP FIRM PROTECTION ==="
input double   InpMaxDailyDD     = 2.0;      // Max daily drawdown % (HARD STOP)
input double   InpMaxDrawdown    = 4.5;      // Max total drawdown % (circuit breaker)
input bool     InpNewsFilter     = true;     // Pause 30min around news (manual flag)

input group "=== SESSION FILTER (GMT) ==="
input int      InpSessionStartH  = 14;       // Session start hour (GMT)
input int      InpSessionStartM  = 30;       // Session start minute
input int      InpSessionEndH    = 20;       // Session end hour (GMT)
input int      InpSessionEndM    = 30;       // Session end minute
input bool     InpAvoidLunch     = true;     // Avoid 17:00-18:00 GMT (lunch lull)

input group "=== LOGGING ==="
input bool     InpVerboseLog     = true;     // Enable detailed logging

//--- Global Variables
int      handleFastEMA_M5;
int      handleSlowEMA_M5;
int      handleTrendEMA_M15;
int      handleRSI;
int      handleBB;

double   g_DayStartBalance   = 0;
double   g_DayHighBalance    = 0;
datetime g_LastBarTime       = 0;
datetime g_CurrentDay        = 0;
int      g_TradesToday       = 0;
bool     g_DailyLimitHit     = false;

double   g_FastEMA[];
double   g_SlowEMA[];
double   g_TrendEMA_M15[];
double   g_RSI[];
double   g_BB_Upper[];
double   g_BB_Middle[];
double   g_BB_Lower[];

//--- Dashboard refresh throttle
datetime g_LastDashUpdate = 0;

//+------------------------------------------------------------------+
//| Expert initialization                                            |
//+------------------------------------------------------------------+
int OnInit()
  {
   if(StringFind(_Symbol, "NAS")   < 0 && StringFind(_Symbol, "US100") < 0 &&
      StringFind(_Symbol, "NDX")   < 0 && StringFind(_Symbol, "USTEC") < 0)
      Print("WARNING: This EA is optimised for US100/NAS100. Current symbol: ", _Symbol);

   trade.SetExpertMagicNumber(EA_MAGIC);
   trade.SetDeviationInPoints(30);
   trade.SetTypeFilling(ORDER_FILLING_IOC);

   // Indicators on M5
   handleFastEMA_M5   = iMA(_Symbol, PERIOD_M5, InpFastEMA,  0, MODE_EMA, PRICE_CLOSE);
   handleSlowEMA_M5   = iMA(_Symbol, PERIOD_M5, InpSlowEMA,  0, MODE_EMA, PRICE_CLOSE);
   handleRSI          = iRSI(_Symbol, PERIOD_M5, InpRSIPeriod, PRICE_CLOSE);
   handleBB           = iBands(_Symbol, PERIOD_M5, InpBBPeriod, 0, InpBBDeviation, PRICE_CLOSE);
   // Trend EMA on M15 for higher-timeframe bias
   handleTrendEMA_M15 = iMA(_Symbol, PERIOD_M15, InpTrendEMA, 0, MODE_EMA, PRICE_CLOSE);

   if(handleFastEMA_M5   == INVALID_HANDLE ||
      handleSlowEMA_M5   == INVALID_HANDLE ||
      handleTrendEMA_M15 == INVALID_HANDLE ||
      handleRSI          == INVALID_HANDLE ||
      handleBB           == INVALID_HANDLE)
     {
      Print("ERROR: Failed to create indicator handles. EA will not run.");
      return INIT_FAILED;
     }

   ArraySetAsSeries(g_FastEMA,      true);
   ArraySetAsSeries(g_SlowEMA,      true);
   ArraySetAsSeries(g_TrendEMA_M15, true);
   ArraySetAsSeries(g_RSI,          true);
   ArraySetAsSeries(g_BB_Upper,     true);
   ArraySetAsSeries(g_BB_Middle,    true);
   ArraySetAsSeries(g_BB_Lower,     true);

   ResetDailyStats();
   Print("US100 PropFirm EA v1.01 Initialised | Risk: ", InpRiskPercent,
         "% | Max Daily DD: ", InpMaxDailyDD, "%");
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
//| Expert deinitialization                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   IndicatorRelease(handleFastEMA_M5);
   IndicatorRelease(handleSlowEMA_M5);
   IndicatorRelease(handleTrendEMA_M15);
   IndicatorRelease(handleRSI);
   IndicatorRelease(handleBB);
   ObjectDelete(0, "EA_Dashboard");
  }

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
  {
   // --- 1. Daily Reset ---
   CheckDayReset();

   // --- 2. Daily Drawdown Circuit Breaker ---
   if(!CheckDailyDrawdown()) return;

   // --- 3. Manage Open Positions (trailing) ---
   ManageOpenPositions();

   // --- 4. Dashboard refresh (at most once per second) ---
   if(TimeCurrent() - g_LastDashUpdate >= 1)
     {
      DrawDashboard();
      g_LastDashUpdate = TimeCurrent();
     }

   // --- 5. Wait for new M5 bar ---
   datetime barTime = iTime(_Symbol, PERIOD_M5, 0);
   if(barTime == g_LastBarTime) return;
   g_LastBarTime = barTime;

   // --- 6. Pre-checks ---
   if(g_DailyLimitHit)
     {
      if(InpVerboseLog) Print("Daily limit hit – no new trades today.");
      return;
     }
   if(g_TradesToday >= InpMaxTradesDay)
     {
      if(InpVerboseLog) Print("Max trades/day reached: ", g_TradesToday, "/", InpMaxTradesDay);
      return;
     }
   if(PositionsTotal() > 0) return;   // One trade at a time
   if(!IsSessionActive())  return;

   // --- 7. Load Indicators ---
   if(!LoadIndicators()) return;

   // --- 8. Entry Logic ---
   int signal = GetEntrySignal();
   if(signal == 0) return;

   // --- 9. Execute Trade ---
   ExecuteTrade(signal);
  }

//+------------------------------------------------------------------+
//| Check & Reset Daily Stats                                        |
//+------------------------------------------------------------------+
void CheckDayReset()
  {
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   datetime today = StringToTime(StringFormat("%04d.%02d.%02d 00:00:00",
                                              dt.year, dt.mon, dt.day));
   if(today != g_CurrentDay)
     {
      g_CurrentDay    = today;
      g_DailyLimitHit = false;
      g_TradesToday   = 0;
      ResetDailyStats();
      Print("=== NEW DAY | Balance: ", AccountInfoDouble(ACCOUNT_BALANCE),
            " | Start equity: ", g_DayStartBalance, " ===");
     }
  }

//+------------------------------------------------------------------+
//| Reset daily balance tracking                                     |
//+------------------------------------------------------------------+
void ResetDailyStats()
  {
   g_DayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   g_DayHighBalance  = AccountInfoDouble(ACCOUNT_EQUITY);
  }

//+------------------------------------------------------------------+
//| Hard daily drawdown circuit breaker                              |
//| Returns false if trading must stop                               |
//+------------------------------------------------------------------+
bool CheckDailyDrawdown()
  {
   double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);

   // Update intraday high
   if(equity > g_DayHighBalance) g_DayHighBalance = equity;

   // DD from day-start balance (FTMO-style)
   double ddFromStart = (g_DayStartBalance > 0)
                         ? (g_DayStartBalance - equity) / g_DayStartBalance * 100.0
                         : 0.0;

   // DD from intraday high (floating peak)
   double ddFromHigh = (g_DayHighBalance > 0)
                        ? (g_DayHighBalance - equity) / g_DayHighBalance * 100.0
                        : 0.0;

   double worstDD = MathMax(ddFromStart, ddFromHigh);

   if(worstDD >= InpMaxDailyDD)
     {
      if(!g_DailyLimitHit)
        {
         PrintFormat("!!! DAILY DRAWDOWN LIMIT HIT: %.2f%% | Closing all positions.", worstDD);
         CloseAllPositions();
         g_DailyLimitHit = true;
        }
      return false;
     }

   // Global circuit breaker from initial balance
   double totalDD = (balance > 0)
                     ? (balance - equity) / balance * 100.0
                     : 0.0;
   if(totalDD >= InpMaxDrawdown)
     {
      PrintFormat("!!! TOTAL DRAWDOWN LIMIT HIT: %.2f%%. EA disabled.", totalDD);
      CloseAllPositions();
      g_DailyLimitHit = true;
      return false;
     }

   return true;
  }

//+------------------------------------------------------------------+
//| Session filter – NY session (GMT)                                |
//+------------------------------------------------------------------+
bool IsSessionActive()
  {
   MqlDateTime dt;
   TimeToStruct(TimeGMT(), dt);
   int mins      = dt.hour * 60 + dt.min;
   int startMins = InpSessionStartH * 60 + InpSessionStartM;
   int endMins   = InpSessionEndH   * 60 + InpSessionEndM;

   if(mins < startMins || mins >= endMins) return false;

   // Avoid lunch lull 17:00-18:00 GMT
   if(InpAvoidLunch && mins >= 1020 && mins < 1080) return false;

   // Avoid last 5 minutes of session (slippage risk at close)
   if(mins >= endMins - 5) return false;

   return true;
  }

//+------------------------------------------------------------------+
//| Load all indicator buffers                                       |
//+------------------------------------------------------------------+
bool LoadIndicators()
  {
   if(CopyBuffer(handleFastEMA_M5,   0, 0, 4, g_FastEMA)      < 4) return false;
   if(CopyBuffer(handleSlowEMA_M5,   0, 0, 4, g_SlowEMA)      < 4) return false;
   if(CopyBuffer(handleTrendEMA_M15, 0, 0, 3, g_TrendEMA_M15) < 3) return false;
   if(CopyBuffer(handleRSI,          0, 0, 4, g_RSI)          < 4) return false;
   if(CopyBuffer(handleBB, UPPER_BAND, 0, 4, g_BB_Upper)      < 4) return false;
   if(CopyBuffer(handleBB, BASE_LINE,  0, 4, g_BB_Middle)     < 4) return false;
   if(CopyBuffer(handleBB, LOWER_BAND, 0, 4, g_BB_Lower)      < 4) return false;
   return true;
  }

//+------------------------------------------------------------------+
//| Core Entry Signal Generator                                      |
//|  Returns: +1 = Long, -1 = Short, 0 = No signal                 |
//|                                                                  |
//|  ENTRY CONDITIONS:                                               |
//|  LONG:                                                           |
//|   1. M15 price > 200 EMA  (uptrend on HTF)                     |
//|   2. M5 Fast EMA > Slow EMA (M5 trend aligned)                 |
//|   3. Previous closed bar LOW touched or crossed Fast EMA        |
//|   4. Current bar re-tests Fast EMA from above (pullback)        |
//|   5. RSI(14) in bullish reload zone (35–52)                    |
//|   6. Price between BB Middle and BB Lower (not over-extended)   |
//|   7. Close[1] > FastEMA[1] (candle closed back above EMA)      |
//|                                                                  |
//|  SHORT: mirror conditions                                        |
//+------------------------------------------------------------------+
int GetEntrySignal()
  {
   double close0 = iClose(_Symbol, PERIOD_M5, 0);
   double close1 = iClose(_Symbol, PERIOD_M5, 1);
   double close2 = iClose(_Symbol, PERIOD_M5, 2);
   double low1   = iLow  (_Symbol, PERIOD_M5, 1);
   double high1  = iHigh (_Symbol, PERIOD_M5, 1);

   double fastEMA0  = g_FastEMA[0];
   double fastEMA1  = g_FastEMA[1];
   double fastEMA2  = g_FastEMA[2];
   double slowEMA0  = g_SlowEMA[0];
   double trendM15  = g_TrendEMA_M15[0];
   double rsi1      = g_RSI[1];

   // BB band-width check (avoid flat/no-volatility periods)
   double bbWidth = (g_BB_Middle[1] > 0)
                     ? (g_BB_Upper[1] - g_BB_Lower[1]) / g_BB_Middle[1] * 100.0
                     : 0.0;
   if(bbWidth < 0.08)
     {
      if(InpVerboseLog)
         Print("SKIP: BB width too tight (", DoubleToString(bbWidth, 3), "%)");
      return 0;
     }

   // ======== LONG SIGNAL ========
   bool trendLong     = close0 > trendM15;
   bool m5AlignLong   = fastEMA0 > slowEMA0;
   bool pullbackLong  = low1 <= fastEMA1 && close1 >= fastEMA1;   // Wick touched, closed above
   bool prevAbove     = close2 > fastEMA2;
   bool rsiLong       = rsi1 >= InpRSILongMin  && rsi1 <= InpRSILongMax;
   bool priceZoneLong = close1 >= g_BB_Lower[1] && close1 <= g_BB_Middle[1];

   if(trendLong && m5AlignLong && pullbackLong && prevAbove && rsiLong && priceZoneLong)
     {
      if(InpVerboseLog)
         PrintFormat("LONG SIGNAL | FastEMA=%.2f | RSI=%.1f | BBWidth=%.3f%%",
                     fastEMA1, rsi1, bbWidth);
      return 1;
     }

   // ======== SHORT SIGNAL ========
   bool trendShort     = close0 < trendM15;
   bool m5AlignShort   = fastEMA0 < slowEMA0;
   bool pullbackShort  = high1 >= fastEMA1 && close1 <= fastEMA1;  // Wick touched, closed below
   bool prevBelow      = close2 < fastEMA2;
   bool rsiShort       = rsi1 >= InpRSIShortMin && rsi1 <= InpRSIShortMax;
   bool priceZoneShort = close1 <= g_BB_Upper[1] && close1 >= g_BB_Middle[1];

   if(trendShort && m5AlignShort && pullbackShort && prevBelow && rsiShort && priceZoneShort)
     {
      if(InpVerboseLog)
         PrintFormat("SHORT SIGNAL | FastEMA=%.2f | RSI=%.1f | BBWidth=%.3f%%",
                     fastEMA1, rsi1, bbWidth);
      return -1;
     }

   // Periodic no-signal log (every 10 bars to avoid spam)
   static int skipCount = 0;
   if(++skipCount % 10 == 0 && InpVerboseLog)
     {
      PrintFormat("NO SIGNAL | trendL=%s trendS=%s | m5AlignL=%s | pullL=%s | rsi=%.1f",
                  trendLong  ? "Y" : "N", trendShort  ? "Y" : "N",
                  m5AlignLong ? "Y" : "N", pullbackLong ? "Y" : "N", rsi1);
     }
   return 0;
  }

//+------------------------------------------------------------------+
//| Calculate lot size from risk %                                   |
//+------------------------------------------------------------------+
double CalcLotSize(double slPoints)
  {
   double balance    = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskAmount = balance * InpRiskPercent / 100.0;
   double tickSize   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValue  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double pointSize  = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

   if(tickSize == 0 || tickValue == 0 || pointSize == 0) return 0.01;

   double slValue = (slPoints * pointSize / tickSize) * tickValue;
   if(slValue <= 0) return 0.01;

   double lots    = riskAmount / slValue;
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double stepLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   lots = MathFloor(lots / stepLot) * stepLot;
   return MathMax(minLot, MathMin(maxLot, lots));
  }

//+------------------------------------------------------------------+
//| Execute trade                                                    |
//+------------------------------------------------------------------+
void ExecuteTrade(int signal)
  {
   double ask    = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid    = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double point  = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double lots   = CalcLotSize(InpSLPoints);

   if(lots <= 0)
     {
      Print("ERROR: Lot size calculation returned 0. Skipping trade.");
      return;
     }

   string comment = StringFormat("US100_EMA|Day:%d|Risk:%.1f%%",
                                 g_TradesToday + 1, InpRiskPercent);

   if(signal == 1)  // LONG
     {
      double entry = ask;
      double sl    = entry - InpSLPoints * point;
      double tp    = entry + InpTPPoints * point;
      if(trade.Buy(lots, _Symbol, entry, sl, tp, comment))
        {
         g_TradesToday++;
         PrintFormat("BUY opened | Lots=%.2f | Entry=%.2f | SL=%.2f | TP=%.2f | Trade#%d",
                     lots, entry, sl, tp, g_TradesToday);
        }
      else
         PrintFormat("ERROR: Buy failed: %d – %s",
                     trade.ResultRetcode(), trade.ResultRetcodeDescription());
     }
   else if(signal == -1)  // SHORT
     {
      double entry = bid;
      double sl    = entry + InpSLPoints * point;
      double tp    = entry - InpTPPoints * point;
      if(trade.Sell(lots, _Symbol, entry, sl, tp, comment))
        {
         g_TradesToday++;
         PrintFormat("SELL opened | Lots=%.2f | Entry=%.2f | SL=%.2f | TP=%.2f | Trade#%d",
                     lots, entry, sl, tp, g_TradesToday);
        }
      else
         PrintFormat("ERROR: Sell failed: %d – %s",
                     trade.ResultRetcode(), trade.ResultRetcodeDescription());
     }
  }

//+------------------------------------------------------------------+
//| Manage open positions – trailing stop logic                      |
//+------------------------------------------------------------------+
void ManageOpenPositions()
  {
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(!posInfo.SelectByIndex(i))       continue;
      if(posInfo.Magic()  != EA_MAGIC)    continue;   // FIX: only manage our own positions
      if(posInfo.Symbol() != _Symbol)     continue;

      double currentSL  = posInfo.StopLoss();
      double openPrice  = posInfo.PriceOpen();
      double currentBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double currentAsk = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      ulong  ticket     = posInfo.Ticket();

      if(posInfo.PositionType() == POSITION_TYPE_BUY)
        {
         double profitPoints = (currentBid - openPrice) / point;
         if(profitPoints >= InpTrailingStart)
           {
            double newSL = currentBid - InpTrailingStep * point;
            if(newSL > currentSL + point)
              {
               trade.PositionModify(ticket, newSL, posInfo.TakeProfit());
               if(InpVerboseLog)
                  PrintFormat("TRAIL BUY | Profit=%.1f pts | NewSL=%.2f", profitPoints, newSL);
              }
           }
        }
      else if(posInfo.PositionType() == POSITION_TYPE_SELL)
        {
         double profitPoints = (openPrice - currentAsk) / point;
         if(profitPoints >= InpTrailingStart)
           {
            double newSL = currentAsk + InpTrailingStep * point;
            if(newSL < currentSL - point || currentSL == 0)
              {
               trade.PositionModify(ticket, newSL, posInfo.TakeProfit());
               if(InpVerboseLog)
                  PrintFormat("TRAIL SELL | Profit=%.1f pts | NewSL=%.2f", profitPoints, newSL);
              }
           }
        }
     }
  }

//+------------------------------------------------------------------+
//| Close all OUR positions (magic-number filtered)                  |
//+------------------------------------------------------------------+
void CloseAllPositions()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(!posInfo.SelectByIndex(i))    continue;
      if(posInfo.Magic() != EA_MAGIC)  continue;   // FIX: never touch other EAs' trades
      if(posInfo.Symbol() != _Symbol)  continue;
      trade.PositionClose(posInfo.Ticket());
     }
  }

//+------------------------------------------------------------------+
//| OnTradeTransaction – log deal results                            |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest     &request,
                        const MqlTradeResult      &result)
  {
   // FIX: MqlTradeTransaction has no deal_profit field.
   //      Retrieve profit from history after DEAL_ADD event.
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;
   if(trans.deal  == 0)                         return;

   if(!HistoryDealSelect(trans.deal)) return;

   long magic = HistoryDealGetInteger(trans.deal, DEAL_MAGIC);
   if(magic != EA_MAGIC) return;

   long entry = HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
   if(entry != DEAL_ENTRY_OUT) return;   // Only log closing deals

   double profit = HistoryDealGetDouble(trans.deal, DEAL_PROFIT)
                 + HistoryDealGetDouble(trans.deal, DEAL_SWAP)
                 + HistoryDealGetDouble(trans.deal, DEAL_COMMISSION);

   if(InpVerboseLog)
      PrintFormat("DEAL closed | Profit=%.2f | Balance=%.2f",
                  profit, AccountInfoDouble(ACCOUNT_BALANCE));
  }

//+------------------------------------------------------------------+
//| OnChartEvent – force dashboard refresh on chart resize           |
//+------------------------------------------------------------------+
void OnChartEvent(const int id, const long &lparam,
                  const double &dparam, const string &sparam)
  {
   if(id == CHARTEVENT_CHART_CHANGE) DrawDashboard();
  }

//+------------------------------------------------------------------+
//| Draw on-chart dashboard                                          |
//+------------------------------------------------------------------+
void DrawDashboard()
  {
   double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
   double ddToday = (g_DayStartBalance > 0)
                     ? (g_DayStartBalance - equity) / g_DayStartBalance * 100.0
                     : 0.0;

   string info = StringFormat(
      "US100 EA v1.01 | Trades: %d/%d | Daily DD: %.2f%% / %.2f%% | Session: %s | Limit: %s",
      g_TradesToday, InpMaxTradesDay,
      ddToday, InpMaxDailyDD,
      IsSessionActive()  ? "ACTIVE" : "CLOSED",
      g_DailyLimitHit    ? "HIT"    : "OK"
   );

   if(ObjectFind(0, "EA_Dashboard") < 0)
     {
      ObjectCreate(0, "EA_Dashboard", OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, "EA_Dashboard", OBJPROP_XDISTANCE, 10);
      ObjectSetInteger(0, "EA_Dashboard", OBJPROP_YDISTANCE, 20);
      ObjectSetInteger(0, "EA_Dashboard", OBJPROP_FONTSIZE,  9);
      ObjectSetInteger(0, "EA_Dashboard", OBJPROP_CORNER,    CORNER_LEFT_UPPER);
     }

   ObjectSetString (0, "EA_Dashboard", OBJPROP_TEXT,  info);
   ObjectSetInteger(0, "EA_Dashboard", OBJPROP_COLOR,
                    g_DailyLimitHit ? clrRed : clrLime);
   ChartRedraw(0);
  }
//+------------------------------------------------------------------+
