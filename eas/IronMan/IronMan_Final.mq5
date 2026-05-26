//+------------------------------------------------------------------+
//|                                                   IronMan.mq5    |
//|                  Manual Trigger BTCUSD Hedge Grid + M15 Exit     |
//|                                                                  |
//|  Logic:                                                          |
//|  - Manual BUY or SELL on same symbol starts the cycle             |
//|  - Base price = first detected manual order price                 |
//|  - Every GridStepUSD movement from base level, open BUY + SELL    |
//|  - No duplicate pair in same grid level                           |
//|  - M15 reversal candle patterns close matching side               |
//|  - Broker-level TP at entry + optional individual trailing        |
//+------------------------------------------------------------------+
#property strict
#property version   "1.00"
#property description "IronMan - BTCUSD manual trigger hedge grid with M15 candle-pattern exits"

#include <Trade/Trade.mqh>
CTrade trade;

//------------------------- Inputs ----------------------------------
input string InpEAName                  = "IronMan";
input long   MagicNumber                = 20260523;

input double LotSize                    = 0.01;
input double GridStepUSD                = 100.0;
input int    MaxEAPositions             = 100;
input int    MaxPairsPerTick            = 3;
input int    SlippagePoints             = 50;

input bool   UseBrokerTP                = true;
input double TakeProfitUSD              = 150.0;

input bool   UseTrailing                = true;
input double TrailStartUSD              = 150.0;
input double TrailGapUSD                = 75.0;

input bool   UseDDPause                 = true;
input double MaxFloatingLossUSD         = 3000.0;

input ENUM_TIMEFRAMES PatternTF         = PERIOD_M15;
input bool   CloseBuyOnBearishPattern   = true;
input bool   CloseSellOnBullishPattern  = true;
input bool   UseHangingMan              = true;
input bool   UseInvertedHammer          = true;
input bool   UseEveningStar             = true;
input bool   UseHammer                  = true;
input bool   UseMorningStar             = true;

input bool   CloseOnlyIronManOrders     = true;
input bool   ShowDashboard              = true;

//------------------------- Globals ---------------------------------
double   g_base_price       = 0.0;
bool     g_cycle_active     = false;
datetime g_last_pattern_bar = 0;

//------------------------- Helpers ---------------------------------
string SideText(const long type)
{
   if(type == POSITION_TYPE_BUY)  return "BUY";
   if(type == POSITION_TYPE_SELL) return "SELL";
   return "UNKNOWN";
}

double NormalizeVolume(double lots)
{
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   lots = MathMax(minLot, MathMin(maxLot, lots));
   if(step > 0)
      lots = MathFloor(lots / step) * step;

   return NormalizeDouble(lots, 2);
}

bool IsIronManPosition()
{
   if(PositionGetString(POSITION_SYMBOL) != _Symbol)
      return false;

   if((long)PositionGetInteger(POSITION_MAGIC) != MagicNumber)
      return false;

   return true;
}

bool IsManualPosition()
{
   if(PositionGetString(POSITION_SYMBOL) != _Symbol)
      return false;

   long magic = (long)PositionGetInteger(POSITION_MAGIC);
   return (magic == 0);
}

int CountIronManPositions(int side = -1)
{
   int count = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;

      if(!IsIronManPosition()) continue;

      long type = (long)PositionGetInteger(POSITION_TYPE);
      if(side == -1 || type == side)
         count++;
   }

   return count;
}

double IronManFloatingPL()
{
   double pl = 0.0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;

      if(!IsIronManPosition()) continue;

      pl += PositionGetDouble(POSITION_PROFIT);
      pl += PositionGetDouble(POSITION_SWAP);
   }

   return pl;
}

bool FindManualBase(double &base_price)
{
   datetime oldest = LONG_MAX;
   bool found = false;
   base_price = 0.0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;

      if(!IsManualPosition()) continue;

      datetime t = (datetime)PositionGetInteger(POSITION_TIME);
      if(t < oldest)
      {
         oldest = t;
         base_price = PositionGetDouble(POSITION_PRICE_OPEN);
         found = true;
      }
   }

   return found;
}

bool LevelAlreadyTraded(int level)
{
   string tag = InpEAName + "_LVL_" + IntegerToString(level);

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;

      if(!IsIronManPosition()) continue;

      string cmt = PositionGetString(POSITION_COMMENT);
      if(StringFind(cmt, tag) >= 0)
         return true;
   }

   return false;
}

bool OpenMarketOrder(ENUM_ORDER_TYPE order_type, int level)
{
   double lots = NormalizeVolume(LotSize);
   double ask  = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid  = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   int digits  = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   string comment = InpEAName + "_LVL_" + IntegerToString(level);

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(SlippagePoints);

   double tp = 0.0;

   if(order_type == ORDER_TYPE_BUY)
   {
      if(UseBrokerTP)
         tp = NormalizeDouble(ask + TakeProfitUSD, digits);

      return trade.Buy(lots, _Symbol, ask, 0.0, tp, comment);
   }

   if(order_type == ORDER_TYPE_SELL)
   {
      if(UseBrokerTP)
         tp = NormalizeDouble(bid - TakeProfitUSD, digits);

      return trade.Sell(lots, _Symbol, bid, 0.0, tp, comment);
   }

   return false;
}

