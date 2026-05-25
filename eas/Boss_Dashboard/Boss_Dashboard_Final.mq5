//+------------------------------------------------------------------+
//| BOSS_Controller_EA_V21_Stack.mq5                                  |
//| EA-wise Monitor + Close Buttons + ProfitBank + Stack Analysis      |
//| Dashboard only opens no trades. Closes only when buttons clicked.  |
//+------------------------------------------------------------------+
#property strict
#property version   "2.10"
#property description "BOSS Controller V2.1 - EA-wise dashboard, close buttons, ProfitBank, $ range stack analysis"

#include <Trade/Trade.mqh>
CTrade trade;

//================ GENERAL INPUTS =================//
input string EA_Name = "BOSS_CONTROLLER_V21";
input bool   CurrentSymbolOnly = true;
input bool   IncludeManualOrders = true;
input int    SlippagePoints = 50;
input int    RefreshSeconds = 1;
input bool   ConfirmButtons = false;       // true = first click arms, second click closes
input double MaxSingleLossClose = 0.0;     // 0 = no limit. Example 100 = do not close loss worse than -100

//================ DASHBOARD INPUTS =================//
input int StartX = 14;
input int StartY = 22;
input int FontSize = 9;
input int RowGap = 24;
input int ButtonW = 55;
input int ButtonH = 18;
input int ButtonGap = 5;
input int ButtonStartX = 890;              // keep SELL P/L visible; move buttons right

//================ PROFIT BANK / WORST EXIT =================//
input double ProfitBank_MinAddProfit = 5.0;     // add closed deal profit to bank only if >= this
input int    WorstClose_MinOrders = 1;
input int    WorstClose_MaxOrders = 3;
input double WorstClose_MaxSingleLoss = 100.0;  // safety: ignore one very large worst order
input double ProfitBank_Reserve = 0.0;          // keep this balance in bank after assisted close

//================ STACK ANALYSIS =================//
input bool   EnableStackDashboard = true;
input double StackRangeUSD = 15.0;              // group orders by $15 price zone
input int    MaxStackRowsPerSide = 6;           // BUY rows + SELL rows
input int    StackMinOrdersToShow = 1;
input bool   StackSortByLoss = true;            // true = largest loss first, false = most orders first

//================ EA MAGIC MAP =================//
#define GROUPS 6

input bool EnableFalcon = true;
input long FalconMagicBuy  = 432515;
input long FalconMagicSell = 532515;

input bool EnableHopeBurst = true;
input long HopeBurstMagic = 27042201;

input bool EnableSniperAutoBuy = true;
input long SniperAutoMagicBuy  = 454001;
input long SniperAutoMagicSell = 454002;

input bool EnableAurax = true;
input long AuraxMagicFrom = 20000;
input long AuraxMagicTo   = 20999;

input bool EnableGroup5 = true;
input string Group5Name = "Hedge EA";          // change to SNIPER_V2 if required
input long Group5MagicBuy  = 909090;
input long Group5MagicSell = 909090;

//================ INTERNALS =================//
string Prefix = "BOSS_V21_";
string armedButton = "";
datetime armedTime = 0;
datetime LastScanTime = 0;
double ProfitBank = 0.0;
ulong LastDealTicket = 0;

string groupName[GROUPS];
bool   groupEnabled[GROUPS];
long   groupBuyMagic[GROUPS];
long   groupSellMagic[GROUPS];
long   groupFromMagic[GROUPS];
long   groupToMagic[GROUPS];
bool   groupIsRange[GROUPS];
bool   groupIsManual[GROUPS];

struct Stat
{
   int buyAll, buyPos, buyNeg;
   int sellAll, sellPos, sellNeg;
   double buyLotsAll, buyLotsPos, buyLotsNeg;
   double sellLotsAll, sellLotsPos, sellLotsNeg;
   double buyPLAll, buyPLPos, buyPLNeg;
   double sellPLAll, sellPLPos, sellPLNeg;
};

struct StackZone
{
   int side;                 // POSITION_TYPE_BUY / POSITION_TYPE_SELL
   double low;
   double high;
   int orders;
   double lots;
   double pl;
};

