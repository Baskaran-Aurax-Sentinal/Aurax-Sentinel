//+------------------------------------------------------------------+
//|                                      BTCUSD_Grid_Pattern_v1_10.mq5 |
//|                         Grid with candle patterns, broker TP, dash |
//+------------------------------------------------------------------+
#property copyright "Copyright 2025"
#property version   "1.10"
#property strict

#include <Trade\Trade.mqh>

//------------------------- Inputs ----------------------------------
input string   InpEAName             = "BTCUSD_Grid_Pattern";
input bool     InpAutoStart          = true;      // Default auto start. false = wait for manual trigger
input bool     InpManualTrigger      = false;     // If true, waits for manual order magic 0
input double   InpGridStep           = 100.0;     // Grid step in dollars
input double   InpLotSize            = 0.01;      // Fixed lot size
input int      InpMaxGridLevels      = 10;        // Maximum levels each side from base
input bool     InpUsePatternExit     = true;      // Use M15 candlestick patterns to exit/reverse
input bool     InpUseBrokerTP        = true;      // Apply broker-level TP
input double   InpBrokerTP_USD       = 20.0;      // Broker TP distance in USD
input double   InpTrailTrigger       = 2.0;       // Start trailing when profit >= $2
input double   InpTrailStep          = 1.0;       // Trail step in USD
input int      InpSlippagePoints     = 50;
input long     InpMagic              = 20250522;
input bool     InpShowDashboard      = true;

//------------------------- Globals ---------------------------------
CTrade         g_trade;
double         g_initialPrice          = 0.0;
int            g_lastBuyLevel          = 0;       // Negative side levels: -1, -2, -3...
int            g_lastSellLevel         = 0;       // Positive side levels: 1, 2, 3...
bool           g_gridActive            = false;
bool           g_patternTradeActive    = false;
double         g_patternTradeOpenPrice = 0.0;
double         g_lastProfitLock        = 0.0;
datetime       g_lastPatternBarTime    = 0;

//+------------------------------------------------------------------+
double NormalizeLots(double lots)
{
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   lots = MathMax(minLot, MathMin(maxLot, lots));
   if(step > 0)
      lots = MathFloor(lots / step) * step;

   return NormalizeDouble(lots, 2);
}

//+------------------------------------------------------------------+
bool IsEAPosition()
{
   return (PositionGetString(POSITION_SYMBOL) == _Symbol &&
           (long)PositionGetInteger(POSITION_MAGIC) == InpMagic);
}

//+------------------------------------------------------------------+
bool IsManualPosition()
{
   return (PositionGetString(POSITION_SYMBOL) == _Symbol &&
           (long)PositionGetInteger(POSITION_MAGIC) == 0);
}

//+------------------------------------------------------------------+
bool FindManualBase(double &basePrice)
{
   bool found = false;
   datetime oldest = LONG_MAX;
   basePrice = 0.0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;

      if(!IsManualPosition()) continue;

      datetime t = (datetime)PositionGetInteger(POSITION_TIME);
      if(t < oldest)
      {
         oldest = t;
         basePrice = PositionGetDouble(POSITION_PRICE_OPEN);
         found = true;
      }
   }

   return found;
}

//+------------------------------------------------------------------+
int CurrentLevel()
{
   if(g_initialPrice <= 0 || InpGridStep <= 0)
      return 0;

   double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double diff  = price - g_initialPrice;

   if(diff >= InpGridStep)
      return (int)MathFloor(diff / InpGridStep);

   if(diff <= -InpGridStep)
      return (int)MathCeil(diff / InpGridStep);

   return 0;
}

//+------------------------------------------------------------------+
int CountPositions(int side = -1)
{
   int count = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;

      if(!IsEAPosition()) continue;

      long type = (long)PositionGetInteger(POSITION_TYPE);
      if(side == -1 || type == side)
         count++;
   }

   return count;
}

//+------------------------------------------------------------------+
double FloatingPL()
{
   double pl = 0.0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;

      if(!IsEAPosition()) continue;

      pl += PositionGetDouble(POSITION_PROFIT);
      pl += PositionGetDouble(POSITION_SWAP);
   }

   return pl;
}

//+------------------------------------------------------------------+
bool OpenBuy(string comment)
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double tp = 0.0;

   if(InpUseBrokerTP)
      tp = NormalizeDouble(ask + InpBrokerTP_USD, digits);

   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetDeviationInPoints(InpSlippagePoints);

   return g_trade.Buy(NormalizeLots(InpLotSize), _Symbol, ask, 0.0, tp, comment);
}

//+------------------------------------------------------------------+
bool OpenSell(string comment)
{
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double tp = 0.0;

   if(InpUseBrokerTP)
      tp = NormalizeDouble(bid - InpBrokerTP_USD, digits);

   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetDeviationInPoints(InpSlippagePoints);

   return g_trade.Sell(NormalizeLots(InpLotSize), _Symbol, bid, 0.0, tp, comment);
}

