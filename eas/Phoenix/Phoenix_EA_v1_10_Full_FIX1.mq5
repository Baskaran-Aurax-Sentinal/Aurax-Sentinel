//+------------------------------------------------------------------+
//| Phoenix_EA_v1_12_HedgeToggle_FIXED.mq5                  |
//| Phoenix v1.13 Hedge Balance Guard + TP Forward Trail Patch       |
//| BUY dynamic grid + Auto SELL tactical + Auto Hedge imbalance      |
//+------------------------------------------------------------------+
#property strict
#property version   "1.13"
#property description "Phoenix v1.12: Hedge trend toggle fixed, separate stack zones, SELL density control, TP forward trailing"

#include <Trade/Trade.mqh>
CTrade trade;

//------------------------- INPUTS ----------------------------------
input string EA_Name                    = "Phoenix_EA_v1_12_HedgeToggle_FIXED";
input ulong  MagicNumber                = 2026052810;
input double BaseLot                    = 0.01;
input bool   UseBrokerTP                = true;
input double BuyTP_USD                  = 5.0;
input double SellTP_USD                 = 3.0;
input double HedgeTP_USD                = 3.0;

// Trailing stop - money based per position, TP remains as broker backup
input bool   EnableTrailing             = true;
input bool   ForwardTPWithTrail         = true;   // Move broker TP forward when trailing SL advances
input double BuyTrailStart_USD          = 2.0;
input double BuyTrailLock_USD           = 1.0;
input double BuyTrailGap_USD            = 1.0;
input double SellTrailStart_USD         = 2.0;
input double SellTrailLock_USD          = 1.0;
input double SellTrailGap_USD           = 1.0;
input double HedgeTrailStart_USD        = 2.0;
input double HedgeTrailLock_USD         = 1.0;
input double HedgeTrailGap_USD          = 1.0;

// BUY grid dynamic spacing
input bool   EnableBuyGrid              = true;
input int    BuyCooldownSeconds         = 20;
input double Spacing_L1_15_USD          = 1.0;
input double Spacing_L16_30_USD         = 2.0;
input double Spacing_L31_50_USD         = 5.0;
input double Spacing_L50Plus_USD        = 10.0;
input int    MaxBuyOrders               = 250;
input double LevelLockTolerance_USD     = 0.25;

// SELL tactical module - auto enabled for demo reaction testing
input bool   EnableAutoSellModule       = true;
input int    MaxNegativeSellOrders      = 5;
input int    SellCooldownSeconds        = 900;
input double SellZoneSizeUSD            = 2.0;   // max sell density zone size
input int    MaxSellOrdersPerZone       = 2;     // max normal sells inside SellZoneSizeUSD
input double BottomBlockPercent24H      = 20.0;  // no sell inside bottom x% of 24h range
input double TopBlockPercent24H         = 20.0;  // no buy hedge inside top x% of 24h range
input int    EMAFastPeriod              = 20;
input int    EMASlowPeriod              = 50;
input bool   RequireM15Bearish          = true;
input bool   RequireM5Bearish           = true;

// Hedge imbalance module - auto enabled for demo reaction testing
input bool   UseTrendFilterForHedge     = false;
input bool   EnableHedgeEngine          = true;
input double ImbalanceLotStep           = 0.01;
input double MaxHedgeLots               = 0.04;   // max total hedge lots per direction
input double HedgeTargetPercent         = 70.0;  // 100 = hedge only until exposure is balanced
input double HedgeBalanceToleranceLots  = 0.001;  // tiny tolerance to avoid over-hedge by rounding
input int    HedgeCooldownSeconds       = 30;
input double MinDDForHedge_USD          = 20.0;

// Profit bank
input bool   EnableProfitBank           = true;
input double ProfitBankUsePercent       = 30.0;

// Safety
input double SoftLockDD_USD             = 0.0;   // 0 = disabled. Example 1000 stops new entries
input double HardLockDD_USD             = 0.0;   // 0 = disabled. Example 2000 stops all entries
input double MaxTotalLots               = 5.0;
input int    SlippagePoints             = 30;

// Dashboard
input bool   ShowDashboard              = true;
input int    DashboardCorner            = CORNER_LEFT_UPPER;
input int    DashboardX                 = 10;
input int    DashboardY                 = 20;
input double BuyStackZoneUSD            = 10.0;  // BUY dashboard grouping
input double SellStackZoneUSD           = 2.0;   // SELL dashboard grouping
input double StackZoneUSD               = 10.0;  // legacy overview grouping
input double DetailStackZoneUSD         = 2.0;   // legacy detailed grouping

//------------------------- GLOBALS ---------------------------------
datetime g_lastBuyTime   = 0;
datetime g_lastSellTime  = 0;
datetime g_lastHedgeTime = 0;
datetime g_bankResetTime = 0;
double   g_bankTotal     = 0.0;
double   g_bankBuy       = 0.0;
double   g_bankSell      = 0.0;
double   g_bankHedge     = 0.0;
string   DASH_PREFIX     = "PX_DASH_";
string   BTN_RESET_BANK  = "PX_BTN_RESET_BANK";

//------------------------- HELPERS ---------------------------------
double NormalizeLots(double lots)
{
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   lots = MathMax(minLot, MathMin(maxLot, lots));
   if(step > 0.0) lots = MathFloor(lots / step) * step;
   return NormalizeDouble(lots, 2);
}

double PriceNormalize(double price)
{
   return NormalizeDouble(price, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
}

double TickValuePerLot()
{
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickSize <= 0.0) return 0.0;
   return tickValue / tickSize;
}