struct StackGroup
{
   int side;
   double low;
   double high;
   int group;
   int orders;
   double lots;
   double pl;
};

//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetDeviationInPoints(SlippagePoints);
   InitGroups();

   if(GlobalVariableCheck(Prefix + "ProfitBank"))
      ProfitBank = GlobalVariableGet(Prefix + "ProfitBank");

   if(GlobalVariableCheck(Prefix + "LastDeal"))
      LastDealTicket = (ulong)GlobalVariableGet(Prefix + "LastDeal");

   EventSetTimer(1);
   DrawDashboard();
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();
   GlobalVariableSet(Prefix + "ProfitBank", ProfitBank);
   GlobalVariableSet(Prefix + "LastDeal", (double)LastDealTicket);
   DeleteBossObjects();
   Comment("");
}

//+------------------------------------------------------------------+
void OnTimer()
{
   if(TimeCurrent() - LastScanTime >= RefreshSeconds)
   {
      UpdateProfitBank();
      DrawDashboard();
      LastScanTime = TimeCurrent();
   }
}

//+------------------------------------------------------------------+
void OnTick()
{
   if(TimeCurrent() - LastScanTime >= RefreshSeconds)
   {
      UpdateProfitBank();
      DrawDashboard();
      LastScanTime = TimeCurrent();
   }
}

//+------------------------------------------------------------------+
void InitGroups()
{
   groupName[0]      = "FALCON";
   groupEnabled[0]   = EnableFalcon;
   groupBuyMagic[0]  = FalconMagicBuy;
   groupSellMagic[0] = FalconMagicSell;
   groupIsRange[0]   = false;
   groupIsManual[0]  = false;

   groupName[1]      = "HOPEBURST";
   groupEnabled[1]   = EnableHopeBurst;
   groupBuyMagic[1]  = HopeBurstMagic;
   groupSellMagic[1] = HopeBurstMagic;
   groupIsRange[1]   = false;
   groupIsManual[1]  = false;

   groupName[2]      = "SNIPER_AUTO";
   groupEnabled[2]   = EnableSniperAutoBuy;
   groupBuyMagic[2]  = SniperAutoMagicBuy;
   groupSellMagic[2] = SniperAutoMagicSell;
   groupIsRange[2]   = false;
   groupIsManual[2]  = false;

   groupName[3]       = "AURAX";
   groupEnabled[3]    = EnableAurax;
   groupFromMagic[3]  = AuraxMagicFrom;
   groupToMagic[3]    = AuraxMagicTo;
   groupIsRange[3]    = true;
   groupIsManual[3]   = false;

   groupName[4]      = Group5Name;
   groupEnabled[4]   = EnableGroup5;
   groupBuyMagic[4]  = Group5MagicBuy;
   groupSellMagic[4] = Group5MagicSell;
   groupIsRange[4]   = false;
   groupIsManual[4]  = false;

   groupName[5]      = "MANUAL";
   groupEnabled[5]   = IncludeManualOrders;
   groupBuyMagic[5]  = 0;
   groupSellMagic[5] = 0;
   groupIsRange[5]   = false;
   groupIsManual[5]  = true;
}

//+------------------------------------------------------------------+
bool PositionBelongsToGroup(int g, long magic, int type)
{
   if(g < 0 || g >= GROUPS) return false;
   if(!groupEnabled[g]) return false;

   if(groupIsManual[g])
      return (magic == 0);

   if(groupIsRange[g])
      return (magic >= groupFromMagic[g] && magic <= groupToMagic[g]);

   if(type == POSITION_TYPE_BUY)
      return (magic == groupBuyMagic[g]);

   if(type == POSITION_TYPE_SELL)
      return (magic == groupSellMagic[g]);

   return false;
}

//+------------------------------------------------------------------+
int GetPositionGroup(long magic, int type)
{
   for(int g=0; g<GROUPS; g++)
      if(PositionBelongsToGroup(g, magic, type))
         return g;
   return -1;
}

