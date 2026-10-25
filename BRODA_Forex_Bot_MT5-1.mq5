//+------------------------------------------------------------------+
//| BRODA Forex Bot - MT5 Expert Advisor                             |
//| Demo-first educational starter. Review and backtest before use.   |
//+------------------------------------------------------------------+
#property strict
#property version   "1.00"
#property description "BRODA Forex Bot: EMA crossover + RSI, ATR exits, risk limits."

#include <Trade/Trade.mqh>
CTrade trade;

// ---- Inputs -------------------------------------------------------
input bool   DemoAccountOnly       = true;    // Refuse to trade live accounts
input double RiskPercent           = 0.50;    // Equity risk per trade (%)
input double DailyLossLimitPercent = 2.00;    // Stop new trades after this realized daily loss (% of current equity)
input int    MaxTradesPerDay       = 3;
input int    FastEMAPeriod         = 20;
input int    SlowEMAPeriod         = 50;
input int    RSIPeriod             = 14;
input double BuyRSIMin             = 50.0;
input double BuyRSIMax             = 70.0;
input double SellRSIMin            = 30.0;
input double SellRSIMax            = 50.0;
input int    ATRPeriod             = 14;
input double ATRStopMultiplier     = 1.5;
input double RewardRiskRatio       = 2.0;
input int    MaxSpreadPoints       = 30;      // Points, broker-dependent
input ulong  MagicNumber           = 26102501;
input int    SlippagePoints        = 10;

// ---- Indicator handles -------------------------------------------
int fastMAHandle = INVALID_HANDLE;
int slowMAHandle = INVALID_HANDLE;
int rsiHandle    = INVALID_HANDLE;
int atrHandle    = INVALID_HANDLE;
datetime lastBarTime = 0;

//+------------------------------------------------------------------+
int OnInit()
{
   if(RiskPercent <= 0.0 || RiskPercent > 2.0)
   {
      Print("RiskPercent must be greater than 0 and no more than 2.");
      return INIT_PARAMETERS_INCORRECT;
   }
   if(DailyLossLimitPercent <= 0.0 || MaxTradesPerDay < 1)
   {
      Print("Check daily loss limit and max trades inputs.");
      return INIT_PARAMETERS_INCORRECT;
   }

   fastMAHandle = iMA(_Symbol, PERIOD_CURRENT, FastEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   slowMAHandle = iMA(_Symbol, PERIOD_CURRENT, SlowEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   rsiHandle    = iRSI(_Symbol, PERIOD_CURRENT, RSIPeriod, PRICE_CLOSE);
   atrHandle    = iATR(_Symbol, PERIOD_CURRENT, ATRPeriod);

   if(fastMAHandle == INVALID_HANDLE || slowMAHandle == INVALID_HANDLE ||
      rsiHandle == INVALID_HANDLE || atrHandle == INVALID_HANDLE)
   {
      Print("Could not create indicator handles. Check symbol/timeframe.");
      return INIT_FAILED;
   }

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(SlippagePoints);
   Print("BRODA Forex Bot initialized on ", _Symbol,
         ". Attach to EURUSD and start on a DEMO account.");
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(fastMAHandle != INVALID_HANDLE) IndicatorRelease(fastMAHandle);
   if(slowMAHandle != INVALID_HANDLE) IndicatorRelease(slowMAHandle);
   if(rsiHandle    != INVALID_HANDLE) IndicatorRelease(rsiHandle);
   if(atrHandle    != INVALID_HANDLE) IndicatorRelease(atrHandle);
}

//+------------------------------------------------------------------+
void OnTick()
{
   if(DemoAccountOnly &&
      (ENUM_ACCOUNT_TRADE_MODE)AccountInfoInteger(ACCOUNT_TRADE_MODE) != ACCOUNT_TRADE_MODE_DEMO)
   {
      Comment("BRODA Forex Bot: DEMO ACCOUNT ONLY mode is enabled.");
      return;
   }
   Comment("BRODA Forex Bot | ", _Symbol, " | Demo-first EA");

   if(!IsNewBar()) return;
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) ||
      !MQLInfoInteger(MQL_TRADE_ALLOWED))
   {
      Print("Trading is not enabled in the terminal/EA settings.");
      return;
   }

   if(CurrentSpreadPoints() > MaxSpreadPoints)
   {
      Print("Spread too high; skipping this bar.");
      return;
   }

   if(CountTodayEntries() >= MaxTradesPerDay)
   {
      Print("Daily trade limit reached.");
      return;
   }

   if(TodaysRealizedProfit() <= -DailyLossLimitMoney())
   {
      Print("Daily realized-loss limit reached; no new trades today.");
      return;
   }

   // One open position at a time for this symbol and this EA.
   if(HasOurOpenPosition()) return;

   double fast[], slow[], rsi[], atr[];
   ArrayResize(fast, 3);
   ArrayResize(slow, 3);
   ArrayResize(rsi, 3);
   ArrayResize(atr, 3);
   ArraySetAsSeries(fast, true);
   ArraySetAsSeries(slow, true);
   ArraySetAsSeries(rsi, true);
   ArraySetAsSeries(atr, true);

   if(CopyBuffer(fastMAHandle, 0, 0, 3, fast) < 3 ||
      CopyBuffer(slowMAHandle, 0, 0, 3, slow) < 3 ||
      CopyBuffer(rsiHandle,    0, 0, 3, rsi)  < 3 ||
      CopyBuffer(atrHandle,    0, 0, 3, atr)  < 3)
   {
      Print("Waiting for enough indicator data.");
      return;
   }

   // Use closed candles: index 1 is the last completed candle; index 2 is prior.
   bool bullishCross = (fast[2] <= slow[2] && fast[1] > slow[1]);
   bool bearishCross = (fast[2] >= slow[2] && fast[1] < slow[1]);

   if(atr[1] <= 0.0) return;

   if(bullishCross && rsi[1] >= BuyRSIMin && rsi[1] <= BuyRSIMax)
      OpenTrade(ORDER_TYPE_BUY, atr[1]);
   else if(bearishCross && rsi[1] >= SellRSIMin && rsi[1] <= SellRSIMax)
      OpenTrade(ORDER_TYPE_SELL, atr[1]);
}

