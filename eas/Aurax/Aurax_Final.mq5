//+------------------------------------------------------------------+
//|             Aurax PRO AUTO USD V3.37 Single ProfitBank Safe Exit              |
//|  Auto EMA Grid + USD Spacing + Individual/Cycle/Global TP         |
//|  Individual Trail + Persistent Profit Bank Exit + Dashboard        |
//+------------------------------------------------------------------+
#property strict
#property version "3.37"

#include <Trade/Trade.mqh>
CTrade trade;

//================ INPUTS =================//
input double LotSize = 0.01;

//--- Auto grid core
input double GridSpacing_USD = 3.0;       // Direct price movement for XAUUSD: 3.0 = $3
input int    MaxOrders       = 5;         // Orders per cycle
input int    MaxCycles       = 3;         // Total cycles
input int    TimeGapSec      = 60;        // Minimum seconds between same-side orders

//--- Temporary manage-only controls
input bool   PauseBuyEntries  = true;      // true = no new BUY orders, manage existing BUY only
input bool   PauseSellEntries = true;      // true = no new SELL orders, manage existing SELL only

//--- USD profit targets
input double IndividualTP_USD = 10.0;     // Broker-level TP per order
input double CycleTP_USD      = 50.0;     // Close one cycle side at profit target
input double GlobalTP_USD     = 150.0;    // Close all BUY side or SELL side

//--- Individual trailing by price movement
input bool   UseIndividualTrail = true;
input double TrailStart_USD     = 5.0;    // Trail starts after price moves $5 in profit
input double TrailLock_USD      = 2.0;    // Lock minimum $2
input double TrailGap_USD       = 2.0;    // SL trails $2 behind price

//--- Basket trailing by side floating profit
input bool   UseBasketTrail      = true;
input double BasketTrailStart_USD = 40.0; // Start basket trailing when side profit reaches this
input double BasketTrailGap_USD   = 15.0; // Close if side profit falls this much from peak


//--- Smart Profit Bank Exit: booked profit reduces opposite-side DD
input bool   UseSmartProfitBankExit = true;
input bool   BankUseAuraxOnly       = true;   // true = only Aurax closed deals, false = same symbol all EA/manual closed deals
input int    BankHistoryLookbackDays = 7;     // History scan range for closed profit bank
input double BankProfitUsePercent   = 80.0;   // Use only this % of booked profit for DD reduction
input double BankMinProfitToAdd_USD   = 2.0;    // Ignore tiny booked profits below this amount
input bool   BankPersistAfterRestart  = true;   // Save bank balance using terminal global variables
input double BankMinKeepProfit_USD  = 5.0;    // Keep this much net booked profit safe
input int    BankMaxWorstClosePerTick = 2;    // Max opposite losing orders closed per tick
input double BankMaxLossPerOrder_USD = 100.0; // Safety: do not close one very large loser above this loss
input double BankMinSideDD_USD       = 50.0;  // Activate only if opposite side floating loss exceeds this
input string BankCommentTag          = "AuraxBankExit";

//--- ProfitBank Assisted Trail for old stacked orders
input bool   UseProfitBankAssistedTrail = true;   // Replaces blind bank close logic
input int    OldStackMinHours           = 12;     // Only orders older than this are eligible
input double RecoveryZoneUSD            = 5.0;    // Price bucket size, example 4500-4505
input double RecoveryNearUSD            = 8.0;    // Current price must be near old stack zone
input int    AssistedMinStackOrders     = 3;      // Minimum old orders in same zone to build basket
input double AssistedTrailStart_USD     = 5.0;    // Start assisted basket trail after bank-adjusted basket >= this
input double AssistedTrailGap_USD       = 2.0;    // Close old basket if bank-adjusted basket drops this much from peak
input double AssistedBankUsePercent     = 70.0;   // Use this % of available bank for assisted basket

//--- Dashboard stack analysis
input double StackBucketUSD             = 5.0;
input int    StackWarnCount             = 5;

//--- Trend and safety spacing
input int    EMA_Period       = 50;
input double NoTradeZone_USD  = 1.0;      // Extra duplicate-zone protection

//--- Magic and label
input int    MagicBase   = 20000;
input string OrderLabel  = "Aurax PRO AUTO USD";

//--- Dashboard uses simple Comment() only to avoid chart label clutter/blinking

//================ GLOBALS =================//
datetime lastBuyTime  = 0;
datetime lastSellTime = 0;

int emaHandle = INVALID_HANDLE;

double buyBasketPeakProfit  = 0.0;
double sellBasketPeakProfit = 0.0;

string buyBlockReason  = "";
string sellBlockReason = "";


//--- Smart bank globals
ulong  processedDealTickets[];
double profitBank = 0.0;      // One common booked-profit bank for safe DD reduction
string smartExitStatus = "Smart bank idle";
double assistedBuyBasketPeak  = 0.0;   // old BUY stack effective peak
double assistedSellBasketPeak = 0.0;   // old SELL stack effective peak
double totalBankAdded = 0.0;
double totalBankUsed = 0.0;
string bankCandidateStatus = "No candidate";