//+------------------------------------------------------------------+
double PositionPL()
{
   return PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
}

//+------------------------------------------------------------------+
void GetStats(int g, Stat &s)
{
   ZeroMemory(s);

   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;

      if(CurrentSymbolOnly && PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      long magic = PositionGetInteger(POSITION_MAGIC);
      int type = (int)PositionGetInteger(POSITION_TYPE);
      if(!PositionBelongsToGroup(g, magic, type)) continue;

      double lots = PositionGetDouble(POSITION_VOLUME);
      double pl = PositionPL();

      if(type == POSITION_TYPE_BUY)
      {
         s.buyAll++;
         s.buyLotsAll += lots;
         s.buyPLAll += pl;
         if(pl >= 0)
         {
            s.buyPos++;
            s.buyLotsPos += lots;
            s.buyPLPos += pl;
         }
         else
         {
            s.buyNeg++;
            s.buyLotsNeg += lots;
            s.buyPLNeg += pl;
         }
      }
      else if(type == POSITION_TYPE_SELL)
      {
         s.sellAll++;
         s.sellLotsAll += lots;
         s.sellPLAll += pl;
         if(pl >= 0)
         {
            s.sellPos++;
            s.sellLotsPos += lots;
            s.sellPLPos += pl;
         }
         else
         {
            s.sellNeg++;
            s.sellLotsNeg += lots;
            s.sellPLNeg += pl;
         }
      }
   }
}

//+------------------------------------------------------------------+
void UpdateProfitBank()
{
   datetime from = TimeCurrent() - 86400 * 30;
   datetime to = TimeCurrent();

   if(!HistorySelect(from, to)) return;

   int total = HistoryDealsTotal();
   for(int i=0; i<total; i++)
   {
      ulong deal = HistoryDealGetTicket(i);
      if(deal == 0) continue;
      if(deal <= LastDealTicket) continue;

      long entry = HistoryDealGetInteger(deal, DEAL_ENTRY);
      if(entry != DEAL_ENTRY_OUT) continue;

      string sym = HistoryDealGetString(deal, DEAL_SYMBOL);
      if(CurrentSymbolOnly && sym != _Symbol) continue;

      double profit = HistoryDealGetDouble(deal, DEAL_PROFIT)
                    + HistoryDealGetDouble(deal, DEAL_SWAP)
                    + HistoryDealGetDouble(deal, DEAL_COMMISSION);

      if(profit >= ProfitBank_MinAddProfit)
      {
         ProfitBank += profit;
         GlobalVariableSet(Prefix + "ProfitBank", ProfitBank);
      }

      LastDealTicket = deal;
      GlobalVariableSet(Prefix + "LastDeal", (double)LastDealTicket);
   }
}

//+------------------------------------------------------------------+
string Money(double v)
{
   return DoubleToString(v, 2);
}

//+------------------------------------------------------------------+
color PLColor(double v)
{
   if(v > 0.0001) return clrLime;
   if(v < -0.0001) return clrTomato;
   return clrWhite;
}

//+------------------------------------------------------------------+
void DeleteBossObjects()
{
   int total = ObjectsTotal(0, 0, -1);
   for(int i=total-1; i>=0; i--)
   {
      string name = ObjectName(0, i, 0, -1);
      if(StringFind(name, Prefix) == 0)
         ObjectDelete(0, name);
   }
}