double MoneyToPriceDistance(double lot, double money)
{
   if(lot <= 0.0 || money <= 0.0) return 0.0;
   double moneyPerPriceUnit = TickValuePerLot() * lot;
   if(moneyPerPriceUnit <= 0.0) return 0.0;
   return money / moneyPerPriceUnit;
}

double TPPrice(ENUM_ORDER_TYPE type, double entry, double lot, double targetMoney)
{
   if(!UseBrokerTP || targetMoney <= 0.0 || lot <= 0.0) return 0.0;
   double dist = MoneyToPriceDistance(lot, targetMoney);
   if(dist <= 0.0) return 0.0;
   if(type == ORDER_TYPE_BUY)  return PriceNormalize(entry + dist);
   if(type == ORDER_TYPE_SELL) return PriceNormalize(entry - dist);
   return 0.0;
}

bool IsOurPosition()
{
   return (PositionGetString(POSITION_SYMBOL) == _Symbol && (ulong)PositionGetInteger(POSITION_MAGIC) == MagicNumber);
}

bool IsHedgeComment(string c) { return (StringFind(c, "PX_HEDGE") >= 0); }
bool IsSellComment(string c)  { return (StringFind(c, "PX_SELL")  >= 0); }
bool IsBuyComment(string c)   { return (StringFind(c, "PX_BUY")   >= 0); }

//------------------------- POSITION SUMMARY ------------------------
struct ModuleStats
{
   int    orders;
   double lots;
   double pl;
   double avg;
   double highest;
   double lowest;
};

void ResetStats(ModuleStats &s)
{
   s.orders = 0;
   s.lots = 0.0;
   s.pl = 0.0;
   s.avg = 0.0;
   s.highest = -DBL_MAX;
   s.lowest = DBL_MAX;
}

void AddPositionToStats(ModuleStats &s, double lot, double price, double pl)
{
   s.orders++;
   s.avg += price * lot;
   s.lots += lot;
   s.pl += pl;
   s.highest = MathMax(s.highest, price);
   s.lowest = MathMin(s.lowest, price);
}

void FinalizeStats(ModuleStats &s)
{
   if(s.lots > 0.0) s.avg = s.avg / s.lots;
   else
   {
      s.avg = 0.0;
      s.highest = 0.0;
      s.lowest = 0.0;
   }
}

void GetModuleStats(ModuleStats &buy, ModuleStats &sell, ModuleStats &hedge, int &negSellCount)
{
   ResetStats(buy);
   ResetStats(sell);
   ResetStats(hedge);
   negSellCount = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
      if(!IsOurPosition()) continue;

      long type = PositionGetInteger(POSITION_TYPE);
      double lot = PositionGetDouble(POSITION_VOLUME);
      double price = PositionGetDouble(POSITION_PRICE_OPEN);
      double pl = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      string c = PositionGetString(POSITION_COMMENT);

      if(IsHedgeComment(c))
      {
         AddPositionToStats(hedge, lot, price, pl);
      }
      else if(type == POSITION_TYPE_BUY)
      {
         AddPositionToStats(buy, lot, price, pl);
      }
      else if(type == POSITION_TYPE_SELL)
      {
         AddPositionToStats(sell, lot, price, pl);
         if(pl < 0.0) negSellCount++;
      }
   }
   FinalizeStats(buy);
   FinalizeStats(sell);
   FinalizeStats(hedge);
}

double CurrentFloatingDD()
{
   ModuleStats b, s, h;
   int ns;
   GetModuleStats(b, s, h, ns);
   double total = b.pl + s.pl + h.pl;
   return (total < 0.0 ? -total : 0.0);
}

double CurrentTotalLots()
{
   ModuleStats b, s, h;
   int ns;
   GetModuleStats(b, s, h, ns);
   return b.lots + s.lots + h.lots;
}

bool EntriesLocked()
{
   double dd = CurrentFloatingDD();
   if(HardLockDD_USD > 0.0 && dd >= HardLockDD_USD) return true;
   if(SoftLockDD_USD > 0.0 && dd >= SoftLockDD_USD) return true;
   if(CurrentTotalLots() >= MaxTotalLots) return true;
   return false;
}

//---------------------- 24H RANGE ----------------------------------
bool Get24HRange(double &hi, double &lo)
{
   hi = -DBL_MAX;
   lo = DBL_MAX;
   datetime from = TimeCurrent() - 24 * 60 * 60;
   MqlRates rates[];
   int copied = CopyRates(_Symbol, PERIOD_M15, from, TimeCurrent(), rates);
   if(copied <= 0) return false;
   for(int i = 0; i < copied; i++)
   {
      hi = MathMax(hi, rates[i].high);
      lo = MathMin(lo, rates[i].low);
   }
   return (hi > lo && hi > 0.0 && lo > 0.0);
}

bool IsInBottom24HZone()
{
   double hi, lo;
   if(!Get24HRange(hi, lo)) return false;
   double limit = lo + (hi - lo) * BottomBlockPercent24H / 100.0;
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   return (bid <= limit);
}

bool IsInTop24HZone()
{
   double hi, lo;
   if(!Get24HRange(hi, lo)) return false;
   double limit = hi - (hi - lo) * TopBlockPercent24H / 100.0;
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   return (ask >= limit);
}

