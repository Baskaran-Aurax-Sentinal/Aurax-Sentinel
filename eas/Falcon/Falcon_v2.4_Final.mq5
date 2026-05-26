//+------------------------------------------------------------------+
//| Falcon Profit Engine v3.20                                       |
//| Auto / Manual Trigger + Manual Base Stop + Hybrid Grid           |
//+------------------------------------------------------------------+
#property strict
#property version "3.20"

#include <Trade/Trade.mqh>
CTrade trade;

//---------------- MODE ----------------//
enum StartModeEnum
{
   AUTO_MODE = 0,
   MANUAL_TRIGGER_MODE = 1
};

input StartModeEnum StartMode = AUTO_MODE;
input bool ManualBuyStartsCycle  = true;
input bool ManualSellStartsCycle = true;

//---------------- INPUTS ----------------//
input double LotSize = 0.01;

input int MagicNumberBuy  = 432515;
input int MagicNumberSell = 532515;

input int MaxTotalOrders = 100;
input int MaxBuyOrders   = 50;
input int MaxSellOrders  = 50;

input int EntryDelaySec = 60;

// Hybrid grid
input int ExactRefillLevels = 10;
input double RefillToleranceUSD = 0.30;

input double Spacing_1_10   = 3.0;
input double Spacing_11_20  = 5.0;
input double Spacing_21_35  = 8.0;
input double Spacing_36_50  = 12.0;

// 3 Layer TP
input int Layer1Orders = 5;
input int Layer2Orders = 20;

// Layer 1 broker TP
input double Layer1_TP_USD = 5.0;

// Layer 2 trailing
input double TrailStartUSD = 5.0;
input double TrailLockUSD  = 2.0;
input double TrailGapUSD   = 3.0;

// Layer 3 basket
input double BasketTP_Money        = 150.0;
input double BasketTrailStartMoney = 75.0;
input double BasketTrailGapMoney   = 30.0;

input bool AllowBuy  = true;
input bool AllowSell = true;

input string OrderLabel = "Falcon PE";

//---------------- GLOBALS ----------------//
datetime lastBuyEntryTime  = 0;
datetime lastSellEntryTime = 0;

double buyAnchorPrice  = 0.0;
double sellAnchorPrice = 0.0;

double buyBasketPeak  = 0.0;
double sellBasketPeak = 0.0;

ulong manualBuyBaseTicket  = 0;
ulong manualSellBaseTicket = 0;

bool buyCycleStartedByManual  = false;
bool sellCycleStartedByManual = false;

bool buyManageOnly  = false;
bool sellManageOnly = false;

//+------------------------------------------------------------------+
double NormalizePrice(double price)
{
   return NormalizeDouble(price, _Digits);
}

//+------------------------------------------------------------------+
double GetSpacingByLayer(int layer)
{
   if(layer <= 10) return Spacing_1_10;
   if(layer <= 20) return Spacing_11_20;
   if(layer <= 35) return Spacing_21_35;
   return Spacing_36_50;
}

//+------------------------------------------------------------------+
int GetLayerFromComment(string comment)
{
   int pos = StringFind(comment, " L");

   if(pos < 0)
      return 0;

   return (int)StringToInteger(StringSubstr(comment, pos + 2));
}

//+------------------------------------------------------------------+
int CountPositions(int type, int magic)
{
   int count = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((int)PositionGetInteger(POSITION_MAGIC) != magic) continue;
      if((int)PositionGetInteger(POSITION_TYPE) != type) continue;

      count++;
   }

   return count;
}

//+------------------------------------------------------------------+
int CountAllFalconOrders()
{
   return CountPositions(POSITION_TYPE_BUY, MagicNumberBuy)
        + CountPositions(POSITION_TYPE_SELL, MagicNumberSell);
}

//+------------------------------------------------------------------+
bool PositionTicketExists(ulong ticket)
{
   if(ticket == 0) return false;
   return PositionSelectByTicket(ticket);
}

//+------------------------------------------------------------------+
bool GetManualPosition(int type, ulong &ticketOut, double &priceOut)
{
   ticketOut = 0;
   priceOut = 0.0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((int)PositionGetInteger(POSITION_MAGIC) != 0) continue;
      if((int)PositionGetInteger(POSITION_TYPE) != type) continue;

      ticketOut = ticket;
      priceOut = PositionGetDouble(POSITION_PRICE_OPEN);
      return true;
   }

   return false;
}