//================ INIT =================//
int OnInit()
{
   emaHandle = iMA(_Symbol, PERIOD_M15, EMA_Period, 0, MODE_EMA, PRICE_CLOSE);

   if(emaHandle == INVALID_HANDLE)
   {
      Print("Aurax V3: EMA handle failed.");
      return INIT_FAILED;
   }

   trade.SetDeviationInPoints(30);
   LoadProfitBankState();
   InitializeProfitBankHistoryMarker();
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   SaveProfitBankState();
   Comment("");

   if(emaHandle != INVALID_HANDLE)
      IndicatorRelease(emaHandle);
}

//================ UTILS =================//
bool IsAuraxMagic(int magic)
{
   return (magic >= MagicBase && magic < MagicBase + MaxCycles);
}

double GetEMA()
{
   double buffer[];
   ArraySetAsSeries(buffer, true);

   if(CopyBuffer(emaHandle, 0, 0, 1, buffer) <= 0)
      return 0.0;

   return buffer[0];
}

double USDToPriceMove(double usd, double lots)
{
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   if(usd <= 0.0 || lots <= 0.0 || tickValue <= 0.0 || tickSize <= 0.0)
      return 0.0;

   return (usd * tickSize) / (tickValue * lots);
}

double GetBrokerTPPrice(bool isBuy, double openPrice, double usdTarget, double lot)
{
   double move = USDToPriceMove(usdTarget, lot);
   if(move <= 0.0) return 0.0;

   double tp = isBuy ? openPrice + move : openPrice - move;
   return NormalizeDouble(tp, _Digits);
}

bool AllowBuy()
{
   double ema = GetEMA();
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   return (ema > 0.0 && bid > ema);
}

bool AllowSell()
{
   double ema = GetEMA();
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   return (ema > 0.0 && ask < ema);
}

//================ POSITION STATS =================//
int CountPositions(bool isBuy, int magicFilter = -1)
{
   int count = 0;

   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;

      int type  = (int)PositionGetInteger(POSITION_TYPE);
      int magic = (int)PositionGetInteger(POSITION_MAGIC);

      if(!IsAuraxMagic(magic)) continue;
      if(magicFilter != -1 && magic != magicFilter) continue;

      if(isBuy  && type == POSITION_TYPE_BUY)  count++;
      if(!isBuy && type == POSITION_TYPE_SELL) count++;
   }

   return count;
}

double GetSideLots(bool isBuy, int magicFilter = -1)
{
   double lots = 0.0;

   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;

      int type  = (int)PositionGetInteger(POSITION_TYPE);
      int magic = (int)PositionGetInteger(POSITION_MAGIC);

      if(!IsAuraxMagic(magic)) continue;
      if(magicFilter != -1 && magic != magicFilter) continue;

      if(isBuy  && type == POSITION_TYPE_BUY)  lots += PositionGetDouble(POSITION_VOLUME);
      if(!isBuy && type == POSITION_TYPE_SELL) lots += PositionGetDouble(POSITION_VOLUME);
   }

   return lots;
}

double GetSideProfit(bool isBuy, int magicFilter = -1)
{
   double total = 0.0;

   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;

      int type  = (int)PositionGetInteger(POSITION_TYPE);
      int magic = (int)PositionGetInteger(POSITION_MAGIC);

      if(!IsAuraxMagic(magic)) continue;
      if(magicFilter != -1 && magic != magicFilter) continue;

      if(isBuy  && type == POSITION_TYPE_BUY)  total += PositionGetDouble(POSITION_PROFIT);
      if(!isBuy && type == POSITION_TYPE_SELL) total += PositionGetDouble(POSITION_PROFIT);
   }

   return total;
}

double GetLastOrderPrice(bool isBuy)
{
   double lastPrice = 0.0;
   datetime lastTime = 0;

   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;

      int type  = (int)PositionGetInteger(POSITION_TYPE);
      int magic = (int)PositionGetInteger(POSITION_MAGIC);

      if(!IsAuraxMagic(magic)) continue;
      if(isBuy  && type != POSITION_TYPE_BUY)  continue;
      if(!isBuy && type != POSITION_TYPE_SELL) continue;

      datetime t = (datetime)PositionGetInteger(POSITION_TIME);

      if(t > lastTime)
      {
         lastTime = t;
         lastPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      }
   }

   return lastPrice;
}

double GetWeightedAveragePrice(bool isBuy, int magicFilter = -1)
{
   double lots = 0.0;
   double sum  = 0.0;

   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;

      int type  = (int)PositionGetInteger(POSITION_TYPE);
      int magic = (int)PositionGetInteger(POSITION_MAGIC);

      if(!IsAuraxMagic(magic)) continue;
      if(magicFilter != -1 && magic != magicFilter) continue;
      if(isBuy  && type != POSITION_TYPE_BUY)  continue;
      if(!isBuy && type != POSITION_TYPE_SELL) continue;

      double lot   = PositionGetDouble(POSITION_VOLUME);
      double price = PositionGetDouble(POSITION_PRICE_OPEN);

      lots += lot;
      sum  += price * lot;
   }

   if(lots <= 0.0) return 0.0;
   return sum / lots;
}