bool OpenBuySellPair(int level)
{
   if(CountIronManPositions() + 2 > MaxEAPositions)
      return false;

   if(LevelAlreadyTraded(level))
      return false;

   bool b = OpenMarketOrder(ORDER_TYPE_BUY, level);
   bool s = OpenMarketOrder(ORDER_TYPE_SELL, level);

   return (b && s);
}

int CurrentGridLevel()
{
   double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(g_base_price <= 0.0 || GridStepUSD <= 0.0)
      return 0;

   double diff = price - g_base_price;

   if(diff >= GridStepUSD)
      return (int)MathFloor(diff / GridStepUSD);

   if(diff <= -GridStepUSD)
      return (int)MathCeil(diff / GridStepUSD);

   return 0;
}

void ManageGridEntries()
{
   if(!g_cycle_active || g_base_price <= 0.0)
      return;

   if(UseDDPause && IronManFloatingPL() <= -MaxFloatingLossUSD)
      return;

   int curLevel = CurrentGridLevel();
   if(curLevel == 0)
      return;

   int opened = 0;

   if(curLevel > 0)
   {
      for(int lvl = 1; lvl <= curLevel && opened < MaxPairsPerTick; lvl++)
      {
         if(OpenBuySellPair(lvl))
            opened++;
      }
   }
   else
   {
      for(int lvl = -1; lvl >= curLevel && opened < MaxPairsPerTick; lvl--)
      {
         if(OpenBuySellPair(lvl))
            opened++;
      }
   }
}

void ManageTrailing()
{
   if(!UseTrailing)
      return;

   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;

      if(!IsIronManPosition()) continue;

      long   type      = (long)PositionGetInteger(POSITION_TYPE);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double oldSL     = PositionGetDouble(POSITION_SL);
      double oldTP     = PositionGetDouble(POSITION_TP);

      if(type == POSITION_TYPE_BUY)
      {
         double move = bid - openPrice;
         if(move >= TrailStartUSD)
         {
            double newSL = NormalizeDouble(bid - TrailGapUSD, digits);
            if(oldSL == 0.0 || newSL > oldSL)
               trade.PositionModify(ticket, newSL, 0.0); // remove TP after trailing starts
         }
      }

      if(type == POSITION_TYPE_SELL)
      {
         double move = openPrice - ask;
         if(move >= TrailStartUSD)
         {
            double newSL = NormalizeDouble(ask + TrailGapUSD, digits);
            if(oldSL == 0.0 || newSL < oldSL)
               trade.PositionModify(ticket, newSL, 0.0); // remove TP after trailing starts
         }
      }
   }
}

void CloseSide(int side, string reason)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      if(CloseOnlyIronManOrders && !IsIronManPosition())
         continue;

      long type = (long)PositionGetInteger(POSITION_TYPE);
      if(type != side)
         continue;

      trade.PositionClose(ticket);
   }

   Print(InpEAName, ": closed ", SideText(side), " orders. Reason: ", reason);
}

//---------------------- Candle Pattern Logic ------------------------
double Body(int shift)
{
   return MathAbs(iClose(_Symbol, PatternTF, shift) - iOpen(_Symbol, PatternTF, shift));
}

double RangeCandle(int shift)
{
   return MathAbs(iHigh(_Symbol, PatternTF, shift) - iLow(_Symbol, PatternTF, shift));
}

bool Bullish(int shift)
{
   return iClose(_Symbol, PatternTF, shift) > iOpen(_Symbol, PatternTF, shift);
}

bool Bearish(int shift)
{
   return iClose(_Symbol, PatternTF, shift) < iOpen(_Symbol, PatternTF, shift);
}

bool IsHammer(int shift)
{
   double o = iOpen(_Symbol, PatternTF, shift);
   double c = iClose(_Symbol, PatternTF, shift);
   double h = iHigh(_Symbol, PatternTF, shift);
   double l = iLow(_Symbol, PatternTF, shift);

   double body = MathAbs(c - o);
   double range = h - l;
   if(range <= 0 || body <= 0) return false;

   double upper = h - MathMax(o, c);
   double lower = MathMin(o, c) - l;

   return (lower >= body * 2.0 && upper <= body * 0.7 && body <= range * 0.4);
}

bool IsInvertedHammerOrShootingStar(int shift)
{
   double o = iOpen(_Symbol, PatternTF, shift);
   double c = iClose(_Symbol, PatternTF, shift);
   double h = iHigh(_Symbol, PatternTF, shift);
   double l = iLow(_Symbol, PatternTF, shift);

   double body = MathAbs(c - o);
   double range = h - l;
   if(range <= 0 || body <= 0) return false;

   double upper = h - MathMax(o, c);
   double lower = MathMin(o, c) - l;

   return (upper >= body * 2.0 && lower <= body * 0.7 && body <= range * 0.4);
}