//+------------------------------------------------------------------+
void Label(string name, string text, int x, int y, color clr, int size=-1)
{
   string obj = Prefix + name;
   if(size < 0) size = FontSize;

   if(ObjectFind(0, obj) < 0)
   {
      ObjectCreate(0, obj, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, obj, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetString(0, obj, OBJPROP_FONT, "Consolas");
   }

   ObjectSetInteger(0, obj, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, obj, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, obj, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, obj, OBJPROP_FONTSIZE, size);
   ObjectSetString(0, obj, OBJPROP_TEXT, text);
}

//+------------------------------------------------------------------+
void Button(string name, string text, int x, int y, int w, int h, color bg)
{
   string obj = Prefix + name;

   if(ObjectFind(0, obj) < 0)
   {
      ObjectCreate(0, obj, OBJ_BUTTON, 0, 0, 0);
      ObjectSetInteger(0, obj, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetString(0, obj, OBJPROP_FONT, "Arial");
      ObjectSetInteger(0, obj, OBJPROP_COLOR, clrWhite);
      ObjectSetInteger(0, obj, OBJPROP_BORDER_COLOR, clrBlack);
      ObjectSetInteger(0, obj, OBJPROP_FONTSIZE, 7);
   }

   ObjectSetInteger(0, obj, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, obj, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, obj, OBJPROP_XSIZE, w);
   ObjectSetInteger(0, obj, OBJPROP_YSIZE, h);
   ObjectSetInteger(0, obj, OBJPROP_BGCOLOR, bg);
   ObjectSetString(0, obj, OBJPROP_TEXT, text);
}

//+------------------------------------------------------------------+
void DrawDashboard()
{
   int y = StartY;

   Label("TITLE", "BOSS CONTROLLER V2.1  |  EA-wise Monitor + Close + ProfitBank + Stack", StartX, y, clrAqua, 10);
   y += 22;

   Label("BANK", "PROFIT BANK: $" + Money(ProfitBank), StartX, y, clrYellow, 10);
   y += 22;

   // Fixed columns. SELL P/L has separate clear column.
   int xEA=StartX, xBPN=StartX+110, xBLOT=StartX+220, xBPL=StartX+325;
   int xSPN=StartX+455, xSLOT=StartX+555, xSPL=StartX+645, xTPL=StartX+760;

   Label("H_EA", "EA", xEA, y, clrYellow);
   Label("H_BPN", "BUY +/-", xBPN, y, clrYellow);
   Label("H_BLOT", "BUY LOT", xBLOT, y, clrYellow);
   Label("H_BPL", "BUY P/L", xBPL, y, clrYellow);
   Label("H_SPN", "SELL +/-", xSPN, y, clrYellow);
   Label("H_SLOT", "SELL LOT", xSLOT, y, clrYellow);
   Label("H_SPL", "SELL P/L", xSPL, y, clrYellow);
   Label("H_TPL", "TOTAL P/L", xTPL, y, clrYellow);
   y += 20;

   double totalBuyLots=0, totalSellLots=0, totalPL=0;

   for(int g=0; g<GROUPS; g++)
   {
      if(!groupEnabled[g]) continue;

      Stat s; GetStats(g, s);
      double rowPL = s.buyPLAll + s.sellPLAll;
      totalBuyLots += s.buyLotsAll;
      totalSellLots += s.sellLotsAll;
      totalPL += rowPL;

      Label("EA_"+IntegerToString(g), groupName[g], xEA, y, clrWhite);
      Label("BPN_"+IntegerToString(g), "B+"+IntegerToString(s.buyPos)+"/B-"+IntegerToString(s.buyNeg), xBPN, y, clrLime);
      Label("BLOT_"+IntegerToString(g), DoubleToString(s.buyLotsAll, 2), xBLOT, y, clrAqua);
      Label("BPL_"+IntegerToString(g), Money(s.buyPLAll), xBPL, y, PLColor(s.buyPLAll));
      Label("SPN_"+IntegerToString(g), "S+"+IntegerToString(s.sellPos)+"/S-"+IntegerToString(s.sellNeg), xSPN, y, clrTomato);
      Label("SLOT_"+IntegerToString(g), DoubleToString(s.sellLotsAll, 2), xSLOT, y, clrAqua);
      Label("SPL_"+IntegerToString(g), Money(s.sellPLAll), xSPL, y, PLColor(s.sellPLAll));
      Label("TPL_"+IntegerToString(g), Money(rowPL), xTPL, y, PLColor(rowPL));

      int bx = ButtonStartX;
      Button("G"+IntegerToString(g)+"_BP", "Buy+", bx, y-4, ButtonW, ButtonH, clrGreen); bx += ButtonW + ButtonGap;
      Button("G"+IntegerToString(g)+"_BN", "Buy-", bx, y-4, ButtonW, ButtonH, clrMaroon); bx += ButtonW + ButtonGap;
      Button("G"+IntegerToString(g)+"_SP", "Sell+", bx, y-4, ButtonW, ButtonH, clrGreen); bx += ButtonW + ButtonGap;
      Button("G"+IntegerToString(g)+"_SN", "Sell-", bx, y-4, ButtonW, ButtonH, clrMaroon); bx += ButtonW + ButtonGap;
      Button("G"+IntegerToString(g)+"_ALLP", "All+", bx, y-4, ButtonW, ButtonH, clrSeaGreen); bx += ButtonW + ButtonGap;
      Button("G"+IntegerToString(g)+"_ALLN", "All-", bx, y-4, ButtonW, ButtonH, clrCrimson); bx += ButtonW + ButtonGap;
      Button("G"+IntegerToString(g)+"_WORST", "Worst", bx, y-4, 60, ButtonH, clrDarkOrange); bx += 60 + ButtonGap;
      Button("G"+IntegerToString(g)+"_ALL", "EA All", bx, y-4, 65, ButtonH, clrSaddleBrown);

      y += RowGap;
   }

   y += 8;
   Label("TOTAL", "TOTAL SYMBOL  BUY LOT: " + DoubleToString(totalBuyLots,2) +
                  "   SELL LOT: " + DoubleToString(totalSellLots,2) +
                  "   TOTAL P/L: " + Money(totalPL), StartX, y, PLColor(totalPL), 10);
   y += 28;

   int gx = StartX;
   Button("ALL_BP", "ALL BUY +", gx, y, 90, 22, clrGreen); gx += 100;
   Button("ALL_BN", "ALL BUY -", gx, y, 90, 22, clrMaroon); gx += 100;
   Button("ALL_SP", "ALL SELL +", gx, y, 90, 22, clrGreen); gx += 100;
   Button("ALL_SN", "ALL SELL -", gx, y, 90, 22, clrMaroon); gx += 100;
   Button("ALL_PROFIT", "ALL PROFIT", gx, y, 105, 22, clrSeaGreen); gx += 115;
   Button("ALL_LOSS", "ALL LOSS", gx, y, 95, 22, clrCrimson); gx += 105;
   Button("CLOSE_BUY", "CLOSE BUY", gx, y, 95, 22, clrChocolate); gx += 105;
   Button("CLOSE_SELL", "CLOSE SELL", gx, y, 95, 22, clrChocolate); gx += 105;
   Button("WORST_ALL", "CLOSE WORST", gx, y, 110, 22, clrDarkOrange); gx += 120;
   Button("RESET_BANK", "RESET BANK", gx, y, 100, 22, clrPurple); gx += 110;
   Button("PANIC", "PANIC ALL", gx, y, 95, 22, clrRed);

   y += 36;

   if(EnableStackDashboard)
      DrawStackDashboard(StartX, y);
}

//+------------------------------------------------------------------+
int FindZone(StackZone &zones[], int count, int side, double low)
{
   for(int i=0; i<count; i++)
      if(zones[i].side == side && MathAbs(zones[i].low - low) < 0.0001)
         return i;
   return -1;
}

//+------------------------------------------------------------------+
int FindZoneGroup(StackGroup &groups[], int count, int side, double low, int group)
{
   for(int i=0; i<count; i++)
      if(groups[i].side == side && groups[i].group == group && MathAbs(groups[i].low - low) < 0.0001)
         return i;
   return -1;
}

//+------------------------------------------------------------------+
void BuildStackData(StackZone &zones[], int &zoneCount, StackGroup &groups[], int &groupCount)
{
   ArrayResize(zones, 0);
   ArrayResize(groups, 0);
   zoneCount = 0;
   groupCount = 0;

   double range = StackRangeUSD;
   if(range <= 0.0) range = 15.0;

   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;

      if(CurrentSymbolOnly && PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      int type = (int)PositionGetInteger(POSITION_TYPE);
      if(type != POSITION_TYPE_BUY && type != POSITION_TYPE_SELL) continue;

      long magic = PositionGetInteger(POSITION_MAGIC);
      int g = GetPositionGroup(magic, type);
      if(g < 0) continue; // only configured EA groups/manual

      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double low = MathFloor(openPrice / range) * range;
      double high = low + range;
      double lot = PositionGetDouble(POSITION_VOLUME);
      double pl = PositionPL();

      int zi = FindZone(zones, zoneCount, type, low);
      if(zi < 0)
      {
         ArrayResize(zones, zoneCount + 1);
         zi = zoneCount;
         zones[zi].side = type;
         zones[zi].low = low;
         zones[zi].high = high;
         zones[zi].orders = 0;
         zones[zi].lots = 0;
         zones[zi].pl = 0;
         zoneCount++;
      }
      zones[zi].orders++;
      zones[zi].lots += lot;
      zones[zi].pl += pl;

      int gi = FindZoneGroup(groups, groupCount, type, low, g);
      if(gi < 0)
      {
         ArrayResize(groups, groupCount + 1);
         gi = groupCount;
         groups[gi].side = type;
         groups[gi].low = low;
         groups[gi].high = high;
         groups[gi].group = g;
         groups[gi].orders = 0;
         groups[gi].lots = 0;
         groups[gi].pl = 0;
         groupCount++;
      }
      groups[gi].orders++;
      groups[gi].lots += lot;
      groups[gi].pl += pl;
   }
}

//+------------------------------------------------------------------+
bool ZoneIsBetter(const StackZone &a,
                  const StackZone &b)
{
   double plA = MathAbs(a.pl);
   double plB = MathAbs(b.pl);

   // Higher DD stack first
   if(plA > plB)
      return true;

   if(plA < plB)
      return false;

   // If DD same -> more orders first
   if(a.orders > b.orders)
      return true;

   if(a.orders < b.orders)
      return false;

   // If orders same -> bigger lot stack first
   return a.lots > b.lots;
}
//+------------------------------------------------------------------+
void SortZones(StackZone &zones[], int count)
{
   for(int a=0; a<count-1; a++)
   {
      for(int b=a+1; b<count; b++)
      {
         if(ZoneIsBetter(zones[b], zones[a]))
         {
            StackZone tmp = zones[a];
            zones[a] = zones[b];
            zones[b] = tmp;
         }
      }
   }
}

//+------------------------------------------------------------------+
string BestEAByOrders(StackGroup &groups[], int groupCount, int side, double low)
{
   int best = -1;
   for(int i=0; i<groupCount; i++)
   {
      if(groups[i].side != side || MathAbs(groups[i].low - low) > 0.0001) continue;
      if(best < 0 || groups[i].orders > groups[best].orders)
         best = i;
   }
   if(best < 0) return "-";
   return groupName[groups[best].group] + " " + IntegerToString(groups[best].orders) + "ord";
}

//+------------------------------------------------------------------+
string BestEAByLoss(StackGroup &groups[], int groupCount, int side, double low)
{
   int best = -1;
   for(int i=0; i<groupCount; i++)
   {
      if(groups[i].side != side || MathAbs(groups[i].low - low) > 0.0001) continue;
      if(best < 0 || groups[i].pl < groups[best].pl)
         best = i;
   }
   if(best < 0) return "-";
   return groupName[groups[best].group] + " " + Money(groups[best].pl);
}

//+------------------------------------------------------------------+
void DrawStackSide(string title, int side, StackZone &zones[], int zoneCount, StackGroup &groups[], int groupCount, int x, int &y)
{
   Label("STACK_"+title+"_TITLE", title + " STACKS  |  Range: $" + DoubleToString(StackRangeUSD, 1), x, y, (side==POSITION_TYPE_BUY ? clrLime : clrTomato), 9);
   y += 18;

   Label("STACK_"+title+"_HDR", "ZONE              ORD   LOT     P/L        MAX ORDERS EA          MAX LOSS EA", x, y, clrYellow, 8);
   y += 16;

   int shown = 0;
   for(int i=0; i<zoneCount && shown<MaxStackRowsPerSide; i++)
   {
      if(zones[i].side != side) continue;
      if(zones[i].orders < StackMinOrdersToShow) continue;

      string zoneTxt = DoubleToString(zones[i].low, 0) + "-" + DoubleToString(zones[i].high, 0);
      string line = StringFormat("%-16s %3d  %6.2f  %9s   %-20s %-20s",
                                 zoneTxt,
                                 zones[i].orders,
                                 zones[i].lots,
                                 Money(zones[i].pl),
                                 BestEAByOrders(groups, groupCount, side, zones[i].low),
                                 BestEAByLoss(groups, groupCount, side, zones[i].low));

      Label("STACK_"+title+"_ROW_"+IntegerToString(shown), line, x, y, PLColor(zones[i].pl), 8);
      y += 16;
      shown++;
   }

   if(shown == 0)
   {
      Label("STACK_"+title+"_EMPTY", "No stacks found", x, y, clrSilver, 8);
      y += 16;
   }

   y += 8;
}

//+------------------------------------------------------------------+
void DrawStackDashboard(int x, int y)
{
   StackZone zones[];
   StackGroup zoneGroups[];
   int zoneCount = 0, groupCount = 0;

   BuildStackData(zones, zoneCount, zoneGroups, groupCount);
   SortZones(zones, zoneCount);

   Label("STACK_MAIN", "STACK ANALYSIS - EA-wise max stack by $ range", x, y, clrAqua, 10);
   y += 22;

   DrawStackSide("BUY", POSITION_TYPE_BUY, zones, zoneCount, zoneGroups, groupCount, x, y);
   DrawStackSide("SELL", POSITION_TYPE_SELL, zones, zoneCount, zoneGroups, groupCount, x, y);
}

//+------------------------------------------------------------------+
void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
{
   if(id != CHARTEVENT_OBJECT_CLICK) return;
   if(StringFind(sparam, Prefix) != 0) return;

   ObjectSetInteger(0, sparam, OBJPROP_STATE, false);

   string btn = sparam;
   StringReplace(btn, Prefix, "");

   if(ConfirmButtons)
   {
      if(armedButton != btn || TimeCurrent() - armedTime > 5)
      {
         armedButton = btn;
         armedTime = TimeCurrent();
         Alert("BOSS armed: ", btn, ". Click same button again within 5 seconds to execute.");
         return;
      }
   }

   ExecuteButton(btn);
   armedButton = "";
   armedTime = 0;
   DrawDashboard();
}

//+------------------------------------------------------------------+
void ExecuteButton(string btn)
{
   for(int g=0; g<GROUPS; g++)
   {
      string p = "G" + IntegerToString(g) + "_";
      if(btn == p+"BP")    { CloseByFilter(g, POSITION_TYPE_BUY,  1); return; }
      if(btn == p+"BN")    { CloseByFilter(g, POSITION_TYPE_BUY, -1); return; }
      if(btn == p+"SP")    { CloseByFilter(g, POSITION_TYPE_SELL, 1); return; }
      if(btn == p+"SN")    { CloseByFilter(g, POSITION_TYPE_SELL,-1); return; }
      if(btn == p+"ALLP")  { CloseByFilter(g, -1,  1); return; }
      if(btn == p+"ALLN")  { CloseByFilter(g, -1, -1); return; }
      if(btn == p+"WORST") { CloseWorstOrders(g); return; }
      if(btn == p+"ALL")   { CloseByFilter(g, -1,  0); return; }
   }

   if(btn == "ALL_BP")     { CloseByFilter(-1, POSITION_TYPE_BUY,  1); return; }
   if(btn == "ALL_BN")     { CloseByFilter(-1, POSITION_TYPE_BUY, -1); return; }
   if(btn == "ALL_SP")     { CloseByFilter(-1, POSITION_TYPE_SELL, 1); return; }
   if(btn == "ALL_SN")     { CloseByFilter(-1, POSITION_TYPE_SELL,-1); return; }
   if(btn == "ALL_PROFIT") { CloseByFilter(-1, -1,  1); return; }
   if(btn == "ALL_LOSS")   { CloseByFilter(-1, -1, -1); return; }
   if(btn == "CLOSE_BUY")  { CloseByFilter(-1, POSITION_TYPE_BUY,  0); return; }
   if(btn == "CLOSE_SELL") { CloseByFilter(-1, POSITION_TYPE_SELL, 0); return; }
   if(btn == "WORST_ALL")  { CloseWorstOrders(-1); return; }
   if(btn == "RESET_BANK") { ResetProfitBank(); return; }
   if(btn == "PANIC")      { CloseByFilter(-1, -1,  0); return; }
}

//+------------------------------------------------------------------+
void CloseByFilter(int group, int side, int profitMode)
{
   ulong tickets[];
   ArrayResize(tickets, 0);

   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;

      if(CurrentSymbolOnly && PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      int type = (int)PositionGetInteger(POSITION_TYPE);
      if(side != -1 && type != side) continue;

      long magic = PositionGetInteger(POSITION_MAGIC);
      bool belongs = false;

      if(group >= 0)
         belongs = PositionBelongsToGroup(group, magic, type);
      else
         belongs = (GetPositionGroup(magic, type) >= 0);

      if(!belongs) continue;

      double pl = PositionPL();
      if(profitMode == 1 && pl < 0) continue;
      if(profitMode == -1 && pl >= 0) continue;
      if(MaxSingleLossClose > 0 && pl < -MaxSingleLossClose) continue;

      int sz = ArraySize(tickets);
      ArrayResize(tickets, sz + 1);
      tickets[sz] = ticket;
   }

   for(int j=0; j<ArraySize(tickets); j++)
   {
      if(PositionSelectByTicket(tickets[j]))
      {
         trade.SetDeviationInPoints(SlippagePoints);
         trade.PositionClose(tickets[j]);
      }
   }
}

//+------------------------------------------------------------------+
void CloseWorstOrders(int group)
{
   ulong tickets[];
   double losses[];
   ArrayResize(tickets, 0);
   ArrayResize(losses, 0);

   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;

      if(CurrentSymbolOnly && PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      int type = (int)PositionGetInteger(POSITION_TYPE);
      long magic = PositionGetInteger(POSITION_MAGIC);

      bool belongs = false;
      if(group >= 0)
         belongs = PositionBelongsToGroup(group, magic, type);
      else
         belongs = (GetPositionGroup(magic, type) >= 0);

      if(!belongs) continue;

      double pl = PositionPL();
      if(pl >= 0) continue;
      if(MathAbs(pl) > WorstClose_MaxSingleLoss) continue;

      int sz = ArraySize(tickets);
      ArrayResize(tickets, sz + 1);
      ArrayResize(losses, sz + 1);
      tickets[sz] = ticket;
      losses[sz] = pl;
   }

   int count = ArraySize(tickets);
   if(count < WorstClose_MinOrders) return;

   for(int a=0; a<count-1; a++)
   {
      for(int b=a+1; b<count; b++)
      {
         if(losses[b] < losses[a])
         {
            double dl = losses[a]; losses[a] = losses[b]; losses[b] = dl;
            ulong tk = tickets[a]; tickets[a] = tickets[b]; tickets[b] = tk;
         }
      }
   }

   int closeCount = MathMin(WorstClose_MaxOrders, count);
   for(int x=0; x<closeCount; x++)
   {
      double need = MathAbs(losses[x]);
      if(ProfitBank - need < ProfitBank_Reserve) break;

      if(PositionSelectByTicket(tickets[x]) && trade.PositionClose(tickets[x]))
      {
         ProfitBank -= need;
         if(ProfitBank < 0) ProfitBank = 0;
         GlobalVariableSet(Prefix + "ProfitBank", ProfitBank);
      }
   }
}

//+------------------------------------------------------------------+
void ResetProfitBank()
{
   ProfitBank = 0.0;
   GlobalVariableSet(Prefix + "ProfitBank", ProfitBank);
}
//+------------------------------------------------------------------+