//+------------------------------------------------------------------+
void CheckStart()
{
   if(g_gridActive)
      return;

   double manualBase = 0.0;

   if(InpManualTrigger || !InpAutoStart)
   {
      if(FindManualBase(manualBase))
      {
         g_initialPrice = manualBase;
         g_lastBuyLevel = CurrentLevel();
         g_lastSellLevel = CurrentLevel();
         g_gridActive = true;
         Print(InpEAName, ": Manual trigger started. Base = ", DoubleToString(g_initialPrice, _Digits));
      }
      return;
   }

   g_initialPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   g_lastBuyLevel = 0;
   g_lastSellLevel = 0;
   g_gridActive = true;

   Print(InpEAName, ": Auto started. Base = ", DoubleToString(g_initialPrice, _Digits));
}

//+------------------------------------------------------------------+
//| Core grid preserved: BUY on drop, SELL on rise                    |
//| v1.10: no backfill, only the next fresh current level             |
//+------------------------------------------------------------------+
void ManageGrid()
{
   if(!g_gridActive || g_initialPrice <= 0)
      return;

   if(g_patternTradeActive)
      return;

   int level = CurrentLevel();

   if(level > 0)
   {
      if(level > InpMaxGridLevels)
         return;

      if(level != g_lastSellLevel)
      {
         if(OpenSell(InpEAName + "_SELL_L" + IntegerToString(level)))
         {
            g_lastSellLevel = level;
            Print("Fresh SELL grid opened at level ", level);
         }
      }
   }

   if(level < 0)
   {
      if(MathAbs(level) > InpMaxGridLevels)
         return;

      if(level != g_lastBuyLevel)
      {
         if(OpenBuy(InpEAName + "_BUY_L" + IntegerToString(level)))
         {
            g_lastBuyLevel = level;
            Print("Fresh BUY grid opened at level ", level);
         }
      }
   }

   if(level == 0)
   {
      g_lastBuyLevel = 0;
      g_lastSellLevel = 0;
   }
}

//+------------------------------------------------------------------+
bool IsEveningStar()
{
   MqlRates candles[3];
   if(CopyRates(_Symbol, PERIOD_M15, 1, 3, candles) != 3)
      return false;

   double body1 = MathAbs(candles[2].close - candles[2].open);
   double body2 = MathAbs(candles[1].close - candles[1].open);
   double body3 = MathAbs(candles[0].close - candles[0].open);

   bool firstBullish = candles[2].close > candles[2].open;
   bool thirdBearish = candles[0].close < candles[0].open;
   bool smallMiddle  = body2 < body1 * 0.5 && body2 < body3 * 0.7;
   double midFirst   = (candles[2].open + candles[2].close) / 2.0;

   return (firstBullish && thirdBearish && smallMiddle && candles[0].close < midFirst);
}

//+------------------------------------------------------------------+
bool IsHangingHammer()
{
   MqlRates candle[1];
   if(CopyRates(_Symbol, PERIOD_M15, 1, 1, candle) != 1)
      return false;

   double body = MathAbs(candle[0].close - candle[0].open);
   double range = candle[0].high - candle[0].low;
   if(body <= 0 || range <= 0) return false;

   double lowerWick = MathMin(candle[0].open, candle[0].close) - candle[0].low;
   double upperWick = candle[0].high - MathMax(candle[0].open, candle[0].close);

   if(lowerWick >= 2.0 * body && upperWick <= body * 0.7 && body <= range * 0.4)
   {
      MqlRates prev[2];
      if(CopyRates(_Symbol, PERIOD_M15, 2, 2, prev) == 2)
         return (prev[0].close > prev[0].open && prev[1].close > prev[1].open);
   }

   return false;
}

//+------------------------------------------------------------------+
bool IsReverseHammer()
{
   MqlRates candle[1];
   if(CopyRates(_Symbol, PERIOD_M15, 1, 1, candle) != 1)
      return false;

   double body = MathAbs(candle[0].close - candle[0].open);
   double range = candle[0].high - candle[0].low;
   if(body <= 0 || range <= 0) return false;

   double upperWick = candle[0].high - MathMax(candle[0].open, candle[0].close);
   double lowerWick = MathMin(candle[0].open, candle[0].close) - candle[0].low;

   if(upperWick >= 2.0 * body && lowerWick <= body * 0.7 && body <= range * 0.4)
   {
      MqlRates prev[2];
      if(CopyRates(_Symbol, PERIOD_M15, 2, 2, prev) == 2)
         return (prev[0].close < prev[0].open && prev[1].close < prev[1].open);
   }

   return false;
}