//+------------------------------------------------------------------+
void CheckManualBaseStatus()
{
   int buyCount  = CountPositions(POSITION_TYPE_BUY, MagicNumberBuy);
   int sellCount = CountPositions(POSITION_TYPE_SELL, MagicNumberSell);

   if(StartMode == MANUAL_TRIGGER_MODE)
   {
      if(buyCycleStartedByManual && !buyManageOnly)
      {
         if(!PositionTicketExists(manualBuyBaseTicket))
         {
            buyManageOnly = true;
            Print("Manual BUY base closed. BUY side is now manage-only.");
         }
      }

      if(sellCycleStartedByManual && !sellManageOnly)
      {
         if(!PositionTicketExists(manualSellBaseTicket))
         {
            sellManageOnly = true;
            Print("Manual SELL base closed. SELL side is now manage-only.");
         }
      }

      // Reset only after EA positions are fully gone
      if(buyManageOnly && buyCount == 0)
      {
         buyManageOnly = false;
         buyCycleStartedByManual = false;
         manualBuyBaseTicket = 0;
         buyAnchorPrice = 0.0;
      }

      if(sellManageOnly && sellCount == 0)
      {
         sellManageOnly = false;
         sellCycleStartedByManual = false;
         manualSellBaseTicket = 0;
         sellAnchorPrice = 0.0;
      }
   }
}

//+------------------------------------------------------------------+
bool IsLayerOpen(int type, int magic, int layer)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((int)PositionGetInteger(POSITION_MAGIC) != magic) continue;
      if((int)PositionGetInteger(POSITION_TYPE) != type) continue;

      if(GetLayerFromComment(PositionGetString(POSITION_COMMENT)) == layer)
         return true;
   }

   return false;
}

//+------------------------------------------------------------------+
int HighestOpenLayer(int type, int magic)
{
   int highest = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((int)PositionGetInteger(POSITION_MAGIC) != magic) continue;
      if((int)PositionGetInteger(POSITION_TYPE) != type) continue;

      int layer = GetLayerFromComment(PositionGetString(POSITION_COMMENT));
      if(layer > highest)
         highest = layer;
   }

   return highest;
}

//+------------------------------------------------------------------+
double GetLowestBuyPrice()
{
   double lowest = 0.0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((int)PositionGetInteger(POSITION_MAGIC) != MagicNumberBuy) continue;
      if((int)PositionGetInteger(POSITION_TYPE) != POSITION_TYPE_BUY) continue;

      double price = PositionGetDouble(POSITION_PRICE_OPEN);
      if(lowest == 0.0 || price < lowest)
         lowest = price;
   }

   return lowest;
}

//+------------------------------------------------------------------+
double GetHighestSellPrice()
{
   double highest = 0.0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((int)PositionGetInteger(POSITION_MAGIC) != MagicNumberSell) continue;
      if((int)PositionGetInteger(POSITION_TYPE) != POSITION_TYPE_SELL) continue;

      double price = PositionGetDouble(POSITION_PRICE_OPEN);
      if(highest == 0.0 || price > highest)
         highest = price;
   }

   return highest;
}

//+------------------------------------------------------------------+
double GetSideProfit(int type, int magic)
{
   double profit = 0.0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((int)PositionGetInteger(POSITION_MAGIC) != magic) continue;
      if((int)PositionGetInteger(POSITION_TYPE) != type) continue;

      profit += PositionGetDouble(POSITION_PROFIT);
   }

   return profit;
}

//+------------------------------------------------------------------+
bool OpenBuy(int layer)
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   double tp = 0.0;
   if(layer <= Layer1Orders)
      tp = NormalizePrice(ask + Layer1_TP_USD);

   trade.SetExpertMagicNumber(MagicNumberBuy);

   bool result = trade.Buy(
      LotSize,
      _Symbol,
      ask,
      0.0,
      tp,
      OrderLabel + " BUY L" + IntegerToString(layer)
   );

   if(result)
      lastBuyEntryTime = TimeCurrent();

   return result;
}