double GetBasketTPFromUSD(bool isBuy, double usdTarget, int magicFilter = -1)
{
   double lots = GetSideLots(isBuy, magicFilter);
   double avg  = GetWeightedAveragePrice(isBuy, magicFilter);

   if(lots <= 0.0 || avg <= 0.0) return 0.0;

   double move = USDToPriceMove(usdTarget, lots);
   if(move <= 0.0) return 0.0;

   double price = isBuy ? avg + move : avg - move;
   return NormalizeDouble(price, _Digits);
}

double GetNextExecutionLowerPrice(bool isBuy)
{
   double lastPrice = GetLastOrderPrice(isBuy);
   if(lastPrice <= 0.0) return 0.0;
   return NormalizeDouble(lastPrice - GridSpacing_USD, _Digits);
}

double GetNextExecutionUpperPrice(bool isBuy)
{
   double lastPrice = GetLastOrderPrice(isBuy);
   if(lastPrice <= 0.0) return 0.0;
   return NormalizeDouble(lastPrice + GridSpacing_USD, _Digits);
}

// Kept for backward compatibility with old dashboard logic.
double GetNextExecutionPrice(bool isBuy)
{
   if(isBuy)
      return GetNextExecutionLowerPrice(isBuy);
   return GetNextExecutionUpperPrice(isBuy);
}

int SecondsLeft(bool isBuy)
{
   datetime lastTime = isBuy ? lastBuyTime : lastSellTime;
   int left = TimeGapSec - (int)(TimeCurrent() - lastTime);
   if(left < 0) left = 0;
   return left;
}


//================ SMART PROFIT BANK EXIT =================//

string BankGVName(string key)
{
   return "AuraxBank_" + _Symbol + "_" + IntegerToString(MagicBase) + "_" + key;
}

void SaveProfitBankState()
{
   if(!BankPersistAfterRestart) return;
   GlobalVariableSet(BankGVName("BANK"), profitBank);
   GlobalVariableSet(BankGVName("ADDED"), totalBankAdded);
   GlobalVariableSet(BankGVName("USED"), totalBankUsed);
}

void LoadProfitBankState()
{
   if(!BankPersistAfterRestart) return;

   // New V3.37 single bank.
   if(GlobalVariableCheck(BankGVName("BANK")))
      profitBank = GlobalVariableGet(BankGVName("BANK"));
   else
   {
      // One-time migration from older split BUY/SELL bank values.
      if(GlobalVariableCheck(BankGVName("BUY_BANK")))
         profitBank += GlobalVariableGet(BankGVName("BUY_BANK"));
      if(GlobalVariableCheck(BankGVName("SELL_BANK")))
         profitBank += GlobalVariableGet(BankGVName("SELL_BANK"));
   }

   if(GlobalVariableCheck(BankGVName("ADDED"))) totalBankAdded = GlobalVariableGet(BankGVName("ADDED"));
   if(GlobalVariableCheck(BankGVName("USED")))  totalBankUsed  = GlobalVariableGet(BankGVName("USED"));
}

void InitializeProfitBankHistoryMarker()
{
   datetime fromTime = TimeCurrent() - BankHistoryLookbackDays * 86400;
   datetime toTime   = TimeCurrent();
   if(!HistorySelect(fromTime, toTime)) return;

   int deals = HistoryDealsTotal();
   for(int i = 0; i < deals; i++)
   {
      ulong deal = HistoryDealGetTicket(i);
      if(deal != 0) MarkProcessedDeal(deal);
   }
}

bool IsProcessedDeal(ulong dealTicket)
{
   for(int i = 0; i < ArraySize(processedDealTickets); i++)
      if(processedDealTickets[i] == dealTicket) return true;
   return false;
}

void MarkProcessedDeal(ulong dealTicket)
{
   int n = ArraySize(processedDealTickets);
   ArrayResize(processedDealTickets, n + 1);
   processedDealTickets[n] = dealTicket;
}

bool DealAllowedForBank(long magic, string symbol)
{
   if(symbol != _Symbol) return false;
   if(BankUseAuraxOnly)
      return IsAuraxMagic((int)magic);
   return true; // same symbol all closed deals can fund the bank, but exits still close only Aurax positions
}

void UpdateProfitBankFromHistory()
{
   if(!UseSmartProfitBankExit) return;

   datetime fromTime = TimeCurrent() - BankHistoryLookbackDays * 86400;
   datetime toTime   = TimeCurrent();
   if(!HistorySelect(fromTime, toTime)) return;

   int deals = HistoryDealsTotal();
   for(int i = 0; i < deals; i++)
   {
      ulong deal = HistoryDealGetTicket(i);
      if(deal == 0 || IsProcessedDeal(deal)) continue;

      long entry = HistoryDealGetInteger(deal, DEAL_ENTRY);
      if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_INOUT)
      {
         MarkProcessedDeal(deal);
         continue;
      }

      string symbol = HistoryDealGetString(deal, DEAL_SYMBOL);
      long magic    = HistoryDealGetInteger(deal, DEAL_MAGIC);
      if(!DealAllowedForBank(magic, symbol))
      {
         MarkProcessedDeal(deal);
         continue;
      }

      double profit = HistoryDealGetDouble(deal, DEAL_PROFIT)
                    + HistoryDealGetDouble(deal, DEAL_SWAP)
                    + HistoryDealGetDouble(deal, DEAL_COMMISSION);

      if(profit < BankMinProfitToAdd_USD)
      {
         MarkProcessedDeal(deal);
         continue;
      }

      double usableProfit = profit * (BankProfitUsePercent / 100.0);

      // V3.37: one common ProfitBank. Any booked profit can safely reduce old BUY or SELL DD.
      profitBank += usableProfit;
      totalBankAdded += usableProfit;

      SaveProfitBankState();
      MarkProcessedDeal(deal);
   }
}