bool IsEveningStar()
{
   // Uses closed candles: shift 3, 2, 1
   if(Bars(_Symbol, PatternTF) < 5) return false;

   double body3 = Body(3);
   double body2 = Body(2);
   double body1 = Body(1);

   if(!Bullish(3)) return false;
   if(!Bearish(1)) return false;
   if(body2 > body3 * 0.6) return false;

   double midFirst = (iOpen(_Symbol, PatternTF, 3) + iClose(_Symbol, PatternTF, 3)) / 2.0;

   return (iClose(_Symbol, PatternTF, 1) < midFirst && body1 >= body2);
}

bool IsMorningStar()
{
   // Uses closed candles: shift 3, 2, 1
   if(Bars(_Symbol, PatternTF) < 5) return false;

   double body3 = Body(3);
   double body2 = Body(2);
   double body1 = Body(1);

   if(!Bearish(3)) return false;
   if(!Bullish(1)) return false;
   if(body2 > body3 * 0.6) return false;

   double midFirst = (iOpen(_Symbol, PatternTF, 3) + iClose(_Symbol, PatternTF, 3)) / 2.0;

   return (iClose(_Symbol, PatternTF, 1) > midFirst && body1 >= body2);
}

void CheckPatternExit()
{
   datetime closedBarTime = iTime(_Symbol, PatternTF, 1);
   if(closedBarTime <= 0 || closedBarTime == g_last_pattern_bar)
      return;

   g_last_pattern_bar = closedBarTime;

   bool bearishPattern = false;
   bool bullishPattern = false;

   if(UseHangingMan && IsHammer(1) && Bearish(1))
      bearishPattern = true;

   if(UseInvertedHammer && IsInvertedHammerOrShootingStar(1) && Bearish(1))
      bearishPattern = true;

   if(UseEveningStar && IsEveningStar())
      bearishPattern = true;

   if(UseHammer && IsHammer(1) && Bullish(1))
      bullishPattern = true;

   if(UseMorningStar && IsMorningStar())
      bullishPattern = true;

   if(CloseBuyOnBearishPattern && bearishPattern)
      CloseSide(POSITION_TYPE_BUY, "M15 bearish reversal pattern");

   if(CloseSellOnBullishPattern && bullishPattern)
      CloseSide(POSITION_TYPE_SELL, "M15 bullish reversal pattern");
}

//------------------------- Dashboard --------------------------------
void Dashboard()
{
   if(!ShowDashboard)
   {
      Comment("");
      return;
   }

   double manualBase = 0.0;
   bool manualFound = FindManualBase(manualBase);

   string status = "WAITING MANUAL ORDER";
   if(g_cycle_active) status = "ACTIVE";
   if(UseDDPause && IronManFloatingPL() <= -MaxFloatingLossUSD) status = "DD PAUSED";

   string text;
   text  = "==== " + InpEAName + " ====\n";
   text += "Symbol: " + _Symbol + "\n";
   text += "Status: " + status + "\n";
   text += "Manual Trigger Found: " + string(manualFound ? "YES" : "NO") + "\n";
   text += "Base Price: " + DoubleToString(g_base_price, _Digits) + "\n";
   text += "Current Grid Level: " + IntegerToString(CurrentGridLevel()) + "\n";
   text += "Grid Step: $" + DoubleToString(GridStepUSD, 2) + "\n\n";

   text += "BUY Orders: " + IntegerToString(CountIronManPositions(POSITION_TYPE_BUY)) + "\n";
   text += "SELL Orders: " + IntegerToString(CountIronManPositions(POSITION_TYPE_SELL)) + "\n";
   text += "Total EA Orders: " + IntegerToString(CountIronManPositions()) + " / " + IntegerToString(MaxEAPositions) + "\n";
   text += "Floating P/L: $" + DoubleToString(IronManFloatingPL(), 2) + "\n\n";

   text += "Pattern TF: M15\n";
   text += "Bearish Pattern => Close BUY\n";
   text += "Bullish Pattern => Close SELL\n";

   Comment(text);
}

//------------------------- MT5 Events --------------------------------
int OnInit()
{
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(SlippagePoints);

   Print(InpEAName, " initialized on ", _Symbol);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   Comment("");
}

void OnTick()
{
   double manualBase = 0.0;

   if(!g_cycle_active)
   {
      if(FindManualBase(manualBase))
      {
         g_base_price = manualBase;
         g_cycle_active = true;
         Print(InpEAName, ": cycle started from manual base price ", DoubleToString(g_base_price, _Digits));
      }
   }

   if(g_cycle_active)
   {
      ManageGridEntries();
      ManageTrailing();
      CheckPatternExit();

      // Reset only when manual trigger and IronMan orders are fully gone
      if(!FindManualBase(manualBase) && CountIronManPositions() == 0)
      {
         g_cycle_active = false;
         g_base_price = 0.0;
         Print(InpEAName, ": cycle reset. Waiting for next manual order.");
      }
   }

   Dashboard();
}
//+------------------------------------------------------------------+
