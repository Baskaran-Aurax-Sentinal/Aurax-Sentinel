//+------------------------------------------------------------------+
//| Falcon Profit Engine v3.22                                       |
//| Auto / Manual Trigger + Manual Base Stop + Hybrid Grid           |
//+------------------------------------------------------------------+
#property strict
#property version "3.22"

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
input double Lot_L1_10   = 0.01;
input double Lot_L11_20  = 0.02;
input double Lot_L21_35  = 0.03;
input double Lot_L36_Max = 0.05;

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

// Unified TP + SL/TP trailing for all EA orders
input double OrderTP_USD     = 10.0;
input double TrailStartUSD   = 2.0;
input double TrailLockUSD    = 1.0;
input double TrailGapUSD     = 2.0;
input bool   EnableTPTrailing = true;
input double TPTrailGapUSD    = 10.0;

// Dashboard stacking analysis
input double StackZoneUSD       = 5.0;
input int    StackAlertOrders   = 5;

// Profit Bank worst-order close
input bool   EnableManualProfitBankClose = true;   // Button only: no auto close
input int    ProfitBankLookbackDays    = 30;
input double ProfitBankUsePercent      = 40.0;
input double MinProfitBankToUse        = 5.0;
input double MaxSingleLossToClose      = 100.0;
input int    ProfitBankCloseDelaySec   = 60;

input bool AllowBuy  = true;
input bool AllowSell = true;

input string OrderLabel = "Falcon PE";

//---------------- GLOBALS ----------------//
datetime lastBuyEntryTime  = 0;
datetime lastSellEntryTime = 0;

double buyAnchorPrice  = 0.0;
double sellAnchorPrice = 0.0;

datetime lastProfitBankCloseTime = 0;