//---------------------- TREND / CONFIRMATION -----------------------
double EMAValue(ENUM_TIMEFRAMES tf, int period, int shift)
{
   int handle = iMA(_Symbol, tf, period, 0, MODE_EMA, PRICE_CLOSE);
   if(handle == INVALID_HANDLE) return 0.0;
   double buf[];
   ArraySetAsSeries(buf, true);
   int copied = CopyBuffer(handle, 0, shift, 1, buf);
   IndicatorRelease(handle);
   if(copied <= 0) return 0.0;
   return buf[0];
}

bool BearishCandle(ENUM_TIMEFRAMES tf, int shift = 1)
{
   MqlRates r[];
   ArraySetAsSeries(r, true);
   if(CopyRates(_Symbol, tf, 0, shift + 2, r) <= shift) return false;
   return (r[shift].close < r[shift].open);
}

bool BullishCandle(ENUM_TIMEFRAMES tf, int shift = 1)
{
   MqlRates r[];
   ArraySetAsSeries(r, true);
   if(CopyRates(_Symbol, tf, 0, shift + 2, r) <= shift) return false;
   return (r[shift].close > r[shift].open);
}

bool BullishTrendM15()
{
   double fast = EMAValue(PERIOD_M15, EMAFastPeriod, 1);
   double slow = EMAValue(PERIOD_M15, EMASlowPeriod, 1);
   return (fast > 0.0 && slow > 0.0 && fast > slow);
}

bool BearishTrendM15()
{
   double fast = EMAValue(PERIOD_M15, EMAFastPeriod, 1);
   double slow = EMAValue(PERIOD_M15, EMASlowPeriod, 1);
   return (fast > 0.0 && slow > 0.0 && fast < slow);
}

string TrendTextM15()
{
   if(BullishTrendM15()) return "BULLISH";
   if(BearishTrendM15()) return "BEARISH";
   return "NEUTRAL";
}

bool SellConfirmationOK()
{
   if(IsInBottom24HZone()) return false;
   if(RequireM15Bearish)
   {
      if(!BearishTrendM15() && !BearishCandle(PERIOD_M15, 1)) return false;
   }
   if(RequireM5Bearish)
   {
      if(!BearishCandle(PERIOD_M5, 1)) return false;
   }
   return true;
}

//---------------------- TRAILING -----------------------------------
void GetTrailInputs(string comment, long posType, double &startMoney, double &lockMoney, double &gapMoney)
{
   if(IsHedgeComment(comment))
   {
      startMoney = HedgeTrailStart_USD;
      lockMoney  = HedgeTrailLock_USD;
      gapMoney   = HedgeTrailGap_USD;
      return;
   }
   if(posType == POSITION_TYPE_BUY)
   {
      startMoney = BuyTrailStart_USD;
      lockMoney  = BuyTrailLock_USD;
      gapMoney   = BuyTrailGap_USD;
   }
   else
   {
      startMoney = SellTrailStart_USD;
      lockMoney  = SellTrailLock_USD;
      gapMoney   = SellTrailGap_USD;
   }
}

void ManageTrailingStops()
{
   if(!EnableTrailing) return;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   int stopsLevel = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minStopDist = stopsLevel * _Point;

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(SlippagePoints);

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
      if(!IsOurPosition()) continue;

      long type       = PositionGetInteger(POSITION_TYPE);
      double lot      = PositionGetDouble(POSITION_VOLUME);
      double open     = PositionGetDouble(POSITION_PRICE_OPEN);
      double curSL    = PositionGetDouble(POSITION_SL);
      double curTP    = PositionGetDouble(POSITION_TP);
      string comment  = PositionGetString(POSITION_COMMENT);

      double startMoney, lockMoney, gapMoney;
      GetTrailInputs(comment, type, startMoney, lockMoney, gapMoney);
      if(startMoney <= 0.0 || gapMoney <= 0.0) continue;

      double startDist = MoneyToPriceDistance(lot, startMoney);
      double lockDist  = MoneyToPriceDistance(lot, lockMoney);
      double gapDist   = MoneyToPriceDistance(lot, gapMoney);
      if(startDist <= 0.0 || gapDist <= 0.0) continue;

      if(type == POSITION_TYPE_BUY)
      {
         if((bid - open) < startDist) continue;
         double lockSL  = open + lockDist;
         double trailSL = bid - gapDist;
         double newSL   = PriceNormalize(MathMax(lockSL, trailSL));
         double newTP   = curTP;
         if(ForwardTPWithTrail)
         {
            double tpDist = MoneyToPriceDistance(lot, (IsHedgeComment(comment) ? HedgeTP_USD : BuyTP_USD));
            if(tpDist > 0.0)
            {
               double trailTP = PriceNormalize(bid + tpDist);
               if(curTP == 0.0 || trailTP > curTP + (_Point * 2.0)) newTP = trailTP;
            }
         }
         if(minStopDist > 0.0 && (bid - newSL) < minStopDist) continue;
         if(curSL == 0.0 || newSL > curSL + (_Point * 2.0) || newTP != curTP)
            trade.PositionModify(ticket, newSL, newTP);
      }
      else if(type == POSITION_TYPE_SELL)
      {
         if((open - ask) < startDist) continue;
         double lockSL  = open - lockDist;
         double trailSL = ask + gapDist;
         double newSL   = PriceNormalize(MathMin(lockSL, trailSL));
         double newTP   = curTP;
         if(ForwardTPWithTrail)
         {
            double tpDist = MoneyToPriceDistance(lot, (IsHedgeComment(comment) ? HedgeTP_USD : SellTP_USD));
            if(tpDist > 0.0)
            {
               double trailTP = PriceNormalize(ask - tpDist);
               if(curTP == 0.0 || trailTP < curTP - (_Point * 2.0)) newTP = trailTP;
            }
         }
         if(minStopDist > 0.0 && (newSL - ask) < minStopDist) continue;
         if(curSL == 0.0 || newSL < curSL - (_Point * 2.0) || newTP != curTP)
            trade.PositionModify(ticket, newSL, newTP);
      }
   }
}