ulong FindWorstLosingPosition(bool findBuySide, double &lossAbs)
{
   ulong worstTicket = 0;
   lossAbs = 0.0;

   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;

      int magic = (int)PositionGetInteger(POSITION_MAGIC);
      if(!IsAuraxMagic(magic)) continue;

      int type = (int)PositionGetInteger(POSITION_TYPE);
      if(findBuySide  && type != POSITION_TYPE_BUY)  continue;
      if(!findBuySide && type != POSITION_TYPE_SELL) continue;

      double pl = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      if(pl >= 0.0) continue;

      double absLoss = MathAbs(pl);
      if(absLoss > lossAbs)
      {
         lossAbs = absLoss;
         worstTicket = ticket;
      }
   }
   return worstTicket;
}

double ZoneStart(double price, double bucket)
{
   if(bucket <= 0.0) bucket = 5.0;
   return MathFloor(price / bucket) * bucket;
}

bool IsOldEnough(datetime openTime)
{
   return ((TimeCurrent() - openTime) >= OldStackMinHours * 3600);
}

bool SameZone(double price, double zoneStart, double bucket)
{
   return (price >= zoneStart && price < zoneStart + bucket);
}

bool FindOldStackZone(bool isBuy, double &bestZone, int &bestCount, double &bestProfit, double &bestLots)
{
   double zones[];
   int counts[];
   double profits[];
   double lots[];
   datetime oldest[];

   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;

      int magic = (int)PositionGetInteger(POSITION_MAGIC);
      if(!IsAuraxMagic(magic)) continue;

      int type = (int)PositionGetInteger(POSITION_TYPE);
      if(isBuy  && type != POSITION_TYPE_BUY)  continue;
      if(!isBuy && type != POSITION_TYPE_SELL) continue;

      datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);
      if(!IsOldEnough(openTime)) continue;

      double price  = PositionGetDouble(POSITION_PRICE_OPEN);
      double zone   = ZoneStart(price, RecoveryZoneUSD);
      double pl     = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      double volume = PositionGetDouble(POSITION_VOLUME);

      int idx = -1;
      for(int z = 0; z < ArraySize(zones); z++)
      {
         if(MathAbs(zones[z] - zone) < 0.00001)
         {
            idx = z;
            break;
         }
      }

      if(idx < 0)
      {
         int n = ArraySize(zones);
         ArrayResize(zones, n + 1);
         ArrayResize(counts, n + 1);
         ArrayResize(profits, n + 1);
         ArrayResize(lots, n + 1);
         ArrayResize(oldest, n + 1);
         zones[n] = zone;
         counts[n] = 0;
         profits[n] = 0.0;
         lots[n] = 0.0;
         oldest[n] = openTime;
         idx = n;
      }

      counts[idx]++;
      profits[idx] += pl;
      lots[idx] += volume;
      if(openTime < oldest[idx]) oldest[idx] = openTime;
   }

   bestZone = 0.0;
   bestCount = 0;
   bestProfit = 0.0;
   bestLots = 0.0;

   double bestScore = -1.0;
   for(int i = 0; i < ArraySize(zones); i++)
   {
      if(counts[i] < AssistedMinStackOrders) continue;
      if(profits[i] >= 0.0) continue; // only old DD stacks need bank assistance

      double lossAbs = MathAbs(profits[i]);
      double ageHours = (double)(TimeCurrent() - oldest[i]) / 3600.0;
      double score = (lossAbs * 2.0) + (counts[i] * 5.0) + ageHours;

      if(score > bestScore)
      {
         bestScore = score;
         bestZone = zones[i];
         bestCount = counts[i];
         bestProfit = profits[i];
         bestLots = lots[i];
      }
   }

   return (bestScore >= 0.0);
}

bool CurrentPriceNearZone(bool isBuy, double zoneStart)
{
   double price = isBuy ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
                        : SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   double low  = zoneStart - RecoveryNearUSD;
   double high = zoneStart + RecoveryZoneUSD + RecoveryNearUSD;
   return (price >= low && price <= high);
}