//+------------------------------------------------------------------+
void CheckPatternAndReverse()
{
   datetime barTime = iTime(_Symbol, PERIOD_M15, 1);
   if(barTime <= 0 || barTime == g_lastPatternBarTime)
      return;

   g_lastPatternBarTime = barTime;

   bool bearishSignal = IsEveningStar() || IsHangingHammer();
   bool bullishSignal = IsReverseHammer();

   if(!(bearishSignal || bullishSignal))
      return;

   CloseAllPositions();

   g_patternTradeActive = true;

   bool success = false;
   double price = 0.0;

   if(bearishSignal)
   {
      price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      success = OpenSell(InpEAName + "_PATTERN_SELL");
   }
   else
   {
      price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      success = OpenBuy(InpEAName + "_PATTERN_BUY");
   }

   if(success)
   {
      g_patternTradeOpenPrice = price;
      g_lastProfitLock = 0.0;
      g_initialPrice = price;
      g_lastBuyLevel = 0;
      g_lastSellLevel = 0;

      Print("Pattern signal: ", bearishSignal ? "Bearish - SELL" : "Bullish - BUY",
            " opened at ", DoubleToString(price, _Digits));
   }
}

//+------------------------------------------------------------------+
void ManageTrailingStop()
{
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;

      if(!IsEAPosition()) continue;

      double currentProfit = PositionGetDouble(POSITION_PROFIT);
      if(currentProfit < InpTrailTrigger)
         continue;

      int profitFloor = (int)MathFloor(currentProfit);

      if(profitFloor > g_lastProfitLock && profitFloor >= (int)InpTrailTrigger)
      {
         double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
         long type = (long)PositionGetInteger(POSITION_TYPE);
         double lockProfit = profitFloor - InpTrailStep;
         if(lockProfit < 0) lockProfit = 0;

         double newSL = 0.0;

         if(type == POSITION_TYPE_BUY)
            newSL = NormalizeDouble(openPrice + lockProfit, digits);
         else
            newSL = NormalizeDouble(openPrice - lockProfit, digits);

         if(g_trade.PositionModify(ticket, newSL, 0.0))
         {
            g_lastProfitLock = profitFloor;
            Print("Trailing SL moved to ", DoubleToString(newSL, digits));
         }
      }
   }
}

//+------------------------------------------------------------------+
void CloseAllPositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;

      if(IsEAPosition())
         g_trade.PositionClose(ticket);
   }
}

//+------------------------------------------------------------------+
void Dashboard()
{
   if(!InpShowDashboard)
   {
      Comment("");
      return;
   }

   string mode = InpAutoStart && !InpManualTrigger ? "AUTO START" : "MANUAL TRIGGER";
   string status = g_gridActive ? "ACTIVE" : "WAITING";
   if(g_patternTradeActive) status = "PATTERN TRADE ACTIVE";

   int level = CurrentLevel();

   string text;
   text  = "==== " + InpEAName + " v1.10 ====\n";
   text += "Symbol: " + _Symbol + "\n";
   text += "Mode: " + mode + "\n";
   text += "Status: " + status + "\n";
   text += "Base Price: " + DoubleToString(g_initialPrice, _Digits) + "\n";
   text += "Current Level: " + IntegerToString(level) + "\n";
   text += "Last BUY Level: " + IntegerToString(g_lastBuyLevel) + "\n";
   text += "Last SELL Level: " + IntegerToString(g_lastSellLevel) + "\n";
   text += "Grid Step: $" + DoubleToString(InpGridStep, 2) + "\n";
   text += "No Backfill: ON - only next fresh level\n\n";

   text += "BUY Orders: " + IntegerToString(CountPositions(POSITION_TYPE_BUY)) + "\n";
   text += "SELL Orders: " + IntegerToString(CountPositions(POSITION_TYPE_SELL)) + "\n";
   text += "Total Orders: " + IntegerToString(CountPositions()) + "\n";
   text += "Floating P/L: $" + DoubleToString(FloatingPL(), 2) + "\n\n";

   text += "Broker TP: " + string(InpUseBrokerTP ? "ON" : "OFF") + " | $" + DoubleToString(InpBrokerTP_USD, 2) + "\n";
   text += "Pattern Exit M15: " + string(InpUsePatternExit ? "ON" : "OFF") + "\n";
   text += "Bearish pattern: Close all + open SELL\n";
   text += "Bullish pattern: Close all + open BUY\n";

   Comment(text);
}

//+------------------------------------------------------------------+
int OnInit()
{
   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetDeviationInPoints(InpSlippagePoints);

   Print(InpEAName, " v1.10 initialized on ", _Symbol);
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   Comment("");
}

//+------------------------------------------------------------------+
void OnTick()
{
   CheckStart();

   if(g_gridActive)
      ManageGrid();

   if(InpUsePatternExit)
      CheckPatternAndReverse();

   if(g_patternTradeActive)
      ManageTrailingStop();

   Dashboard();
}
//+------------------------------------------------------------------+