//+------------------------------------------------------------------+
bool OpenSell(int layer)
{
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   double tp = 0.0;
   if(layer <= Layer1Orders)
      tp = NormalizePrice(bid - Layer1_TP_USD);

   trade.SetExpertMagicNumber(MagicNumberSell);

   bool result = trade.Sell(
      LotSize,
      _Symbol,
      bid,
      0.0,
      tp,
      OrderLabel + " SELL L" + IntegerToString(layer)
   );

   if(result)
      lastSellEntryTime = TimeCurrent();

   return result;
}

//+------------------------------------------------------------------+
void ManageBuyEntries()
{
   if(!AllowBuy) return;
   if(buyManageOnly) return;

   int totalOrders = CountAllFalconOrders();
   int buyCount = CountPositions(POSITION_TYPE_BUY, MagicNumberBuy);

   if(totalOrders >= MaxTotalOrders) return;
   if(buyCount >= MaxBuyOrders) return;
   if(TimeCurrent() - lastBuyEntryTime < EntryDelaySec) return;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   if(buyCount == 0)
   {
      if(StartMode == AUTO_MODE)
      {
         buyAnchorPrice = ask;
         OpenBuy(1);
         return;
      }

      if(StartMode == MANUAL_TRIGGER_MODE && ManualBuyStartsCycle)
      {
         ulong manualTicket;
         double manualPrice;

         if(GetManualPosition(POSITION_TYPE_BUY, manualTicket, manualPrice))
         {
            manualBuyBaseTicket = manualTicket;
            buyAnchorPrice = manualPrice;
            buyCycleStartedByManual = true;
            buyManageOnly = false;
            OpenBuy(1);
            return;
         }
      }

      return;
   }

   if(StartMode == MANUAL_TRIGGER_MODE && buyCycleStartedByManual && manualBuyBaseTicket > 0)
   {
      if(!PositionTicketExists(manualBuyBaseTicket))
      {
         buyManageOnly = true;
         return;
      }
   }

   if(buyAnchorPrice <= 0.0)
      buyAnchorPrice = GetLowestBuyPrice() + ((ExactRefillLevels - 1) * Spacing_1_10);

   for(int layer = 1; layer <= ExactRefillLevels; layer++)
   {
      if(IsLayerOpen(POSITION_TYPE_BUY, MagicNumberBuy, layer))
         continue;

      double levelPrice = buyAnchorPrice - ((layer - 1) * Spacing_1_10);

   if(bid <= levelPrice && bid >= levelPrice - RefillToleranceUSD)
{
   OpenBuy(layer);
   return;
}
   }

   int highestLayer = HighestOpenLayer(POSITION_TYPE_BUY, MagicNumberBuy);
   int nextLayer = highestLayer + 1;

   if(nextLayer <= ExactRefillLevels)
      nextLayer = ExactRefillLevels + 1;

   if(nextLayer > MaxBuyOrders)
      return;

   double lowestBuy = GetLowestBuyPrice();
   double spacing = GetSpacingByLayer(nextLayer);

   if(bid <= lowestBuy - spacing)
      OpenBuy(nextLayer);
}