string BTN_CLOSE_WORST = "FALCON_BTN_CLOSE_WORST";
string BTN_RESET_BANK_TIME = "FALCON_BTN_RESET_BANK_TIME";

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
double GetLotByLayer(int layer)
{
   if(layer <= 10) return Lot_L1_10;
   if(layer <= 20) return Lot_L11_20;
   if(layer <= 35) return Lot_L21_35;
   return Lot_L36_Max;
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
   double lot = GetLotByLayer(layer);
   double tp  = NormalizePrice(ask + OrderTP_USD);

   trade.SetExpertMagicNumber(MagicNumberBuy);

   bool result = trade.Buy(
      lot,
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
   double lot = GetLotByLayer(layer);
   double tp  = NormalizePrice(bid - OrderTP_USD);

   trade.SetExpertMagicNumber(MagicNumberSell);

   bool result = trade.Sell(
      lot,
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
void ManageAllOrderTrailing()
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

      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double oldSL = PositionGetDouble(POSITION_SL);
      double oldTP = PositionGetDouble(POSITION_TP);

      if(type == POSITION_TYPE_BUY)
      {
         double move = bid - openPrice;

         if(move >= TrailStartUSD)
         {
            double lockSL = openPrice + TrailLockUSD;
            double gapSL  = bid - TrailGapUSD;
            double newSL  = NormalizePrice(MathMax(lockSL, gapSL));

            double newTP = oldTP;
            if(EnableTPTrailing)
            {
               double trailTP = NormalizePrice(bid + TPTrailGapUSD);
               if(oldTP == 0.0 || trailTP > oldTP)
                  newTP = trailTP;
            }

            if(oldSL == 0.0 || newSL > oldSL || newTP != oldTP)
               trade.PositionModify(ticket, newSL, newTP);
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

            double newTP = oldTP;
            if(EnableTPTrailing)
            {
               double trailTP = NormalizePrice(ask - TPTrailGapUSD);
               if(oldTP == 0.0 || trailTP < oldTP)
                  newTP = trailTP;
            }

            if(oldSL == 0.0 || newSL < oldSL || newTP != oldTP)
               trade.PositionModify(ticket, newSL, newTP);
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
double GetClosedFalconNetProfit()
{
   double profit = 0.0;
   datetime fromTime = TimeCurrent() - (ProfitBankLookbackDays * 86400);

   if(!HistorySelect(fromTime, TimeCurrent()))
      return 0.0;

   int total = HistoryDealsTotal();
   for(int i = 0; i < total; i++)
   {
      ulong deal = HistoryDealGetTicket(i);
      if(deal == 0) continue;

      if(HistoryDealGetString(deal, DEAL_SYMBOL) != _Symbol) continue;

      int magic = (int)HistoryDealGetInteger(deal, DEAL_MAGIC);
      if(magic != MagicNumberBuy && magic != MagicNumberSell) continue;

      int entry = (int)HistoryDealGetInteger(deal, DEAL_ENTRY);
      if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_INOUT && entry != DEAL_ENTRY_OUT_BY) continue;

      profit += HistoryDealGetDouble(deal, DEAL_PROFIT)
              + HistoryDealGetDouble(deal, DEAL_SWAP)
              + HistoryDealGetDouble(deal, DEAL_COMMISSION);
   }

   if(profit < 0.0)
      profit = 0.0;

   return profit;
}

//+------------------------------------------------------------------+
bool GetWorstFalconOrder(ulong &ticketOut, double &lossOut, int &typeOut, double &lotOut)
{
   ticketOut = 0;
   lossOut = 0.0;
   typeOut = -1;
   lotOut = 0.0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;

      int magic = (int)PositionGetInteger(POSITION_MAGIC);
      if(magic != MagicNumberBuy && magic != MagicNumberSell) continue;

      double pl = PositionGetDouble(POSITION_PROFIT);
      if(pl < lossOut)
      {
         lossOut = pl;
         ticketOut = ticket;
         typeOut = (int)PositionGetInteger(POSITION_TYPE);
         lotOut = PositionGetDouble(POSITION_VOLUME);
      }
   }

   return (ticketOut > 0 && lossOut < 0.0);
}

//+------------------------------------------------------------------+
bool CloseWorstOrderByProfitBank()
{
   if(!EnableManualProfitBankClose) return false;
   if(TimeCurrent() - lastProfitBankCloseTime < ProfitBankCloseDelaySec) return false;

   double bank = GetClosedFalconNetProfit();
   if(bank < MinProfitBankToUse) return false;

   double usableBank = bank * ProfitBankUsePercent / 100.0;

   ulong ticket;
   double loss;
   int type;
   double lot;

   if(!GetWorstFalconOrder(ticket, loss, type, lot)) return false;

   double lossAbs = MathAbs(loss);
   if(lossAbs > usableBank) return false;
   if(MaxSingleLossToClose > 0.0 && lossAbs > MaxSingleLossToClose) return false;

   if(trade.PositionClose(ticket))
   {
      lastProfitBankCloseTime = TimeCurrent();
      Print("Manual Profit Bank button closed worst Falcon order. Ticket=", ticket,
            " Loss=", DoubleToString(loss, 2),
            " Bank=", DoubleToString(bank, 2),
            " Usable=", DoubleToString(usableBank, 2));
      return true;
   }

   return false;
}

//+------------------------------------------------------------------+
void CreateDashboardButton()
{
   if(!EnableManualProfitBankClose)
   {
      ObjectDelete(0, BTN_CLOSE_WORST);
      return;
   }

   if(ObjectFind(0, BTN_CLOSE_WORST) < 0)
   {
      ObjectCreate(0, BTN_CLOSE_WORST, OBJ_BUTTON, 0, 0, 0);
      ObjectSetInteger(0, BTN_CLOSE_WORST, OBJPROP_CORNER, CORNER_RIGHT_UPPER);
      ObjectSetInteger(0, BTN_CLOSE_WORST, OBJPROP_XDISTANCE, 20);
      ObjectSetInteger(0, BTN_CLOSE_WORST, OBJPROP_YDISTANCE, 25);
      ObjectSetInteger(0, BTN_CLOSE_WORST, OBJPROP_XSIZE, 170);
      ObjectSetInteger(0, BTN_CLOSE_WORST, OBJPROP_YSIZE, 28);
      ObjectSetInteger(0, BTN_CLOSE_WORST, OBJPROP_FONTSIZE, 9);
      ObjectSetInteger(0, BTN_CLOSE_WORST, OBJPROP_COLOR, clrWhite);
      ObjectSetInteger(0, BTN_CLOSE_WORST, OBJPROP_BGCOLOR, clrFireBrick);
      ObjectSetInteger(0, BTN_CLOSE_WORST, OBJPROP_BORDER_COLOR, clrWhite);
   }

   ObjectSetString(0, BTN_CLOSE_WORST, OBJPROP_TEXT, "Close Worst by Bank");
}

//+------------------------------------------------------------------+
//+------------------------------------------------------------------+
string GetStackingText(int type, int magic)
{
   double minPrice = 0.0;
   double maxPrice = 0.0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((int)PositionGetInteger(POSITION_MAGIC) != magic) continue;
      if((int)PositionGetInteger(POSITION_TYPE) != type) continue;

      double price = PositionGetDouble(POSITION_PRICE_OPEN);
      if(minPrice == 0.0 || price < minPrice) minPrice = price;
      if(maxPrice == 0.0 || price > maxPrice) maxPrice = price;
   }

   if(minPrice == 0.0 || maxPrice == 0.0 || StackZoneUSD <= 0.0)
      return "No open stack\n";

   double startZone = MathFloor(minPrice / StackZoneUSD) * StackZoneUSD;
   double endZone   = MathFloor(maxPrice / StackZoneUSD) * StackZoneUSD;

   string txt = "";

   for(double z = startZone; z <= endZone + 0.0001; z += StackZoneUSD)
   {
      int orders = 0;
      double lots = 0.0;
      double pl = 0.0;

      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         ulong ticket = PositionGetTicket(i);
         if(ticket == 0) continue;
         if(!PositionSelectByTicket(ticket)) continue;

         if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
         if((int)PositionGetInteger(POSITION_MAGIC) != magic) continue;
         if((int)PositionGetInteger(POSITION_TYPE) != type) continue;

         double price = PositionGetDouble(POSITION_PRICE_OPEN);
         if(price >= z && price < z + StackZoneUSD)
         {
            orders++;
            lots += PositionGetDouble(POSITION_VOLUME);
            pl += PositionGetDouble(POSITION_PROFIT);
         }
      }

      if(orders > 0)
      {
         txt += DoubleToString(z, _Digits) + " - " + DoubleToString(z + StackZoneUSD, _Digits)
             + " : " + IntegerToString(orders)
             + " | Lot " + DoubleToString(lots, 2)
             + " | P/L " + DoubleToString(pl, 2);

         if(orders >= StackAlertOrders)
            txt += " <<< STACKED";

         txt += "\n";
      }
   }

   return txt;
}

//+------------------------------------------------------------------+
void DrawDashboard()
{
   int buyCount  = CountPositions(POSITION_TYPE_BUY, MagicNumberBuy);
   int sellCount = CountPositions(POSITION_TYPE_SELL, MagicNumberSell);

   double buyProfit  = GetSideProfit(POSITION_TYPE_BUY, MagicNumberBuy);
   double sellProfit = GetSideProfit(POSITION_TYPE_SELL, MagicNumberSell);
   double profitBank = GetClosedFalconNetProfit();
   double usableBank = profitBank * ProfitBankUsePercent / 100.0;

   ulong worstTicket;
   double worstLoss;
   int worstType;
   double worstLot;
   bool hasWorst = GetWorstFalconOrder(worstTicket, worstLoss, worstType, worstLot);

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

   string worstText = "None";
   if(hasWorst)
   {
      worstText = (worstType == POSITION_TYPE_BUY ? "BUY" : "SELL")
                + " | Lot " + DoubleToString(worstLot, 2)
                + " | Loss " + DoubleToString(worstLoss, 2);
   }

   string text =
      "FALCON PROFIT ENGINE v3.22\n"
      "--------------------------------\n"
      "Mode        : " + modeText + "\n"
      "BUY Status  : " + buyStatus + "\n"
      "SELL Status : " + sellStatus + "\n\n"
      "BUY Orders  : " + IntegerToString(buyCount) + " / " + IntegerToString(MaxBuyOrders) + " | P/L " + DoubleToString(buyProfit, 2) + "\n"
      "SELL Orders : " + IntegerToString(sellCount) + " / " + IntegerToString(MaxSellOrders) + " | P/L " + DoubleToString(sellProfit, 2) + "\n"
      "TOTAL       : " + IntegerToString(buyCount + sellCount) + " / " + IntegerToString(MaxTotalOrders) + "\n\n"
      "LOT LADDER\n"
      "L1-L10  : " + DoubleToString(Lot_L1_10, 2) + " lot | $" + DoubleToString(Spacing_1_10, 1) + " spacing | Exact refill\n"
      "L11-L20 : " + DoubleToString(Lot_L11_20, 2) + " lot | $" + DoubleToString(Spacing_11_20, 1) + " spacing\n"
      "L21-L35 : " + DoubleToString(Lot_L21_35, 2) + " lot | $" + DoubleToString(Spacing_21_35, 1) + " spacing\n"
      "L36-Max : " + DoubleToString(Lot_L36_Max, 2) + " lot | $" + DoubleToString(Spacing_36_50, 1) + " spacing\n\n"
      "TP/TRAIL\n"
      "Broker TP : $" + DoubleToString(OrderTP_USD, 2) + " on every order\n"
      "SL Trail  : start $" + DoubleToString(TrailStartUSD, 2) + " | lock $" + DoubleToString(TrailLockUSD, 2) + " | gap $" + DoubleToString(TrailGapUSD, 2) + "\n"
      "TP Trail  : " + (EnableTPTrailing ? "ON | gap $" + DoubleToString(TPTrailGapUSD, 2) : "OFF") + "\n\n"
      "PROFIT BANK\n"
      "Bank      : " + DoubleToString(profitBank, 2) + " | Usable " + DoubleToString(usableBank, 2) + " (" + DoubleToString(ProfitBankUsePercent, 1) + "%)\n"
      "Worst     : " + worstText + "\n\n"
      "STACKING ANALYSIS BUY\n"
      + GetStackingText(POSITION_TYPE_BUY, MagicNumberBuy) + "\n"
      "STACKING ANALYSIS SELL\n"
      + GetStackingText(POSITION_TYPE_SELL, MagicNumberSell) + "\n"
      "BUY Anchor  : " + DoubleToString(buyAnchorPrice, _Digits) + "\n"
      "SELL Anchor : " + DoubleToString(sellAnchorPrice, _Digits);

   Comment(text);
}

//+------------------------------------------------------------------+
void OnChartEvent(const int id,
                  const long &lparam,
                  const double &dparam,
                  const string &sparam)
{
   if(id == CHARTEVENT_OBJECT_CLICK && sparam == BTN_CLOSE_WORST)
   {
      bool closed = CloseWorstOrderByProfitBank();

      if(!closed)
         Print("Manual Profit Bank close skipped. Check bank, usable %, max loss, cooldown, or no losing Falcon order.");

      ObjectSetInteger(0, BTN_CLOSE_WORST, OBJPROP_STATE, false);
      ChartRedraw();
   }
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   ObjectDelete(0, BTN_CLOSE_WORST);
}

//+------------------------------------------------------------------+
//+------------------------------------------------------------------+
int OnInit()
{
   Print("Falcon Profit Engine v3.22 initialized.");
   CreateDashboardButton();
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnTick()
{
   CheckManualBaseStatus();
   ManageEntries();
   ManageAllOrderTrailing();
   DrawDashboard();
   CreateDashboardButton();
}
//+------------------------------------------------------------------+