//---------------------- BUY GRID -----------------------------------
double DynamicSpacingByBuyCount(int buyCount)
{
   int nextLevel = buyCount + 1;
   if(nextLevel <= 15) return Spacing_L1_15_USD;
   if(nextLevel <= 30) return Spacing_L16_30_USD;
   if(nextLevel <= 50) return Spacing_L31_50_USD;
   return Spacing_L50Plus_USD;
}

bool HasBuyNearPrice(double price, double tolerance)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
      if(!IsOurPosition()) continue;
      if(PositionGetInteger(POSITION_TYPE) != POSITION_TYPE_BUY) continue;
      if(IsHedgeComment(PositionGetString(POSITION_COMMENT))) continue;
      double p = PositionGetDouble(POSITION_PRICE_OPEN);
      if(MathAbs(p - price) <= tolerance) return true;
   }
   return false;
}

bool GetBuyExtremes(double &lowestBuy, double &highestBuy)
{
   lowestBuy = DBL_MAX;
   highestBuy = -DBL_MAX;
   bool found = false;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
      if(!IsOurPosition()) continue;
      if(PositionGetInteger(POSITION_TYPE) != POSITION_TYPE_BUY) continue;
      if(IsHedgeComment(PositionGetString(POSITION_COMMENT))) continue;
      double p = PositionGetDouble(POSITION_PRICE_OPEN);
      lowestBuy = MathMin(lowestBuy, p);
      highestBuy = MathMax(highestBuy, p);
      found = true;
   }
   return found;
}

bool OpenBuy(string comment)
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double lot = NormalizeLots(BaseLot);
   double tp = TPPrice(ORDER_TYPE_BUY, ask, lot, BuyTP_USD);
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(SlippagePoints);
   bool ok = trade.Buy(lot, _Symbol, ask, 0.0, tp, comment);
   if(ok) g_lastBuyTime = TimeCurrent();
   return ok;
}

void ManageBuyGrid()
{
   if(!EnableBuyGrid || EntriesLocked()) return;
   if(TimeCurrent() - g_lastBuyTime < BuyCooldownSeconds) return;

   ModuleStats b, s, h;
   int ns;
   GetModuleStats(b, s, h, ns);
   if(b.orders >= MaxBuyOrders) return;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double lowest, highest;
   if(!GetBuyExtremes(lowest, highest))
   {
      OpenBuy("PX_BUY_L1");
      return;
   }

   double spacing = DynamicSpacingByBuyCount(b.orders);
   if(bid <= lowest - spacing || bid >= highest + spacing)
   {
      if(!HasBuyNearPrice(bid, LevelLockTolerance_USD))
      {
         string c = "PX_BUY_L" + IntegerToString(b.orders + 1);
         OpenBuy(c);
      }
   }
}

//---------------------- SELL MODULE --------------------------------
int CountNormalSellsInZone(double price, double zoneSize)
{
   if(zoneSize <= 0.0) return 0;
   double zoneLow = MathFloor(price / zoneSize) * zoneSize;
   double zoneHigh = zoneLow + zoneSize;
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
      if(!IsOurPosition()) continue;
      if(PositionGetInteger(POSITION_TYPE) != POSITION_TYPE_SELL) continue;
      if(IsHedgeComment(PositionGetString(POSITION_COMMENT))) continue;
      double p = PositionGetDouble(POSITION_PRICE_OPEN);
      if(p >= zoneLow && p < zoneHigh) count++;
   }
   return count;
}

bool SellZoneDensityOK()
{
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   return (CountNormalSellsInZone(bid, SellZoneSizeUSD) < MaxSellOrdersPerZone);
}

bool OpenSell(string comment, double lotMult = 1.0)
{
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double lot = NormalizeLots(BaseLot * lotMult);
   double tp = TPPrice(ORDER_TYPE_SELL, bid, lot, SellTP_USD);
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(SlippagePoints);
   bool ok = trade.Sell(lot, _Symbol, bid, 0.0, tp, comment);
   if(ok) g_lastSellTime = TimeCurrent();
   return ok;
}

void ManageSellModule()
{
   if(!EnableAutoSellModule || EntriesLocked()) return;
   if(TimeCurrent() - g_lastSellTime < SellCooldownSeconds) return;

   ModuleStats b, s, h;
   int ns;
   GetModuleStats(b, s, h, ns);
   if(ns >= MaxNegativeSellOrders) return;
   if(!SellZoneDensityOK()) return;
   if(!SellConfirmationOK()) return;

   // Tactical sell only, not grid. One entry per cooldown.
   OpenSell("PX_SELL_AUTO", 1.0);
}

//---------------------- HEDGE ENGINE -------------------------------
void GetExposureLots(double &normalBuyLots, double &normalSellLots, double &hedgeBuyLots, double &hedgeSellLots)
{
   normalBuyLots = 0.0;
   normalSellLots = 0.0;
   hedgeBuyLots = 0.0;
   hedgeSellLots = 0.0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
      if(!IsOurPosition()) continue;

      long type = PositionGetInteger(POSITION_TYPE);
      double lot = PositionGetDouble(POSITION_VOLUME);
      string c = PositionGetString(POSITION_COMMENT);

      if(IsHedgeComment(c))
      {
         if(type == POSITION_TYPE_BUY) hedgeBuyLots += lot;
         else if(type == POSITION_TYPE_SELL) hedgeSellLots += lot;
      }
      else
      {
         if(type == POSITION_TYPE_BUY) normalBuyLots += lot;
         else if(type == POSITION_TYPE_SELL) normalSellLots += lot;
      }
   }
}