int CloseOldStackBasket(bool isBuy, double zoneStart, double &closedLossAbs)
{
   int closed = 0;
   closedLossAbs = 0.0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;

      int magic = (int)PositionGetInteger(POSITION_MAGIC);
      if(!IsAuraxMagic(magic)) continue;

      int type = (int)PositionGetInteger(POSITION_TYPE);
      if(isBuy  && type != POSITION_TYPE_BUY)  continue;
      if(!isBuy && type != POSITION_TYPE_SELL) continue;

      datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);
      if(!IsOldEnough(openTime)) continue;

      double price = PositionGetDouble(POSITION_PRICE_OPEN);
      if(!SameZone(price, zoneStart, RecoveryZoneUSD)) continue;

      double pl = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      double lossAbs = MathMax(0.0, -pl);

      // Safety: do not close a very large single loser from the bank.
      if(lossAbs > BankMaxLossPerOrder_USD)
         continue;

      if(trade.PositionClose(ticket))
      {
         closed++;
         closedLossAbs += lossAbs;
      }
   }

   return closed;
}

void CheckAssistedSide(bool isBuy)
{
   double sideProfit = GetSideProfit(isBuy);
   if(sideProfit > -BankMinSideDD_USD)
   {
      if(isBuy) assistedBuyBasketPeak = 0.0;
      else      assistedSellBasketPeak = 0.0;
      return;
   }

   double zone = 0.0, stackProfit = 0.0, stackLots = 0.0;
   int oldCount = 0;
   if(!FindOldStackZone(isBuy, zone, oldCount, stackProfit, stackLots))
      return;

   double availableBank = MathMax(0.0, profitBank - BankMinKeepProfit_USD);
   double usableBank = availableBank * (AssistedBankUsePercent / 100.0);
   double effectivePL = stackProfit + usableBank;
   string side = isBuy ? "BUY" : "SELL";

   bankCandidateStatus = side + " zone " + DoubleToString(zone, 0) + "-" + DoubleToString(zone + RecoveryZoneUSD, 0) +
                         " cnt " + IntegerToString(oldCount) +
                         " stackPL $" + DoubleToString(stackProfit, 2) +
                         " usableBank $" + DoubleToString(usableBank, 2) +
                         " eff $" + DoubleToString(effectivePL, 2);

   if(!CurrentPriceNearZone(isBuy, zone))
   {
      if(isBuy) assistedBuyBasketPeak = 0.0;
      else      assistedSellBasketPeak = 0.0;
      smartExitStatus = "Waiting price near " + bankCandidateStatus;
      return;
   }

   if(usableBank <= 0.0 || effectivePL < AssistedTrailStart_USD)
   {
      if(isBuy) assistedBuyBasketPeak = 0.0;
      else      assistedSellBasketPeak = 0.0;
      smartExitStatus = "Near zone, waiting more bank/recovery: " + bankCandidateStatus;
      return;
   }

   double peak = isBuy ? assistedBuyBasketPeak : assistedSellBasketPeak;
   if(effectivePL > peak) peak = effectivePL;

   if(isBuy) assistedBuyBasketPeak = peak;
   else      assistedSellBasketPeak = peak;

   smartExitStatus = side + " old stack trailing | " + bankCandidateStatus +
                     " peak $" + DoubleToString(peak, 2);

   if(peak - effectivePL >= AssistedTrailGap_USD)
   {
      double closedLossAbs = 0.0;
      int closed = CloseOldStackBasket(isBuy, zone, closedLossAbs);
      if(closed > 0)
      {
         double used = MathMin(usableBank, closedLossAbs);
         profitBank = MathMax(0.0, profitBank - used);
         totalBankUsed += used;
         SaveProfitBankState();
         smartExitStatus = "Single bank closed old " + side + " stack: " + IntegerToString(closed) +
                           " orders, used $" + DoubleToString(used, 2);
      }

      if(isBuy) assistedBuyBasketPeak = 0.0;
      else      assistedSellBasketPeak = 0.0;
   }
}

void ManageProfitBankAssistedTrail()
{
   smartExitStatus = "Assisted bank idle";
   bankCandidateStatus = "No candidate";
   if(!UseSmartProfitBankExit || !UseProfitBankAssistedTrail) return;

   UpdateProfitBankFromHistory();

   // V3.37: one bank can safely assist either old BUY or old SELL DD stacks.
   // Run both sides; safety checks stop blind close when price is far or bank is insufficient.
   CheckAssistedSide(true);
   CheckAssistedSide(false);
}

// old blind worst-loss close removed. Bank now works only through old stacked recovery-zone assisted trailing.
void ManageSmartProfitBankExit()
{
   ManageProfitBankAssistedTrail();
}

//================ CLOSE =================//
void ClosePositions(bool isBuy, int magicFilter = -1)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;

      int type  = (int)PositionGetInteger(POSITION_TYPE);
      int magic = (int)PositionGetInteger(POSITION_MAGIC);

      if(!IsAuraxMagic(magic)) continue;
      if(magicFilter != -1 && magic != magicFilter) continue;

      if(isBuy  && type != POSITION_TYPE_BUY)  continue;
      if(!isBuy && type != POSITION_TYPE_SELL) continue;

      trade.PositionClose(ticket);
   }
}