//+------------------------------------------------------------------+
void ManageSellEntries()
{
   if(!AllowSell) return;
   if(sellManageOnly) return;

   int totalOrders = CountAllFalconOrders();
   int sellCount = CountPositions(POSITION_TYPE_SELL, MagicNumberSell);

   if(totalOrders >= MaxTotalOrders) return;
   if(sellCount >= MaxSellOrders) return;
   if(TimeCurrent() - lastSellEntryTime < EntryDelaySec) return;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   if(sellCount == 0)
   {
      if(StartMode == AUTO_MODE)
      {
         sellAnchorPrice = bid;
         OpenSell(1);
         return;
      }

      if(StartMode == MANUAL_TRIGGER_MODE && ManualSellStartsCycle)
      {
         ulong manualTicket;
         double manualPrice;

         if(GetManualPosition(POSITION_TYPE_SELL, manualTicket, manualPrice))
         {
            manualSellBaseTicket = manualTicket;
            sellAnchorPrice = manualPrice;
            sellCycleStartedByManual = true;
            sellManageOnly = false;
            OpenSell(1);
            return;
         }
      }

      return;
   }

   if(StartMode == MANUAL_TRIGGER_MODE && sellCycleStartedByManual && manualSellBaseTicket > 0)
   {
      if(!PositionTicketExists(manualSellBaseTicket))
      {
         sellManageOnly = true;
         return;
      }
   }

   if(sellAnchorPrice <= 0.0)
      sellAnchorPrice = GetHighestSellPrice() - ((ExactRefillLevels - 1) * Spacing_1_10);

   for(int layer = 1; layer <= ExactRefillLevels; layer++)
   {
      if(IsLayerOpen(POSITION_TYPE_SELL, MagicNumberSell, layer))
         continue;

      double levelPrice = sellAnchorPrice + ((layer - 1) * Spacing_1_10);

if(ask >= levelPrice && ask <= levelPrice + RefillToleranceUSD)
{
   OpenSell(layer);
   return;
}
   }

   int highestLayer = HighestOpenLayer(POSITION_TYPE_SELL, MagicNumberSell);
   int nextLayer = highestLayer + 1;

   if(nextLayer <= ExactRefillLevels)
      nextLayer = ExactRefillLevels + 1;

   if(nextLayer > MaxSellOrders)
      return;

   double highestSell = GetHighestSellPrice();
   double spacing = GetSpacingByLayer(nextLayer);

   if(ask >= highestSell + spacing)
      OpenSell(nextLayer);
}

//+------------------------------------------------------------------+
void ManageEntries()
{
   ManageBuyEntries();
   ManageSellEntries();
}

//+------------------------------------------------------------------+
void ManageLayer2Trailing()
{
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;

      int type  = (int)PositionGetInteger(POSITION_TYPE);
      int magic = (int)PositionGetInteger(POSITION_MAGIC);

      if(magic != MagicNumberBuy && magic != MagicNumberSell)
         continue;

      int layer = GetLayerFromComment(PositionGetString(POSITION_COMMENT));

      if(layer <= Layer1Orders || layer > Layer2Orders)
         continue;

      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double oldSL = PositionGetDouble(POSITION_SL);

      if(type == POSITION_TYPE_BUY)
      {
         double move = bid - openPrice;

         if(move >= TrailStartUSD)
         {
            double lockSL = openPrice + TrailLockUSD;
            double gapSL  = bid - TrailGapUSD;
            double newSL  = NormalizePrice(MathMax(lockSL, gapSL));

            if(oldSL == 0.0 || newSL > oldSL)
               trade.PositionModify(ticket, newSL, 0.0);
         }
      }

      if(type == POSITION_TYPE_SELL)
      {
         double move = openPrice - ask;

         if(move >= TrailStartUSD)
         {
            double lockSL = openPrice - TrailLockUSD;
            double gapSL  = ask + TrailGapUSD;
            double newSL  = NormalizePrice(MathMin(lockSL, gapSL));

            if(oldSL == 0.0 || newSL < oldSL)
               trade.PositionModify(ticket, newSL, 0.0);
         }
      }
   }
}

//+------------------------------------------------------------------+
void CloseSide(int type, int magic)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((int)PositionGetInteger(POSITION_MAGIC) != magic) continue;
      if((int)PositionGetInteger(POSITION_TYPE) != type) continue;

      trade.PositionClose(ticket);
   }
}