bool OpenHedgeBuy(double lot)
{
   if(IsInTop24HZone()) return false;
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   lot = NormalizeLots(lot);
   double tp = TPPrice(ORDER_TYPE_BUY, ask, lot, HedgeTP_USD);
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(SlippagePoints);
   bool ok = trade.Buy(lot, _Symbol, ask, 0.0, tp, "PX_HEDGE_BUY");
   if(ok) g_lastHedgeTime = TimeCurrent();
   return ok;
}

bool OpenHedgeSell(double lot)
{
   if(IsInBottom24HZone()) return false;
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   lot = NormalizeLots(lot);
   double tp = TPPrice(ORDER_TYPE_SELL, bid, lot, HedgeTP_USD);
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(SlippagePoints);
   bool ok = trade.Sell(lot, _Symbol, bid, 0.0, tp, "PX_HEDGE_SELL");
   if(ok) g_lastHedgeTime = TimeCurrent();
   return ok;
}

void ManageHedgeEngine()
{
   if(!EnableHedgeEngine) return;
   if(EntriesLocked()) return;   // Current behavior: locks still block hedge. Later SoftLock will allow recovery hedge.
   if(TimeCurrent() - g_lastHedgeTime < HedgeCooldownSeconds) return;
   if(CurrentFloatingDD() < MinDDForHedge_USD) return;

   double normalBuyLots, normalSellLots, hedgeBuyLots, hedgeSellLots;
   GetExposureLots(normalBuyLots, normalSellLots, hedgeBuyLots, hedgeSellLots);

   double ratio = MathMax(0.0, MathMin(100.0, HedgeTargetPercent)) / 100.0;
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);

   // BUY-heavy exposure gets protective HEDGE SELL, but only until target/balance is reached.
   double buyDominance = normalBuyLots - normalSellLots;
   if(buyDominance > HedgeBalanceToleranceLots)
   {
      if(UseTrendFilterForHedge && !BearishTrendM15()) return;
      if(IsInBottom24HZone()) return;

      double targetHedgeSell = buyDominance * ratio;
      double remainingTarget = targetHedgeSell - hedgeSellLots;
      double remainingCap = MaxHedgeLots - hedgeSellLots;
      double openLot = MathMin(ImbalanceLotStep, MathMin(remainingTarget, remainingCap));
      openLot = NormalizeLots(openLot);

      if(openLot >= minLot && remainingTarget > HedgeBalanceToleranceLots && remainingCap >= minLot)
         OpenHedgeSell(openLot);
      return;
   }

   // SELL-heavy exposure gets protective HEDGE BUY, but only until target/balance is reached.
   double sellDominance = normalSellLots - normalBuyLots;
   if(sellDominance > HedgeBalanceToleranceLots)
   {
      if(UseTrendFilterForHedge && !BullishTrendM15()) return;
      if(IsInTop24HZone()) return;

      double targetHedgeBuy = sellDominance * ratio;
      double remainingTarget = targetHedgeBuy - hedgeBuyLots;
      double remainingCap = MaxHedgeLots - hedgeBuyLots;
      double openLot = MathMin(ImbalanceLotStep, MathMin(remainingTarget, remainingCap));
      openLot = NormalizeLots(openLot);

      if(openLot >= minLot && remainingTarget > HedgeBalanceToleranceLots && remainingCap >= minLot)
         OpenHedgeBuy(openLot);
      return;
   }

   // Already balanced or no directional exposure. No new hedge order.
}

//---------------------- PROFIT BANK --------------------------------
string DealModuleFromPosition(ulong positionId, long exitDealType)
{
   int deals = HistoryDealsTotal();
   for(int j = 0; j < deals; j++)
   {
      ulong d2 = HistoryDealGetTicket(j);
      if(d2 == 0) continue;
      if((ulong)HistoryDealGetInteger(d2, DEAL_POSITION_ID) != positionId) continue;
      if(HistoryDealGetString(d2, DEAL_SYMBOL) != _Symbol) continue;
      if((ulong)HistoryDealGetInteger(d2, DEAL_MAGIC) != MagicNumber) continue;
      long e2 = HistoryDealGetInteger(d2, DEAL_ENTRY);
      if(e2 != DEAL_ENTRY_IN && e2 != DEAL_ENTRY_INOUT) continue;
      string c2 = HistoryDealGetString(d2, DEAL_COMMENT);
      if(IsHedgeComment(c2)) return "HEDGE";
      if(IsSellComment(c2))  return "SELL";
      if(IsBuyComment(c2))   return "BUY";
      long t2 = HistoryDealGetInteger(d2, DEAL_TYPE);
      if(t2 == DEAL_TYPE_BUY)  return "BUY";
      if(t2 == DEAL_TYPE_SELL) return "SELL";
   }

   // Fallback: an OUT BUY deal usually closes a SELL position; an OUT SELL deal usually closes a BUY position.
   if(exitDealType == DEAL_TYPE_BUY)  return "SELL";
   if(exitDealType == DEAL_TYPE_SELL) return "BUY";
   return "BUY";
}