//================ TRAILING =================//
void ManageIndividualTrailing()
{
   if(!UseIndividualTrail) return;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;

      int magic = (int)PositionGetInteger(POSITION_MAGIC);
      if(!IsAuraxMagic(magic)) continue;

      int type = (int)PositionGetInteger(POSITION_TYPE);

      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double oldSL     = PositionGetDouble(POSITION_SL);

      if(type == POSITION_TYPE_BUY)
      {
         double moveProfit = bid - openPrice;

         if(moveProfit >= TrailStart_USD)
         {
            double newSL   = bid - TrailGap_USD;
            double minLock = openPrice + TrailLock_USD;

            if(newSL < minLock)
               newSL = minLock;

            newSL = NormalizeDouble(newSL, _Digits);

            // TP removed when trailing starts
            if(oldSL == 0.0 || newSL > oldSL)
               trade.PositionModify(ticket, newSL, 0.0);
         }
      }

      if(type == POSITION_TYPE_SELL)
      {
         double moveProfit = openPrice - ask;

         if(moveProfit >= TrailStart_USD)
         {
            double newSL   = ask + TrailGap_USD;
            double minLock = openPrice - TrailLock_USD;

            if(newSL > minLock)
               newSL = minLock;

            newSL = NormalizeDouble(newSL, _Digits);

            // TP removed when trailing starts
            if(oldSL == 0.0 || newSL < oldSL)
               trade.PositionModify(ticket, newSL, 0.0);
         }
      }
   }
}

void ManageBasketTrailing()
{
   if(!UseBasketTrail) return;

   int buyCount  = CountPositions(true);
   int sellCount = CountPositions(false);

   double buyProfit  = GetSideProfit(true);
   double sellProfit = GetSideProfit(false);

   if(buyCount > 0 && buyProfit >= BasketTrailStart_USD)
   {
      if(buyProfit > buyBasketPeakProfit)
         buyBasketPeakProfit = buyProfit;

      if(buyBasketPeakProfit - buyProfit >= BasketTrailGap_USD)
      {
         ClosePositions(true);
         buyBasketPeakProfit = 0.0;
      }
   }
   else if(buyCount == 0)
   {
      buyBasketPeakProfit = 0.0;
   }

   if(sellCount > 0 && sellProfit >= BasketTrailStart_USD)
   {
      if(sellProfit > sellBasketPeakProfit)
         sellBasketPeakProfit = sellProfit;

      if(sellBasketPeakProfit - sellProfit >= BasketTrailGap_USD)
      {
         ClosePositions(false);
         sellBasketPeakProfit = 0.0;
      }
   }
   else if(sellCount == 0)
   {
      sellBasketPeakProfit = 0.0;
   }
}

//================ TP MANAGEMENT =================//
void ManageGlobalTP()
{
   double buyProfit  = GetSideProfit(true);
   double sellProfit = GetSideProfit(false);

   if(CountPositions(true) > 0 && buyProfit >= GlobalTP_USD)
   {
      ClosePositions(true);
      buyBasketPeakProfit = 0.0;
   }

   if(CountPositions(false) > 0 && sellProfit >= GlobalTP_USD)
   {
      ClosePositions(false);
      sellBasketPeakProfit = 0.0;
   }
}

void ManageCycleTP()
{
   for(int c = 0; c < MaxCycles; c++)
   {
      int magic = MagicBase + c;

      double cBuyProfit  = GetSideProfit(true, magic);
      double cSellProfit = GetSideProfit(false, magic);

      if(CountPositions(true, magic) > 0 && cBuyProfit >= CycleTP_USD)
         ClosePositions(true, magic);

      if(CountPositions(false, magic) > 0 && cSellProfit >= CycleTP_USD)
         ClosePositions(false, magic);
   }
}

//================ OPEN GRID =================//
bool CanOpenGrid(bool isBuy)
{
   if(isBuy) buyBlockReason = "";
   else      sellBlockReason = "";

   if(isBuy)
   {
      if(TimeCurrent() - lastBuyTime < TimeGapSec)
      {
         buyBlockReason = "Waiting time gap: " + IntegerToString(SecondsLeft(true)) + "s";
         return false;
      }

      if(!AllowBuy())
      {
         buyBlockReason = "Blocked: price below EMA";
         return false;
      }
   }
   else
   {
      if(TimeCurrent() - lastSellTime < TimeGapSec)
      {
         sellBlockReason = "Waiting time gap: " + IntegerToString(SecondsLeft(false)) + "s";
         return false;
      }

      if(!AllowSell())
      {
         sellBlockReason = "Blocked: price above EMA";
         return false;
      }
   }

   int totalCount = CountPositions(isBuy);
   int maxTotal   = MaxOrders * MaxCycles;

   if(totalCount >= maxTotal)
   {
      if(isBuy) buyBlockReason = "Blocked: max orders reached";
      else      sellBlockReason = "Blocked: max orders reached";
      return false;
   }

   double lastPrice = GetLastOrderPrice(isBuy);
   double price = isBuy ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                        : SymbolInfoDouble(_Symbol, SYMBOL_BID);

   if(lastPrice > 0.0)
   {
      // ANY-SIDE SPACING FIX:
      // Earlier BUY waited only below last BUY, and SELL waited only above last SELL.
      // Now each side can add when price has moved GridSpacing_USD either up OR down
      // from that side's last order, while still blocking duplicate/same-range stacking.
      double dist = MathAbs(price - lastPrice);

      if(dist < GridSpacing_USD)
      {
         if(isBuy)
            buyBlockReason = "Waiting BUY spacing either side: " + DoubleToString(dist, 2) + "/" + DoubleToString(GridSpacing_USD, 2);
         else
            sellBlockReason = "Waiting SELL spacing either side: " + DoubleToString(dist, 2) + "/" + DoubleToString(GridSpacing_USD, 2);
         return false;
      }

      if(dist < NoTradeZone_USD)
      {
         if(isBuy) buyBlockReason = "Blocked: no-trade duplicate zone";
         else      sellBlockReason = "Blocked: no-trade duplicate zone";
         return false;
      }
   }

   return true;
}