//+------------------------------------------------------------------+
bool IsNewBar()
{
   datetime currentBar = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(currentBar == 0 || currentBar == lastBarTime) return false;
   lastBarTime = currentBar;
   return true;
}

//+------------------------------------------------------------------+
double CurrentSpreadPoints()
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(ask <= 0 || bid <= 0 || _Point <= 0) return 1e9;
   return (ask - bid) / _Point;
}

//+------------------------------------------------------------------+
bool HasOurOpenPosition()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
         (ulong)PositionGetInteger(POSITION_MAGIC) == MagicNumber)
         return true;
   }
   return false;
}

//+------------------------------------------------------------------+
datetime ServerDayStart()
{
   MqlDateTime dt;
   TimeToStruct(TimeTradeServer(), dt);
   dt.hour = 0;
   dt.min  = 0;
   dt.sec  = 0;
   return StructToTime(dt);
}

//+------------------------------------------------------------------+
int CountTodayEntries()
{
   if(!HistorySelect(ServerDayStart(), TimeTradeServer())) return 0;
   int count = 0;
   int total = HistoryDealsTotal();

   for(int i = 0; i < total; i++)
   {
      ulong deal = HistoryDealGetTicket(i);
      if(deal == 0) continue;
      if(HistoryDealGetString(deal, DEAL_SYMBOL) != _Symbol) continue;
      if((ulong)HistoryDealGetInteger(deal, DEAL_MAGIC) != MagicNumber) continue;
      if((ENUM_DEAL_ENTRY)HistoryDealGetInteger(deal, DEAL_ENTRY) == DEAL_ENTRY_IN)
         count++;
   }
   return count;
}

//+------------------------------------------------------------------+
double TodaysRealizedProfit()
{
   if(!HistorySelect(ServerDayStart(), TimeTradeServer())) return 0.0;
   double totalProfit = 0.0;

   for(int i = 0; i < HistoryDealsTotal(); i++)
   {
      ulong deal = HistoryDealGetTicket(i);
      if(deal == 0) continue;
      if(HistoryDealGetString(deal, DEAL_SYMBOL) != _Symbol) continue;
      if((ulong)HistoryDealGetInteger(deal, DEAL_MAGIC) != MagicNumber) continue;

      totalProfit += HistoryDealGetDouble(deal, DEAL_PROFIT);
      totalProfit += HistoryDealGetDouble(deal, DEAL_SWAP);
      totalProfit += HistoryDealGetDouble(deal, DEAL_COMMISSION);
   }
   return totalProfit;
}

//+------------------------------------------------------------------+
double DailyLossLimitMoney()
{
   return AccountInfoDouble(ACCOUNT_EQUITY) * DailyLossLimitPercent / 100.0;
}

//+------------------------------------------------------------------+
double CalculateVolume(double stopDistance)
{
   double equity   = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskCash = equity * RiskPercent / 100.0;
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickVal  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double volMin   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double volMax   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double volStep  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(stopDistance <= 0 || tickSize <= 0 || tickVal <= 0 ||
      volMin <= 0 || volStep <= 0) return 0.0;

   double lossPerLot = (stopDistance / tickSize) * tickVal;
   if(lossPerLot <= 0) return 0.0;

   double volume = riskCash / lossPerLot;
   volume = MathMin(volume, volMax);
   volume = MathFloor(volume / volStep) * volStep;
   volume = NormalizeDouble(volume, 8);

   // Do not force minimum lot if it would exceed the requested risk.
   if(volume < volMin) return 0.0;
   return volume;
}

//+------------------------------------------------------------------+
void OpenTrade(ENUM_ORDER_TYPE orderType, double atrValue)
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   double stopDistance = atrValue * ATRStopMultiplier;
   double minStop = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   if(stopDistance < minStop) stopDistance = minStop;
   if(stopDistance <= 0) return;

   double volume = CalculateVolume(stopDistance);
   if(volume <= 0.0)
   {
      Print("Calculated lot size is below broker minimum for this risk setting; no trade opened.");
      return;
   }

   bool sent = false;
   if(orderType == ORDER_TYPE_BUY)
   {
      double sl = NormalizeDouble(ask - stopDistance, digits);
      double tp = NormalizeDouble(ask + stopDistance * RewardRiskRatio, digits);
      sent = trade.Buy(volume, _Symbol, 0.0, sl, tp, "BRODA EMA-RSI BUY");
   }
   else if(orderType == ORDER_TYPE_SELL)
   {
      double sl = NormalizeDouble(bid + stopDistance, digits);
      double tp = NormalizeDouble(bid - stopDistance * RewardRiskRatio, digits);
      sent = trade.Sell(volume, _Symbol, 0.0, sl, tp, "BRODA EMA-RSI SELL");
   }

   if(!sent)
      Print("Trade request failed. Retcode=", trade.ResultRetcode(),
            " ", trade.ResultRetcodeDescription());
   else
      Print("Trade request sent. Volume=", DoubleToString(volume, 2),
            " retcode=", trade.ResultRetcodeDescription());
}
//+------------------------------------------------------------------+