//+------------------------------------------------------------------+
void ManageBasketTP()
{
   int buyCount  = CountPositions(POSITION_TYPE_BUY, MagicNumberBuy);
   int sellCount = CountPositions(POSITION_TYPE_SELL, MagicNumberSell);

   double buyProfit  = GetSideProfit(POSITION_TYPE_BUY, MagicNumberBuy);
   double sellProfit = GetSideProfit(POSITION_TYPE_SELL, MagicNumberSell);

   if(buyCount > Layer2Orders)
   {
      if(buyProfit > buyBasketPeak)
         buyBasketPeak = buyProfit;

      if(buyProfit >= BasketTP_Money)
      {
         CloseSide(POSITION_TYPE_BUY, MagicNumberBuy);
         buyBasketPeak = 0.0;
         buyAnchorPrice = 0.0;
      }
      else if(buyBasketPeak >= BasketTrailStartMoney &&
              buyProfit <= buyBasketPeak - BasketTrailGapMoney &&
              buyProfit > 0.0)
      {
         CloseSide(POSITION_TYPE_BUY, MagicNumberBuy);
         buyBasketPeak = 0.0;
         buyAnchorPrice = 0.0;
      }
   }
   else
   {
      buyBasketPeak = 0.0;
   }

   if(sellCount > Layer2Orders)
   {
      if(sellProfit > sellBasketPeak)
         sellBasketPeak = sellProfit;

      if(sellProfit >= BasketTP_Money)
      {
         CloseSide(POSITION_TYPE_SELL, MagicNumberSell);
         sellBasketPeak = 0.0;
         sellAnchorPrice = 0.0;
      }
      else if(sellBasketPeak >= BasketTrailStartMoney &&
              sellProfit <= sellBasketPeak - BasketTrailGapMoney &&
              sellProfit > 0.0)
      {
         CloseSide(POSITION_TYPE_SELL, MagicNumberSell);
         sellBasketPeak = 0.0;
         sellAnchorPrice = 0.0;
      }
   }
   else
   {
      sellBasketPeak = 0.0;
   }

   if(buyCount == 0 && StartMode == AUTO_MODE)
      buyAnchorPrice = 0.0;

   if(sellCount == 0 && StartMode == AUTO_MODE)
      sellAnchorPrice = 0.0;
}

//+------------------------------------------------------------------+
void DrawDashboard()
{
   int buyCount  = CountPositions(POSITION_TYPE_BUY, MagicNumberBuy);
   int sellCount = CountPositions(POSITION_TYPE_SELL, MagicNumberSell);

   double buyProfit  = GetSideProfit(POSITION_TYPE_BUY, MagicNumberBuy);
   double sellProfit = GetSideProfit(POSITION_TYPE_SELL, MagicNumberSell);

   string modeText = "AUTO";
   if(StartMode == MANUAL_TRIGGER_MODE)
      modeText = "MANUAL TRIGGER";

   string buyStatus = "ACTIVE";
   string sellStatus = "ACTIVE";

   if(StartMode == MANUAL_TRIGGER_MODE)
   {
      if(!buyCycleStartedByManual) buyStatus = "WAITING MANUAL BUY";
      else if(buyManageOnly) buyStatus = "MANAGE ONLY";
      else buyStatus = "MANUAL BASE ACTIVE";

      if(!sellCycleStartedByManual) sellStatus = "WAITING MANUAL SELL";
      else if(sellManageOnly) sellStatus = "MANAGE ONLY";
      else sellStatus = "MANUAL BASE ACTIVE";
   }

   string text =
      "FALCON PROFIT ENGINE v3.20\n"
      "--------------------------------\n"
      "Mode        : " + modeText + "\n"
      "BUY Status  : " + buyStatus + "\n"
      "SELL Status : " + sellStatus + "\n\n"
      "BUY Orders  : " + IntegerToString(buyCount) + " / " + IntegerToString(MaxBuyOrders) + "\n"
      "SELL Orders : " + IntegerToString(sellCount) + " / " + IntegerToString(MaxSellOrders) + "\n"
      "TOTAL       : " + IntegerToString(buyCount + sellCount) + " / " + IntegerToString(MaxTotalOrders) + "\n\n"
      "BUY Profit  : " + DoubleToString(buyProfit, 2) + "\n"
      "SELL Profit : " + DoubleToString(sellProfit, 2) + "\n\n"
      "BUY Peak    : " + DoubleToString(buyBasketPeak, 2) + "\n"
      "SELL Peak   : " + DoubleToString(sellBasketPeak, 2) + "\n\n"
      "BUY Anchor  : " + DoubleToString(buyAnchorPrice, _Digits) + "\n"
      "SELL Anchor : " + DoubleToString(sellAnchorPrice, _Digits) + "\n\n"
      "L1-L10      : Exact Refill\n"
      "L11-L50     : Dynamic Spacing\n"
      "Layer 1     : Broker TP\n"
      "Layer 2     : Trail SL\n"
      "Layer 3     : Basket TP / Trail";

   Comment(text);
}

//+------------------------------------------------------------------+
int OnInit()
{
   Print("Falcon Profit Engine v3.20 initialized.");
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnTick()
{
   CheckManualBaseStatus();
   ManageEntries();
   ManageLayer2Trailing();
   ManageBasketTP();
   DrawDashboard();
}
//+------------------------------------------------------------------+