void OpenGrid(bool isBuy)
{
   // Side-wise pause: management functions still run, only new entries are blocked.
   if(isBuy && PauseBuyEntries)
   {
      buyBlockReason = "PAUSED BUY - managing existing only";
      return;
   }

   if(!isBuy && PauseSellEntries)
   {
      sellBlockReason = "PAUSED SELL - managing existing only";
      return;
   }

   if(!CanOpenGrid(isBuy)) return;

   int totalCount = CountPositions(isBuy);
   int cycle = totalCount / MaxOrders;

   if(cycle >= MaxCycles)
      return;

   int magic = MagicBase + cycle;

   double price = isBuy ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                        : SymbolInfoDouble(_Symbol, SYMBOL_BID);

   double tp = GetBrokerTPPrice(isBuy, price, IndividualTP_USD, LotSize);

   if(tp <= 0.0)
   {
      if(isBuy) buyBlockReason = "TP calculation failed";
      else      sellBlockReason = "TP calculation failed";
      Print("Aurax V3: TP calculation failed.");
      return;
   }

   trade.SetExpertMagicNumber(magic);

   bool result = false;

   if(isBuy)
      result = trade.Buy(LotSize, _Symbol, price, 0.0, tp, OrderLabel + " BUY C" + IntegerToString(cycle + 1));
   else
      result = trade.Sell(LotSize, _Symbol, price, 0.0, tp, OrderLabel + " SELL C" + IntegerToString(cycle + 1));

   if(result)
   {
      if(isBuy)
      {
         lastBuyTime = TimeCurrent();
         buyBlockReason = "Last BUY opened";
      }
      else
      {
         lastSellTime = TimeCurrent();
         sellBlockReason = "Last SELL opened";
      }
   }
   else
   {
      int err = GetLastError();
      if(isBuy) buyBlockReason = "BUY failed error: " + IntegerToString(err);
      else      sellBlockReason = "SELL failed error: " + IntegerToString(err);

      Print("Aurax V3 order failed. Error: ", err);
   }
}

//================ DASHBOARD =================//
string CycleLine(bool isBuy)
{
   string side = isBuy ? "BUY" : "SELL";
   string out = "";

   for(int c = 0; c < MaxCycles; c++)
   {
      int magic = MagicBase + c;
      int count = CountPositions(isBuy, magic);
      double profit = GetSideProfit(isBuy, magic);
      double lots = GetSideLots(isBuy, magic);

      out += side + " C" + IntegerToString(c + 1) +
             " | Orders: " + IntegerToString(count) +
             " | Lots: " + DoubleToString(lots, 2) +
             " | P/L: " + DoubleToString(profit, 2) + "\n";
   }

   return out;
}

void AddStackDashboardZone(string &zones[], int &counts[], double price)
{
   double bucket = StackBucketUSD;
   if(bucket <= 0.0) bucket = 5.0;
   double zoneStart = ZoneStart(price, bucket);
   string zone = DoubleToString(zoneStart, 0) + "-" + DoubleToString(zoneStart + bucket, 0);

   for(int i = 0; i < ArraySize(zones); i++)
   {
      if(zones[i] == zone)
      {
         counts[i]++;
         return;
      }
   }

   int n = ArraySize(zones);
   ArrayResize(zones, n + 1);
   ArrayResize(counts, n + 1);
   zones[n] = zone;
   counts[n] = 1;
}

string StackDashboardLine(bool isBuy)
{
   string zones[];
   int counts[];

   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;

      int magic = (int)PositionGetInteger(POSITION_MAGIC);
      if(!IsAuraxMagic(magic)) continue;

      int type = (int)PositionGetInteger(POSITION_TYPE);
      if(isBuy  && type != POSITION_TYPE_BUY)  continue;
      if(!isBuy && type != POSITION_TYPE_SELL) continue;

      AddStackDashboardZone(zones, counts, PositionGetDouble(POSITION_PRICE_OPEN));
   }

   string out = isBuy ? "BUY STACK ZONES\n" : "SELL STACK ZONES\n";
   for(int i = 0; i < ArraySize(zones); i++)
   {
      string warn = counts[i] >= StackWarnCount ? " <<< STACKED" : "";
      out += zones[i] + " : " + IntegerToString(counts[i]) + warn + "\n";
   }
   return out;
}