void UpdateProfitBankFromHistory()
{
   if(!EnableProfitBank) return;

   datetime dayStart = iTime(_Symbol, PERIOD_D1, 0);
   datetime fromTime = dayStart;
   if(g_bankResetTime > fromTime) fromTime = g_bankResetTime;
   if(!HistorySelect(fromTime, TimeCurrent())) return;

   g_bankTotal = 0.0;
   g_bankBuy = 0.0;
   g_bankSell = 0.0;
   g_bankHedge = 0.0;

   int deals = HistoryDealsTotal();
   for(int i = 0; i < deals; i++)
   {
      ulong d = HistoryDealGetTicket(i);
      if(d == 0) continue;
      if(HistoryDealGetString(d, DEAL_SYMBOL) != _Symbol) continue;
      if((ulong)HistoryDealGetInteger(d, DEAL_MAGIC) != MagicNumber) continue;
      long entry = HistoryDealGetInteger(d, DEAL_ENTRY);
      if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_INOUT) continue;

      double p = HistoryDealGetDouble(d, DEAL_PROFIT) + HistoryDealGetDouble(d, DEAL_SWAP) + HistoryDealGetDouble(d, DEAL_COMMISSION);
      long dealType = HistoryDealGetInteger(d, DEAL_TYPE);
      ulong posId = (ulong)HistoryDealGetInteger(d, DEAL_POSITION_ID);
      string module = DealModuleFromPosition(posId, dealType);
      g_bankTotal += p;
      if(module == "HEDGE") g_bankHedge += p;
      else if(module == "SELL") g_bankSell += p;
      else g_bankBuy += p;
   }
}

//---------------------- STACK ZONES --------------------------------
void AddZone(double price, double lot, double pl, double zoneSize,
             double &lows[], double &highs[], int &counts[], double &lots[], double &pls[], int &n)
{
   if(zoneSize <= 0.0) return;
   double low = MathFloor(price / zoneSize) * zoneSize;
   double high = low + zoneSize;
   for(int i = 0; i < n; i++)
   {
      if(MathAbs(lows[i] - low) < 0.0001)
      {
         counts[i]++;
         lots[i] += lot;
         pls[i] += pl;
         return;
      }
   }
   int maxN = ArraySize(lows);
   if(n >= maxN) return;
   lows[n] = low;
   highs[n] = high;
   counts[n] = 1;
   lots[n] = lot;
   pls[n] = pl;
   n++;
}

string TopZonesText(bool buySide)
{
   double lows[20], highs[20], lots[20], pls[20];
   int counts[20];
   ArrayInitialize(lows, 0.0); ArrayInitialize(highs, 0.0); ArrayInitialize(lots, 0.0); ArrayInitialize(pls, 0.0); ArrayInitialize(counts, 0);
   int n = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
      if(!IsOurPosition()) continue;
      long type = PositionGetInteger(POSITION_TYPE);
      string c = PositionGetString(POSITION_COMMENT);
      if(IsHedgeComment(c)) continue;
      if(buySide && type != POSITION_TYPE_BUY) continue;
      if(!buySide && type != POSITION_TYPE_SELL) continue;
      double price = PositionGetDouble(POSITION_PRICE_OPEN);
      double lot = PositionGetDouble(POSITION_VOLUME);
      double pl = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      AddZone(price, lot, pl, StackZoneUSD, lows, highs, counts, lots, pls, n);
   }

   if(n <= 0) return "none";

   for(int a = 0; a < n - 1; a++)
   {
      for(int b = a + 1; b < n; b++)
      {
         if(counts[b] > counts[a])
         {
            int tc = counts[a]; counts[a] = counts[b]; counts[b] = tc;
            double td = lows[a]; lows[a] = lows[b]; lows[b] = td;
            td = highs[a]; highs[a] = highs[b]; highs[b] = td;
            td = lots[a]; lots[a] = lots[b]; lots[b] = td;
            td = pls[a]; pls[a] = pls[b]; pls[b] = td;
         }
      }
   }
   string txt = "";
   int limit = MathMin(n, 3);
   for(int i = 0; i < limit; i++)
   {
      if(i > 0) txt += " | ";
      txt += DoubleToString(lows[i], 0) + "-" + DoubleToString(highs[i], 0) + ":" + IntegerToString(counts[i]);
   }
   return txt;
}

void BuildZones(bool buySide, double zoneSize,
                double &lows[], double &highs[], int &counts[], double &lots[], double &pls[], int &n)
{
   ArrayInitialize(lows, 0.0); ArrayInitialize(highs, 0.0); ArrayInitialize(lots, 0.0); ArrayInitialize(pls, 0.0); ArrayInitialize(counts, 0);
   n = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
      if(!IsOurPosition()) continue;
      long type = PositionGetInteger(POSITION_TYPE);
      string c = PositionGetString(POSITION_COMMENT);
      if(IsHedgeComment(c)) continue;
      if(buySide && type != POSITION_TYPE_BUY) continue;
      if(!buySide && type != POSITION_TYPE_SELL) continue;
      AddZone(PositionGetDouble(POSITION_PRICE_OPEN), PositionGetDouble(POSITION_VOLUME),
              PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP), zoneSize,
              lows, highs, counts, lots, pls, n);
   }

   for(int a = 0; a < n - 1; a++)
   {
      for(int b = a + 1; b < n; b++)
      {
         if(counts[b] > counts[a])
         {
            int tc = counts[a]; counts[a] = counts[b]; counts[b] = tc;
            double td = lows[a]; lows[a] = lows[b]; lows[b] = td;
            td = highs[a]; highs[a] = highs[b]; highs[b] = td;
            td = lots[a]; lots[a] = lots[b]; lots[b] = td;
            td = pls[a]; pls[a] = pls[b]; pls[b] = td;
         }
      }
   }
}

void DrawStackLines(string prefix, string title, bool buySide, double zoneSize, int maxAllowed, int x, int &y, color clr)
{
   double lows[30], highs[30], lots[30], pls[30];
   int counts[30];
   int n = 0;
   BuildZones(buySide, zoneSize, lows, highs, counts, lots, pls, n);
   Label(prefix + "_H", title + " zone=" + DoubleToString(zoneSize,1), x, y, clr, 9); y += 14;
   if(n <= 0)
   {
      Label(prefix + "_0", "  none", x, y, clrSilver, 9); y += 14;
      return;
   }
   int limit = MathMin(n, 5);
   for(int i = 0; i < limit; i++)
   {
      string warn = "";
      if(maxAllowed > 0 && counts[i] > maxAllowed) warn = " <<< STACKED";
      string line = "  " + DoubleToString(lows[i],0) + "-" + DoubleToString(highs[i],0)
                  + " | " + IntegerToString(counts[i]) + " orders | "
                  + DoubleToString(lots[i],2) + " lot | " + DoubleToString(pls[i],2) + warn;
      Label(prefix + "_" + IntegerToString(i+1), line, x, y, clr, 9); y += 14;
   }
}

//---------------------- DASHBOARD ----------------------------------
void Label(string name, string text, int x, int y, color clr = clrWhite, int size = 9)
{
   string obj = DASH_PREFIX + name;
   if(ObjectFind(0, obj) < 0)
   {
      ObjectCreate(0, obj, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, obj, OBJPROP_CORNER, DashboardCorner);
      ObjectSetInteger(0, obj, OBJPROP_XDISTANCE, x);
      ObjectSetInteger(0, obj, OBJPROP_YDISTANCE, y);
      ObjectSetInteger(0, obj, OBJPROP_FONTSIZE, size);
      ObjectSetString(0, obj, OBJPROP_FONT, "Consolas");
   }
   ObjectSetString(0, obj, OBJPROP_TEXT, text);
   ObjectSetInteger(0, obj, OBJPROP_COLOR, clr);
}

void Button(string name, string text, int x, int y, int w, int h)
{
   if(ObjectFind(0, name) < 0)
   {
      ObjectCreate(0, name, OBJ_BUTTON, 0, 0, 0);
      ObjectSetInteger(0, name, OBJPROP_CORNER, DashboardCorner);
      ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
      ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
      ObjectSetInteger(0, name, OBJPROP_XSIZE, w);
      ObjectSetInteger(0, name, OBJPROP_YSIZE, h);
      ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 8);
   }
   ObjectSetString(0, name, OBJPROP_TEXT, text);
}

void ClearDashboard()
{
   int total = ObjectsTotal(0, 0, -1);
   for(int i = total - 1; i >= 0; i--)
   {
      string name = ObjectName(0, i, 0, -1);
      if(StringFind(name, DASH_PREFIX) == 0 || StringFind(name, "PX_BTN_") == 0) ObjectDelete(0, name);
   }
}