void DrawDashboard()
{
   double ema = GetEMA();
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   int buyCount  = CountPositions(true);
   int sellCount = CountPositions(false);

   double buyLots  = GetSideLots(true);
   double sellLots = GetSideLots(false);

   double buyProfit  = GetSideProfit(true);
   double sellProfit = GetSideProfit(false);
   double netProfit  = buyProfit + sellProfit;

   double lastBuy  = GetLastOrderPrice(true);
   double lastSell = GetLastOrderPrice(false);

   string bias = "NEUTRAL";
   if(bid > ema) bias = "BUY ALLOWED";
   if(ask < ema) bias = "SELL ALLOWED";

   string text = "";
   text += "========== AURAX V3.37 SINGLE BANK SAFE EXIT ==========" + "\n";
   text += "Symbol: " + _Symbol + " | Magic: " + IntegerToString(MagicBase) + "-" + IntegerToString(MagicBase + MaxCycles - 1) + "\n";
   text += "Pause BUY: " + string(PauseBuyEntries ? "ON" : "OFF") + " | Pause SELL: " + string(PauseSellEntries ? "ON" : "OFF") + "\n";
   text += "EMA M15(" + IntegerToString(EMA_Period) + "): " + DoubleToString(ema, _Digits) + " | Bias: " + bias + "\n";
   text += "Bid/Ask: " + DoubleToString(bid, _Digits) + " / " + DoubleToString(ask, _Digits) + "\n";
   text += "---------------------------------------------\n";
   text += "BUY  Orders: " + IntegerToString(buyCount) + " | Lots: " + DoubleToString(buyLots, 2) + " | P/L: " + DoubleToString(buyProfit, 2) + "\n";
   text += "SELL Orders: " + IntegerToString(sellCount) + " | Lots: " + DoubleToString(sellLots, 2) + " | P/L: " + DoubleToString(sellProfit, 2) + "\n";
   text += "NET P/L: " + DoubleToString(netProfit, 2) + "\n";
   text += "Last BUY: " + DoubleToString(lastBuy, _Digits) + " | Last SELL: " + DoubleToString(lastSell, _Digits) + "\n";
   text += "BUY Status: " + buyBlockReason + "\n";
   text += "SELL Status: " + sellBlockReason + "\n";
   text += "---------------------------------------------\n";
   text += "Individual Trail: " + string(UseIndividualTrail ? "ON" : "OFF") +
           " | Start $" + DoubleToString(TrailStart_USD, 2) +
           " | Lock $" + DoubleToString(TrailLock_USD, 2) +
           " | Gap $" + DoubleToString(TrailGap_USD, 2) + "\n";
   text += "Basket Trail: " + string(UseBasketTrail ? "ON" : "OFF") +
           " | Start $" + DoubleToString(BasketTrailStart_USD, 2) +
           " | Gap $" + DoubleToString(BasketTrailGap_USD, 2) + "\n";
   text += "BUY Peak: " + DoubleToString(buyBasketPeakProfit, 2) + " | SELL Peak: " + DoubleToString(sellBasketPeakProfit, 2) + "\n";
   text += "---------------------------------------------\n";
   text += "PROFITBANK SAFE EXIT: " + string((UseSmartProfitBankExit && UseProfitBankAssistedTrail) ? "ON" : "OFF") + "\n";
   text += "Single ProfitBank: $" + DoubleToString(profitBank, 2) +
           " | Usable: $" + DoubleToString(MathMax(0.0, profitBank - BankMinKeepProfit_USD) * (AssistedBankUsePercent / 100.0), 2) +
           " | Keep: $" + DoubleToString(BankMinKeepProfit_USD, 2) + "\n";
   text += "Bank Added: $" + DoubleToString(totalBankAdded, 2) +
           " | Bank Used: $" + DoubleToString(totalBankUsed, 2) + "\n";
   text += "OldStack > " + IntegerToString(OldStackMinHours) + "h | Zone $" + DoubleToString(RecoveryZoneUSD, 2) +
           " | Near $" + DoubleToString(RecoveryNearUSD, 2) +
           " | Min DD $" + DoubleToString(BankMinSideDD_USD, 2) + "\n";
   text += "Candidate: " + bankCandidateStatus + "\n";
   text += "Smart: " + smartExitStatus + "\n";
   text += "---------------------------------------------\n";
   text += "CYCLE WISE ORDERS\n";
   text += CycleLine(true);
   text += CycleLine(false);
   text += "---------------------------------------------\n";
   text += "STACKING ANALYSIS\n";
   text += StackDashboardLine(true);
   text += StackDashboardLine(false);
   text += "=============================================";

   Comment(text);
}

//================ MAIN =================//
void OnTick()
{
   ManageIndividualTrailing();
   ManageBasketTrailing();

   ManageGlobalTP();
   ManageCycleTP();

   ManageSmartProfitBankExit();

   OpenGrid(true);
   OpenGrid(false);

   DrawDashboard();
}
//+------------------------------------------------------------------+