void DrawDashboard()
{
   if(!ShowDashboard) return;

   ModuleStats buy, sell, hedge;
   int negSell;
   GetModuleStats(buy, sell, hedge, negSell);

   double hi = 0.0, lo = 0.0;
   Get24HRange(hi, lo);
   double range = hi - lo;
   double bottomLimit = lo + range * BottomBlockPercent24H / 100.0;
   double topLimit = hi - range * TopBlockPercent24H / 100.0;
   string sellAllowed = SellConfirmationOK() ? "YES" : "NO";
   string lock = EntriesLocked() ? "LOCKED" : "ACTIVE";
   double usableBank = g_bankTotal * ProfitBankUsePercent / 100.0;
   double totalPL = buy.pl + sell.pl + hedge.pl;

   int y = DashboardY;
   int x = DashboardX;
   Label("01", "PHOENIX EA v1.13 PATCH | " + _Symbol + " | " + lock, x, y, clrAqua, 10); y += 16;
   Label("02", "Modules: Buy=" + (EnableBuyGrid ? "ON" : "OFF") + " Sell=" + (EnableAutoSellModule ? "ON" : "OFF") + " Hedge=" + (EnableHedgeEngine ? "ON" : "OFF") + " Trail=" + (EnableTrailing ? "ON" : "OFF"), x, y, clrWhite); y += 14;
   Label("02A", "Hedge: MinDD=" + DoubleToString(MinDDForHedge_USD,1) + " Cooldown=" + IntegerToString(HedgeCooldownSeconds) + " TrendFilter=" + (UseTrendFilterForHedge ? "ON" : "OFF") + " Target=" + DoubleToString(HedgeTargetPercent,0) + "%", x, y, clrDeepSkyBlue); y += 14;
   Label("02B", "Zones: BuyDash=" + DoubleToString(BuyStackZoneUSD,1) + " SellDash=" + DoubleToString(SellStackZoneUSD,1) + " SellEntry=" + DoubleToString(SellZoneSizeUSD,1) + " max=" + IntegerToString(MaxSellOrdersPerZone), x, y, clrSilver); y += 14;
   Label("03", "TOTAL: lots=" + DoubleToString(buy.lots + sell.lots + hedge.lots,2) + " | BUY=" + DoubleToString(buy.lots,2) + " SELL=" + DoubleToString(sell.lots,2) + " HEDGE=" + DoubleToString(hedge.lots,2), x, y, clrWhite); y += 14;
   Label("03B", "FLOAT: total=" + DoubleToString(totalPL,2) + " BUY=" + DoubleToString(buy.pl,2) + " SELL=" + DoubleToString(sell.pl,2) + " HEDGE=" + DoubleToString(hedge.pl,2) + " DD=" + DoubleToString(CurrentFloatingDD(),2), x, y, clrWhite); y += 14;

   Label("04", "BUY_GRID : orders=" + IntegerToString(buy.orders) + " lots=" + DoubleToString(buy.lots,2) + " PL=" + DoubleToString(buy.pl,2) + " avg=" + DoubleToString(buy.avg,_Digits), x, y, clrLime); y += 14;
   Label("05", "BUY Lvls : low=" + DoubleToString(buy.lowest,_Digits) + " high=" + DoubleToString(buy.highest,_Digits) + " nextSpace=" + DoubleToString(DynamicSpacingByBuyCount(buy.orders),1), x, y, clrLime); y += 14;
   Label("06", "SELL    : orders=" + IntegerToString(sell.orders) + " lots=" + DoubleToString(sell.lots,2) + " PL=" + DoubleToString(sell.pl,2) + " avg=" + DoubleToString(sell.avg,_Digits) + " neg=" + IntegerToString(negSell), x, y, clrTomato); y += 14;
   Label("07", "HEDGE   : orders=" + IntegerToString(hedge.orders) + " lots=" + DoubleToString(hedge.lots,2) + " PL=" + DoubleToString(hedge.pl,2) + " avg=" + DoubleToString(hedge.avg,_Digits), x, y, clrDeepSkyBlue); y += 14;
   double nbDash, nsDash, hbDash, hsDash;
   GetExposureLots(nbDash, nsDash, hbDash, hsDash);
   Label("07B", "HedgeCtrl: NormalBUY=" + DoubleToString(nbDash,2) + " NormalSELL=" + DoubleToString(nsDash,2) + " HedgeBUY=" + DoubleToString(hbDash,2) + " HedgeSELL=" + DoubleToString(hsDash,2), x, y, clrDeepSkyBlue); y += 14;

   Label("08", "24H: high=" + DoubleToString(hi,_Digits) + " low=" + DoubleToString(lo,_Digits) + " | NoSellBelow=" + DoubleToString(bottomLimit,_Digits), x, y, clrGold); y += 14;
   Label("09", "NoBuyAbove=" + DoubleToString(topLimit,_Digits) + " | M15=" + TrendTextM15() + " | SellAllowed=" + sellAllowed, x, y, clrGold); y += 14;
   Label("10", "ProfitBank: total=" + DoubleToString(g_bankTotal,2) + " usable=" + DoubleToString(usableBank,2) + " (" + DoubleToString(ProfitBankUsePercent,0) + "%)", x, y, clrDeepSkyBlue); y += 14;
   Label("11", "Bank Split: BUY=" + DoubleToString(g_bankBuy,2) + " SELL=" + DoubleToString(g_bankSell,2) + " HEDGE=" + DoubleToString(g_bankHedge,2), x, y, clrDeepSkyBlue); y += 14;
   DrawStackLines("12", "BUY STACK", true, BuyStackZoneUSD, 0, x, y, clrPaleGreen);
   DrawStackLines("13", "SELL STACK", false, SellStackZoneUSD, MaxSellOrdersPerZone, x, y, clrLightSalmon);
   Label("14", "Safety: SoftLockDD=" + DoubleToString(SoftLockDD_USD,0) + " HardLockDD=" + DoubleToString(HardLockDD_USD,0) + " MaxLots=" + DoubleToString(MaxTotalLots,2), x, y, clrSilver); y += 14;
   Label("15", "Trail BUY start=" + DoubleToString(BuyTrailStart_USD,1) + " lock=" + DoubleToString(BuyTrailLock_USD,1) + " gap=" + DoubleToString(BuyTrailGap_USD,1) + " | TP backup=" + (UseBrokerTP ? "ON" : "OFF") + " | TP forward=" + (ForwardTPWithTrail ? "ON" : "OFF"), x, y, clrLightSkyBlue); y += 14;
   Button(BTN_RESET_BANK, "RESET BANK", x, y + 4, 95, 18);
}

//---------------------- EVENTS -------------------------------------
int OnInit()
{
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(SlippagePoints);
   string gv = "PX_BANK_RESET_" + _Symbol + "_" + IntegerToString((int)MagicNumber);
   if(GlobalVariableCheck(gv)) g_bankResetTime = (datetime)GlobalVariableGet(gv);
   else g_bankResetTime = 0;
   Print(EA_Name, " initialized on ", _Symbol);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   ClearDashboard();
}

void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
{
   if(id == CHARTEVENT_OBJECT_CLICK && sparam == BTN_RESET_BANK)
   {
      g_bankResetTime = TimeCurrent();
      string gv = "PX_BANK_RESET_" + _Symbol + "_" + IntegerToString((int)MagicNumber);
      GlobalVariableSet(gv, (double)g_bankResetTime);
      g_bankTotal = 0.0; g_bankBuy = 0.0; g_bankSell = 0.0; g_bankHedge = 0.0;
      ObjectSetInteger(0, BTN_RESET_BANK, OBJPROP_STATE, false);
      Print("Phoenix profit bank reset at ", TimeToString(g_bankResetTime));
   }
}

void OnTick()
{
   UpdateProfitBankFromHistory();
   ManageTrailingStops();
   ManageBuyGrid();
   ManageSellModule();
   ManageHedgeEngine();
   DrawDashboard();
}
//+------------------------------------------------------------------+
