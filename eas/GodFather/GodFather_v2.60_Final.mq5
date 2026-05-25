//+------------------------------------------------------------------+
//|                                                GodFather_V3.mq5  |
//|  GodFather v3.00 - Split Grid + Controlled Timed Booster         |
//|  Normal grid independent | Timed entries controlled separately   |
//+------------------------------------------------------------------+
#property strict
#property version   "3.00"
#property copyright "GodFather"

#include <Trade/Trade.mqh>
CTrade trade;

//---------------- START MODE ----------------//
enum ENUM_GF_START_MODE
{
   MANUAL_ONLY = 0,
   AUTO_ONLY   = 1,
   BOTH        = 2
};

//---------------- MAIN INPUTS ----------------//
input ENUM_GF_START_MODE StartMode      = BOTH;
input int    MagicNumber                = 20260422;
input int    SlippagePoints             = 20;
input bool   EnableGlobalDDPause        = false;
input double GlobalDDPause              = -1000;

//---------------- NORMAL GRID ENGINE ----------------//
input bool   EnableGridEngine           = true;
input double GridLotSize                = 0.01;
input int    MaxGridOrdersBuy           = 20;
input int    MaxGridOrdersSell          = 20;
input double GridSpacing_1_5            = 5.0;
input double GridSpacing_6_10           = 7.0;
input double GridSpacing_11Plus         = 10.0;
input double GridTP_USD                 = 10.0;     // broker-level TP for every grid/base EA order
input bool   EnableExactGridRefill      = true;
input double GridLevelToleranceUSD      = 0.75;
input double DuplicateRangeBlockUSD     = 0.75;     // avoids duplicate/stuck same-range orders

// Grid individual trailing
input bool   EnableGridTrailing         = true;
input double GridTrailStart_USD         = 2.0;
input double GridTrailLock_USD          = 1.0;
input double GridTrailGap_USD           = 2.0;
input bool   RemoveTPWhenTrailStarts    = true;

// Grid basket - separate from timed entries
input bool   EnableGridBasketTP         = true;
input double GridBasketTP_USD           = 40.0;
input bool   EnableGridBasketTrailing   = true;
input double GridBasketTrailStart_USD   = 40.0;
input double GridBasketTrailGap_USD     = 10.0;

//---------------- TIMED BOOSTER ENGINE ----------------//
input bool   EnableTimedEntries         = true;
input double TimedLotSize               = 0.02;
input int    TimedAddIntervalSec        = 10;       // every 10 sec
input int    MaxTimedOrdersBuy          = 10;
input int    MaxTimedOrdersSell         = 10;
input int    MaxNegativeTimedOrders     = 3;        // only timed negative cap
input double TimedStartMove_USD         = 0.0;      // 0 = start as soon as base side is positive
input double TimedMinSpacingUSD         = 1.0;
input double TimedTP_USD                = 3.0;
input bool   TimedUseInitialSL          = false;
input double TimedSL_USD                = 8.0;
input bool   EnableTimedTrailing        = true;
input double TimedTrailStart_USD        = 2.0;
input double TimedTrailLock_USD         = 1.0;
input double TimedTrailGap_USD          = 1.0;

//---------------- AUTO / MANUAL BASE ----------------//
input bool   AutoStartBuy               = true;
input bool   AutoStartSell              = true;
input bool   DetectManualBuy            = true;
input bool   DetectManualSell           = true;
input bool   StopNewOrdersWhenBaseClosed= true;     // manage-only after base closes

//---------------- OPTIONAL RECOVERY BOOST ----------------//
input bool   EnableRecoveryBoost        = false;    // disabled by default in v3 to keep grid/timed clean
input int    MinGridEntriesForRecovery  = 3;
input double RecoveryZoneUSD            = 1.5;
input double RecoveryLotSize            = 0.01;
input double RecoveryTP_USD             = 10.0;
input double RecoverySL_USD             = 8.0;
input bool   EnableRecoveryTrailing     = false;
input double RecoveryTrailGap_USD       = 2.0;

//---------------- COMMENTS ----------------//
string CMT_BUY_BASE    = "GF_AUTO_BUY_BASE";
string CMT_SELL_BASE   = "GF_AUTO_SELL_BASE";
string CMT_BUY_GRID    = "GF_GRID_BUY";
string CMT_SELL_GRID   = "GF_GRID_SELL";
string CMT_BUY_TIMED   = "GF_TIMED_BUY";
string CMT_SELL_TIMED  = "GF_TIMED_SELL";
string CMT_BUY_RECOV   = "GF_RECOVERY_BUY";
string CMT_SELL_RECOV  = "GF_RECOVERY_SELL";

//---------------- GLOBALS ----------------//
string   g_symbol = "";

bool     g_buyCycleActive      = false;
bool     g_buyManageOnly       = false;
ulong    g_buyBaseTicket       = 0;
double   g_buyBaseEntry        = 0.0;
datetime g_lastBuyTimedAdd     = 0;
double   g_buyGridBasketPeak   = 0.0;
bool     g_buyRecoveryUsed     = false;

bool     g_sellCycleActive     = false;
bool     g_sellManageOnly      = false;
ulong    g_sellBaseTicket      = 0;
double   g_sellBaseEntry       = 0.0;
datetime g_lastSellTimedAdd    = 0;
double   g_sellGridBasketPeak  = 0.0;
bool     g_sellRecoveryUsed    = false;

//---------------- BASIC HELPERS ----------------//
double AskPrice(){ return SymbolInfoDouble(g_symbol, SYMBOL_ASK); }
double BidPrice(){ return SymbolInfoDouble(g_symbol, SYMBOL_BID); }

double NormPrice(double p)
{
   int digits = (int)SymbolInfoInteger(g_symbol, SYMBOL_DIGITS);
   return NormalizeDouble(p, digits);
}

bool SelectPos(ulong ticket)
{
   if(ticket == 0) return false;
   return PositionSelectByTicket(ticket);
}

bool ManualAllowed(){ return (StartMode == MANUAL_ONLY || StartMode == BOTH); }
bool AutoAllowed(){ return (StartMode == AUTO_ONLY || StartMode == BOTH); }

bool CanAddAnyNewOrders()
{
   if(!EnableGlobalDDPause) return true;
   return (GetAllEAProfit() > GlobalDDPause);
}

double GetGridLevelDistance(int level)
{
   double d = 0.0;
   for(int i = 1; i <= level; i++)
   {
      if(i <= 5)       d += GridSpacing_1_5;
      else if(i <= 10) d += GridSpacing_6_10;
      else             d += GridSpacing_11Plus;
   }
   return d;
}

string GridLevelComment(ENUM_POSITION_TYPE side, int level)
{
   if(side == POSITION_TYPE_BUY)
      return CMT_BUY_GRID + "_L" + IntegerToString(level);
   return CMT_SELL_GRID + "_L" + IntegerToString(level);
}

bool IsTimedComment(const string c)
{
   return (StringFind(c, CMT_BUY_TIMED) == 0 || StringFind(c, CMT_SELL_TIMED) == 0);
}

bool IsGridComment(const string c)
{
   return (StringFind(c, CMT_BUY_GRID) == 0 || StringFind(c, CMT_SELL_GRID) == 0);
}

bool IsBaseComment(const string c)
{
   return (c == CMT_BUY_BASE || c == CMT_SELL_BASE);
}

bool IsGridFamilyComment(const string c)
{
   return (IsGridComment(c) || IsBaseComment(c));
}

bool IsRecoveryComment(const string c)
{
   return (StringFind(c, CMT_BUY_RECOV) == 0 || StringFind(c, CMT_SELL_RECOV) == 0);
}

//---------------- POSITION CLASSIFICATION ----------------//
bool IsManualBaseTicket(ENUM_POSITION_TYPE side, ulong ticket)
{
   if(side == POSITION_TYPE_BUY) return (ticket == g_buyBaseTicket);
   return (ticket == g_sellBaseTicket);
}

bool IsCyclePosition(ENUM_POSITION_TYPE side, ulong ticket)
{
   if(!SelectPos(ticket)) return false;
   if(PositionGetString(POSITION_SYMBOL) != g_symbol) return false;
   if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != side) return false;

   long mg = (long)PositionGetInteger(POSITION_MAGIC);
   if(mg == MagicNumber) return true;
   if(mg == 0 && IsManualBaseTicket(side, ticket)) return true;
   return false;
}

bool IsEAOnlyCyclePosition(ENUM_POSITION_TYPE side, ulong ticket)
{
   if(!SelectPos(ticket)) return false;
   if(PositionGetString(POSITION_SYMBOL) != g_symbol) return false;
   if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != side) return false;
   return ((long)PositionGetInteger(POSITION_MAGIC) == MagicNumber);
}

int CountEAOnlyPositions(ENUM_POSITION_TYPE side)
{
   int count = 0;
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && IsEAOnlyCyclePosition(side, ticket)) count++;
   }
   return count;
}

int CountByFamily(ENUM_POSITION_TYPE side, int family) // 0 grid, 1 timed, 2 recovery
{
   int count = 0;
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !IsEAOnlyCyclePosition(side, ticket)) continue;
      string cmt = PositionGetString(POSITION_COMMENT);
      if(family == 0 && IsGridFamilyComment(cmt)) count++;
      if(family == 1 && IsTimedComment(cmt)) count++;
      if(family == 2 && IsRecoveryComment(cmt)) count++;
   }
   return count;
}

int CountGridEntriesOnly(ENUM_POSITION_TYPE side)
{
   int count = 0;
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !IsEAOnlyCyclePosition(side, ticket)) continue;
      if(IsGridComment(PositionGetString(POSITION_COMMENT))) count++;
   }
   return count;
}

int CountNegativeTimedPositions(ENUM_POSITION_TYPE side)
{
   int count = 0;
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !IsEAOnlyCyclePosition(side, ticket)) continue;
      if(!IsTimedComment(PositionGetString(POSITION_COMMENT))) continue;
      if(PositionGetDouble(POSITION_PROFIT) < 0.0) count++;
   }
   return count;
}

double GetEAOnlyFloatingProfit(ENUM_POSITION_TYPE side)
{
   double p = 0.0;
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !IsEAOnlyCyclePosition(side, ticket)) continue;
      p += PositionGetDouble(POSITION_PROFIT);
   }
   return p;
}

double GetFamilyFloatingProfit(ENUM_POSITION_TYPE side, int family)
{
   double p = 0.0;
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !IsEAOnlyCyclePosition(side, ticket)) continue;
      string cmt = PositionGetString(POSITION_COMMENT);
      if(family == 0 && !IsGridFamilyComment(cmt)) continue;
      if(family == 1 && !IsTimedComment(cmt)) continue;
      if(family == 2 && !IsRecoveryComment(cmt)) continue;
      p += PositionGetDouble(POSITION_PROFIT);
   }
   return p;
}

double GetAllEAProfit()
{
   double p = 0.0;
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) == g_symbol && (long)PositionGetInteger(POSITION_MAGIC) == MagicNumber)
         p += PositionGetDouble(POSITION_PROFIT);
   }
   return p;
}

double GetLotSum(ENUM_POSITION_TYPE side)
{
   double lots = 0.0;
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !IsEAOnlyCyclePosition(side, ticket)) continue;
      lots += PositionGetDouble(POSITION_VOLUME);
   }
   return lots;
}

double GetHighestEAOpenPrice(ENUM_POSITION_TYPE side)
{
   double highest = 0.0;
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !IsEAOnlyCyclePosition(side, ticket)) continue;
      double pr = PositionGetDouble(POSITION_PRICE_OPEN);
      if(highest == 0.0 || pr > highest) highest = pr;
   }
   return highest;
}

double GetLowestEAOpenPrice(ENUM_POSITION_TYPE side)
{
   double lowest = 0.0;
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !IsEAOnlyCyclePosition(side, ticket)) continue;
      double pr = PositionGetDouble(POSITION_PRICE_OPEN);
      if(lowest == 0.0 || pr < lowest) lowest = pr;
   }
   return lowest;
}

double GetLatestTimedEntryPrice(ENUM_POSITION_TYPE side)
{
   double latestPrice = 0.0;
   datetime latestTime = 0;
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !IsEAOnlyCyclePosition(side, ticket)) continue;
      if(!IsTimedComment(PositionGetString(POSITION_COMMENT))) continue;
      datetime t = (datetime)PositionGetInteger(POSITION_TIME);
      if(latestPrice == 0.0 || t > latestTime)
      {
         latestTime = t;
         latestPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      }
   }
   return latestPrice;
}

bool HasSameRangeOrder(ENUM_POSITION_TYPE side, double price, double tolerance, int family)
{
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !IsEAOnlyCyclePosition(side, ticket)) continue;
      string cmt = PositionGetString(POSITION_COMMENT);
      if(family == 0 && !IsGridFamilyComment(cmt) && !IsGridComment(cmt)) continue;
      if(family == 1 && !IsTimedComment(cmt)) continue;
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      if(MathAbs(openPrice - price) <= tolerance) return true;
   }
   return false;
}

//---------------- BASE DETECTION / RESET ----------------//
bool GetLatestManualBase(ENUM_POSITION_TYPE side, ulong &ticketOut, double &entryOut)
{
   ticketOut = 0; entryOut = 0.0;
   bool found = false;
   datetime latest = 0;

   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != g_symbol) continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != 0) continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != side) continue;

      datetime t = (datetime)PositionGetInteger(POSITION_TIME);
      if(!found || t > latest)
      {
         found = true;
         latest = t;
         ticketOut = ticket;
         entryOut = PositionGetDouble(POSITION_PRICE_OPEN);
      }
   }
   return found;
}

bool GetLatestEAByComment(ENUM_POSITION_TYPE side, const string commentText, ulong &ticketOut, double &entryOut)
{
   ticketOut = 0; entryOut = 0.0;
   bool found = false;
   datetime latest = 0;

   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != g_symbol) continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != side) continue;
      if(PositionGetString(POSITION_COMMENT) != commentText) continue;

      datetime t = (datetime)PositionGetInteger(POSITION_TIME);
      if(!found || t > latest)
      {
         found = true;
         latest = t;
         ticketOut = ticket;
         entryOut = PositionGetDouble(POSITION_PRICE_OPEN);
      }
   }
   return found;
}

void ResetBuySide()
{
   g_buyCycleActive = false; g_buyManageOnly = false; g_buyBaseTicket = 0; g_buyBaseEntry = 0.0;
   g_lastBuyTimedAdd = 0; g_buyGridBasketPeak = 0.0; g_buyRecoveryUsed = false;
}

void ResetSellSide()
{
   g_sellCycleActive = false; g_sellManageOnly = false; g_sellBaseTicket = 0; g_sellBaseEntry = 0.0;
   g_lastSellTimedAdd = 0; g_sellGridBasketPeak = 0.0; g_sellRecoveryUsed = false;
}

void ActivateSide(ENUM_POSITION_TYPE side, ulong ticket, double entry, bool manual)
{
   if(side == POSITION_TYPE_BUY)
   {
      g_buyCycleActive = true; g_buyManageOnly = false; g_buyBaseTicket = ticket; g_buyBaseEntry = entry;
      g_lastBuyTimedAdd = 0; g_buyGridBasketPeak = 0.0; g_buyRecoveryUsed = false;
      Print("GodFather V3: BUY base activated. Manual=", manual, " Entry=", entry);
   }
   else
   {
      g_sellCycleActive = true; g_sellManageOnly = false; g_sellBaseTicket = ticket; g_sellBaseEntry = entry;
      g_lastSellTimedAdd = 0; g_sellGridBasketPeak = 0.0; g_sellRecoveryUsed = false;
      Print("GodFather V3: SELL base activated. Manual=", manual, " Entry=", entry);
   }
}

//---------------- ORDER PLACEMENT ----------------//
double CalcTP(ENUM_POSITION_TYPE side, const string commentText, double entryPrice)
{
   double move = 0.0;
   if(IsTimedComment(commentText)) move = TimedTP_USD;
   else if(IsRecoveryComment(commentText)) move = RecoveryTP_USD;
   else move = GridTP_USD;

   if(move <= 0.0) return 0.0;
   if(side == POSITION_TYPE_BUY) return NormPrice(entryPrice + move);
   return NormPrice(entryPrice - move);
}

double CalcInitialSL(ENUM_POSITION_TYPE side, const string commentText, double entryPrice)
{
   if(IsTimedComment(commentText))
   {
      if(!TimedUseInitialSL || TimedSL_USD <= 0.0) return 0.0;
      if(side == POSITION_TYPE_BUY) return NormPrice(entryPrice - TimedSL_USD);
      return NormPrice(entryPrice + TimedSL_USD);
   }
   if(IsRecoveryComment(commentText))
   {
      if(RecoverySL_USD <= 0.0) return 0.0;
      if(side == POSITION_TYPE_BUY) return NormPrice(entryPrice - RecoverySL_USD);
      return NormPrice(entryPrice + RecoverySL_USD);
   }
   return 0.0;
}

bool PlaceBuy(const string commentText, double lots)
{
   double entry = AskPrice();
   double sl = CalcInitialSL(POSITION_TYPE_BUY, commentText, entry);
   double tp = CalcTP(POSITION_TYPE_BUY, commentText, entry);

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(SlippagePoints);
   bool ok = trade.Buy(lots, g_symbol, 0.0, sl, tp, commentText);
   if(!ok)
      Print("BUY failed: ", commentText, " retcode=", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription(), " error=", GetLastError());
   return ok;
}

bool PlaceSell(const string commentText, double lots)
{
   double entry = BidPrice();
   double sl = CalcInitialSL(POSITION_TYPE_SELL, commentText, entry);
   double tp = CalcTP(POSITION_TYPE_SELL, commentText, entry);

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(SlippagePoints);
   bool ok = trade.Sell(lots, g_symbol, 0.0, sl, tp, commentText);
   if(!ok)
      Print("SELL failed: ", commentText, " retcode=", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription(), " error=", GetLastError());
   return ok;
}

//---------------- BASE START ----------------//
void DetectManualBaseOrders()
{
   if(!ManualAllowed()) return;
   ulong tk = 0; double pr = 0.0;

   if(DetectManualBuy && !g_buyCycleActive)
      if(GetLatestManualBase(POSITION_TYPE_BUY, tk, pr)) ActivateSide(POSITION_TYPE_BUY, tk, pr, true);

   if(DetectManualSell && !g_sellCycleActive)
      if(GetLatestManualBase(POSITION_TYPE_SELL, tk, pr)) ActivateSide(POSITION_TYPE_SELL, tk, pr, true);
}

void CheckAutoStart()
{
   if(!AutoAllowed() || !CanAddAnyNewOrders()) return;
   ulong tk = 0; double pr = 0.0;

   if(AutoStartBuy && !g_buyCycleActive)
   {
      if(PlaceBuy(CMT_BUY_BASE, GridLotSize))
         if(GetLatestEAByComment(POSITION_TYPE_BUY, CMT_BUY_BASE, tk, pr)) ActivateSide(POSITION_TYPE_BUY, tk, pr, false);
   }

   if(AutoStartSell && !g_sellCycleActive)
   {
      if(PlaceSell(CMT_SELL_BASE, GridLotSize))
         if(GetLatestEAByComment(POSITION_TYPE_SELL, CMT_SELL_BASE, tk, pr)) ActivateSide(POSITION_TYPE_SELL, tk, pr, false);
   }
}

void UpdateBaseAliveState()
{
   if(g_buyCycleActive && !g_buyManageOnly && StopNewOrdersWhenBaseClosed && !SelectPos(g_buyBaseTicket))
   {
      g_buyManageOnly = true;
      Print("GodFather V3: BUY base closed. BUY side manage-only.");
   }

   if(g_sellCycleActive && !g_sellManageOnly && StopNewOrdersWhenBaseClosed && !SelectPos(g_sellBaseTicket))
   {
      g_sellManageOnly = true;
      Print("GodFather V3: SELL base closed. SELL side manage-only.");
   }
}

void ValidateResetConditions()
{
   if(g_buyCycleActive && CountEAOnlyPositions(POSITION_TYPE_BUY) == 0 && !SelectPos(g_buyBaseTicket)) ResetBuySide();
   if(g_sellCycleActive && CountEAOnlyPositions(POSITION_TYPE_SELL) == 0 && !SelectPos(g_sellBaseTicket)) ResetSellSide();
}

//---------------- BROKER TP BACKUP / PROTECTIONS ----------------//
void ApplyBrokerTPBackup()
{
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != g_symbol) continue;
      long mg = (long)PositionGetInteger(POSITION_MAGIC);
      if(mg != MagicNumber) continue;

      ENUM_POSITION_TYPE side = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double entry = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl = PositionGetDouble(POSITION_SL);
      double tp = PositionGetDouble(POSITION_TP);
      string cmt = PositionGetString(POSITION_COMMENT);

      // If trailing already locked SL, keep TP removed.
      if(RemoveTPWhenTrailStarts && sl != 0.0)
      {
         if(IsTimedComment(cmt) || IsGridComment(cmt) || IsRecoveryComment(cmt))
         {
            double positiveSL = 0.0;
            if(side == POSITION_TYPE_BUY && sl > entry) positiveSL = sl;
            if(side == POSITION_TYPE_SELL && sl < entry) positiveSL = sl;
            if(positiveSL != 0.0 && tp != 0.0)
               trade.PositionModify(ticket, sl, 0.0);
            continue;
         }
      }

      double wantTP = CalcTP(side, cmt, entry);
      double wantSL = sl;

      if(IsTimedComment(cmt) && TimedUseInitialSL && sl == 0.0)
         wantSL = CalcInitialSL(side, cmt, entry);
      if(IsRecoveryComment(cmt) && sl == 0.0)
         wantSL = CalcInitialSL(side, cmt, entry);

      bool need = false;
      if(wantTP > 0.0 && (tp == 0.0 || MathAbs(tp - wantTP) > (_Point * 2))) need = true;
      if(wantSL != sl) need = true;

      if(need) trade.PositionModify(ticket, wantSL, wantTP);
   }
}

//---------------- TRAILING ----------------//
void ManageTrailing()
{
   double bid = BidPrice();
   double ask = AskPrice();

   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != g_symbol) continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;

      ENUM_POSITION_TYPE side = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double entry = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl = PositionGetDouble(POSITION_SL);
      double tp = PositionGetDouble(POSITION_TP);
      string cmt = PositionGetString(POSITION_COMMENT);

      bool doTrail = false;
      double start = 0.0, lock = 0.0, gap = 0.0;

      if(IsTimedComment(cmt) && EnableTimedTrailing)
      {
         doTrail = true; start = TimedTrailStart_USD; lock = TimedTrailLock_USD; gap = TimedTrailGap_USD;
      }
      else if(IsGridComment(cmt) && EnableGridTrailing)
      {
         doTrail = true; start = GridTrailStart_USD; lock = GridTrailLock_USD; gap = GridTrailGap_USD;
      }
      else if(IsRecoveryComment(cmt) && EnableRecoveryTrailing)
      {
         doTrail = true; start = GridTrailStart_USD; lock = GridTrailLock_USD; gap = RecoveryTrailGap_USD;
      }

      if(!doTrail) continue;

      if(side == POSITION_TYPE_BUY && bid >= entry + start)
      {
         double lockSL = NormPrice(entry + lock);
         double trailSL = NormPrice(bid - gap);
         double wantedSL = MathMax(lockSL, trailSL);
         double wantedTP = RemoveTPWhenTrailStarts ? 0.0 : tp;
         if(sl == 0.0 || wantedSL > sl + (_Point * 2) || (RemoveTPWhenTrailStarts && tp != 0.0))
            trade.PositionModify(ticket, wantedSL, wantedTP);
      }

      if(side == POSITION_TYPE_SELL && ask <= entry - start)
      {
         double lockSL = NormPrice(entry - lock);
         double trailSL = NormPrice(ask + gap);
         double wantedSL = MathMin(lockSL, trailSL);
         double wantedTP = RemoveTPWhenTrailStarts ? 0.0 : tp;
         if(sl == 0.0 || wantedSL < sl - (_Point * 2) || (RemoveTPWhenTrailStarts && tp != 0.0))
            trade.PositionModify(ticket, wantedSL, wantedTP);
      }
   }
}

//---------------- STRICT GRID ----------------//
bool HasGridLevelOpen(ENUM_POSITION_TYPE side, int level, double levelPrice)
{
   string exactComment = GridLevelComment(side, level);
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !IsEAOnlyCyclePosition(side, ticket)) continue;
      string cmt = PositionGetString(POSITION_COMMENT);
      if(!IsGridComment(cmt)) continue;
      if(cmt == exactComment) return true;
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      if(MathAbs(openPrice - levelPrice) <= GridLevelToleranceUSD) return true;
   }
   return false;
}

void HandleBuyStrictGridRefill()
{
   if(!EnableGridEngine || !g_buyCycleActive || g_buyManageOnly || g_buyBaseEntry <= 0.0) return;
   if(CountGridEntriesOnly(POSITION_TYPE_BUY) >= MaxGridOrdersBuy) return;

   double bid = BidPrice();
   for(int level = 1; level <= MaxGridOrdersBuy; level++)
   {
      if(CountGridEntriesOnly(POSITION_TYPE_BUY) >= MaxGridOrdersBuy) return;
      double levelPrice = NormPrice(g_buyBaseEntry - GetGridLevelDistance(level));
      if(bid <= levelPrice)
      {
         if(!HasGridLevelOpen(POSITION_TYPE_BUY, level, levelPrice) && !HasSameRangeOrder(POSITION_TYPE_BUY, levelPrice, DuplicateRangeBlockUSD, 0))
         {
            PlaceBuy(GridLevelComment(POSITION_TYPE_BUY, level), GridLotSize);
            return;
         }
      }
      else return;
   }
}

void HandleSellStrictGridRefill()
{
   if(!EnableGridEngine || !g_sellCycleActive || g_sellManageOnly || g_sellBaseEntry <= 0.0) return;
   if(CountGridEntriesOnly(POSITION_TYPE_SELL) >= MaxGridOrdersSell) return;

   double ask = AskPrice();
   for(int level = 1; level <= MaxGridOrdersSell; level++)
   {
      if(CountGridEntriesOnly(POSITION_TYPE_SELL) >= MaxGridOrdersSell) return;
      double levelPrice = NormPrice(g_sellBaseEntry + GetGridLevelDistance(level));
      if(ask >= levelPrice)
      {
         if(!HasGridLevelOpen(POSITION_TYPE_SELL, level, levelPrice) && !HasSameRangeOrder(POSITION_TYPE_SELL, levelPrice, DuplicateRangeBlockUSD, 0))
         {
            PlaceSell(GridLevelComment(POSITION_TYPE_SELL, level), GridLotSize);
            return;
         }
      }
      else return;
   }
}

void HandleGridEntries()
{
   if(!EnableGridEngine || !CanAddAnyNewOrders()) return;
   HandleBuyStrictGridRefill();
   HandleSellStrictGridRefill();
}

//---------------- TIMED BOOSTER ----------------//
bool BasePositive(ENUM_POSITION_TYPE side)
{
   if(side == POSITION_TYPE_BUY)
   {
      if(!SelectPos(g_buyBaseTicket)) return false;
      return (BidPrice() >= g_buyBaseEntry + TimedStartMove_USD);
   }
   if(!SelectPos(g_sellBaseTicket)) return false;
   return (AskPrice() <= g_sellBaseEntry - TimedStartMove_USD);
}

bool TimedSpacingAllows(ENUM_POSITION_TYPE side)
{
   double lastTimed = GetLatestTimedEntryPrice(side);
   if(lastTimed <= 0.0) return true;
   double nowPrice = (side == POSITION_TYPE_BUY ? AskPrice() : BidPrice());
   return (MathAbs(nowPrice - lastTimed) >= TimedMinSpacingUSD);
}

string TimedBlockReason(ENUM_POSITION_TYPE side)
{
   if(!EnableTimedEntries) return "OFF";
   if(!CanAddAnyNewOrders()) return "DD pause";
   if(side == POSITION_TYPE_BUY)
   {
      if(!g_buyCycleActive) return "No base";
      if(g_buyManageOnly) return "Manage only";
      if(!SelectPos(g_buyBaseTicket)) return "Base closed";
      if(!BasePositive(side)) return "Base not positive";
      if(CountByFamily(side, 1) >= MaxTimedOrdersBuy) return "Max timed";
   }
   else
   {
      if(!g_sellCycleActive) return "No base";
      if(g_sellManageOnly) return "Manage only";
      if(!SelectPos(g_sellBaseTicket)) return "Base closed";
      if(!BasePositive(side)) return "Base not positive";
      if(CountByFamily(side, 1) >= MaxTimedOrdersSell) return "Max timed";
   }
   if(CountNegativeTimedPositions(side) >= MaxNegativeTimedOrders) return "Timed neg cap";
   if(!TimedSpacingAllows(side)) return "Spacing block";
   return "READY";
}

void HandleTimedEntries()
{
   if(!EnableTimedEntries || !CanAddAnyNewOrders()) return;
   datetime now = TimeCurrent();

   if(g_buyCycleActive && !g_buyManageOnly && BasePositive(POSITION_TYPE_BUY))
   {
      if(CountByFamily(POSITION_TYPE_BUY, 1) < MaxTimedOrdersBuy &&
         CountNegativeTimedPositions(POSITION_TYPE_BUY) < MaxNegativeTimedOrders &&
         TimedSpacingAllows(POSITION_TYPE_BUY))
      {
         if(g_lastBuyTimedAdd == 0 || (now - g_lastBuyTimedAdd) >= TimedAddIntervalSec)
         {
            double px = AskPrice();
            if(!HasSameRangeOrder(POSITION_TYPE_BUY, px, DuplicateRangeBlockUSD, 1))
            {
               if(PlaceBuy(CMT_BUY_TIMED, TimedLotSize)) g_lastBuyTimedAdd = now;
            }
         }
      }
   }

   if(g_sellCycleActive && !g_sellManageOnly && BasePositive(POSITION_TYPE_SELL))
   {
      if(CountByFamily(POSITION_TYPE_SELL, 1) < MaxTimedOrdersSell &&
         CountNegativeTimedPositions(POSITION_TYPE_SELL) < MaxNegativeTimedOrders &&
         TimedSpacingAllows(POSITION_TYPE_SELL))
      {
         if(g_lastSellTimedAdd == 0 || (now - g_lastSellTimedAdd) >= TimedAddIntervalSec)
         {
            double px = BidPrice();
            if(!HasSameRangeOrder(POSITION_TYPE_SELL, px, DuplicateRangeBlockUSD, 1))
            {
               if(PlaceSell(CMT_SELL_TIMED, TimedLotSize)) g_lastSellTimedAdd = now;
            }
         }
      }
   }
}

//---------------- OPTIONAL RECOVERY ----------------//
double GetGridAveragePrice(ENUM_POSITION_TYPE side)
{
   double sumVol = 0.0, sumWeighted = 0.0;
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !IsEAOnlyCyclePosition(side, ticket)) continue;
      string cmt = PositionGetString(POSITION_COMMENT);
      if(!IsGridFamilyComment(cmt)) continue;
      double vol = PositionGetDouble(POSITION_VOLUME);
      double pr = PositionGetDouble(POSITION_PRICE_OPEN);
      sumVol += vol; sumWeighted += vol * pr;
   }
   if(sumVol <= 0.0) return 0.0;
   return sumWeighted / sumVol;
}

int CountNegativeGridFamily(ENUM_POSITION_TYPE side)
{
   int count = 0;
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !IsEAOnlyCyclePosition(side, ticket)) continue;
      if(!IsGridFamilyComment(PositionGetString(POSITION_COMMENT))) continue;
      if(PositionGetDouble(POSITION_PROFIT) < 0.0) count++;
   }
   return count;
}

void HandleRecoveryEntries()
{
   if(!EnableRecoveryBoost || !CanAddAnyNewOrders()) return;

   if(g_buyCycleActive && !g_buyManageOnly && !g_buyRecoveryUsed)
   {
      double avg = GetGridAveragePrice(POSITION_TYPE_BUY);
      if(CountGridEntriesOnly(POSITION_TYPE_BUY) >= MinGridEntriesForRecovery && CountNegativeGridFamily(POSITION_TYPE_BUY) > 0 && avg > 0.0)
      {
         double price = BidPrice();
         if(price >= avg - RecoveryZoneUSD && price <= avg + RecoveryZoneUSD)
            if(PlaceBuy(CMT_BUY_RECOV, RecoveryLotSize)) g_buyRecoveryUsed = true;
      }
   }

   if(g_sellCycleActive && !g_sellManageOnly && !g_sellRecoveryUsed)
   {
      double avg = GetGridAveragePrice(POSITION_TYPE_SELL);
      if(CountGridEntriesOnly(POSITION_TYPE_SELL) >= MinGridEntriesForRecovery && CountNegativeGridFamily(POSITION_TYPE_SELL) > 0 && avg > 0.0)
      {
         double price = AskPrice();
         if(price >= avg - RecoveryZoneUSD && price <= avg + RecoveryZoneUSD)
            if(PlaceSell(CMT_SELL_RECOV, RecoveryLotSize)) g_sellRecoveryUsed = true;
      }
   }
}

//---------------- GRID BASKET TP/TRAIL ----------------//
void CloseFamilySide(ENUM_POSITION_TYPE side, int family)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !IsEAOnlyCyclePosition(side, ticket)) continue;
      string cmt = PositionGetString(POSITION_COMMENT);
      if(family == 0 && !IsGridFamilyComment(cmt)) continue;
      if(family == 1 && !IsTimedComment(cmt)) continue;
      if(family == 2 && !IsRecoveryComment(cmt)) continue;
      trade.PositionClose(ticket);
   }

   if(side == POSITION_TYPE_BUY && family == 0) g_buyGridBasketPeak = 0.0;
   if(side == POSITION_TYPE_SELL && family == 0) g_sellGridBasketPeak = 0.0;
}

void ManageGridBasket()
{
   if(g_buyCycleActive)
   {
      double p = GetFamilyFloatingProfit(POSITION_TYPE_BUY, 0);
      if(EnableGridBasketTP && p >= GridBasketTP_USD)
      {
         Print("GodFather V3: BUY grid basket TP hit.");
         CloseFamilySide(POSITION_TYPE_BUY, 0);
      }
      else if(EnableGridBasketTrailing && p >= GridBasketTrailStart_USD)
      {
         if(p > g_buyGridBasketPeak) g_buyGridBasketPeak = p;
         if(g_buyGridBasketPeak - p >= GridBasketTrailGap_USD)
         {
            Print("GodFather V3: BUY grid basket trailing hit.");
            CloseFamilySide(POSITION_TYPE_BUY, 0);
         }
      }
   }

   if(g_sellCycleActive)
   {
      double p = GetFamilyFloatingProfit(POSITION_TYPE_SELL, 0);
      if(EnableGridBasketTP && p >= GridBasketTP_USD)
      {
         Print("GodFather V3: SELL grid basket TP hit.");
         CloseFamilySide(POSITION_TYPE_SELL, 0);
      }
      else if(EnableGridBasketTrailing && p >= GridBasketTrailStart_USD)
      {
         if(p > g_sellGridBasketPeak) g_sellGridBasketPeak = p;
         if(g_sellGridBasketPeak - p >= GridBasketTrailGap_USD)
         {
            Print("GodFather V3: SELL grid basket trailing hit.");
            CloseFamilySide(POSITION_TYPE_SELL, 0);
         }
      }
   }
}

//---------------- DASHBOARD ----------------//
void CreateOrUpdateLabel(const string name, const string text, int x, int y, color clr)
{
   if(ObjectFind(0, name) < 0)
   {
      ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
      ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
      ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 10);
      ObjectSetString(0, name, OBJPROP_FONT, "Arial");
   }
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
}

void DeleteLabels()
{
   string names[8] = {"GFV3_TITLE","GFV3_BUY","GFV3_SELL","GFV3_TIMED_BUY","GFV3_TIMED_SELL","GFV3_GRID","GFV3_FLOAT","GFV3_NOTE"};
   for(int i = 0; i < 8; i++) ObjectDelete(0, names[i]);
}

string ModeText()
{
   if(StartMode == MANUAL_ONLY) return "MANUAL_ONLY";
   if(StartMode == AUTO_ONLY) return "AUTO_ONLY";
   return "BOTH";
}

void UpdateLabels()
{
   string title = "GodFather V3 | " + g_symbol + " | Mode:" + ModeText() + " | Grid:Independent | Timed:Controlled";

   string buyTxt = "BUY  Active:" + (g_buyCycleActive ? "Y" : "N") +
                   " MOnly:" + (g_buyManageOnly ? "Y" : "N") +
                   " Grid:" + IntegerToString(CountGridEntriesOnly(POSITION_TYPE_BUY)) +
                   " Timed:" + IntegerToString(CountByFamily(POSITION_TYPE_BUY, 1)) +
                   " Lot:" + DoubleToString(GetLotSum(POSITION_TYPE_BUY), 2) +
                   " High:" + DoubleToString(GetHighestEAOpenPrice(POSITION_TYPE_BUY), _Digits) +
                   " Low:" + DoubleToString(GetLowestEAOpenPrice(POSITION_TYPE_BUY), _Digits) +
                   " P/L:" + DoubleToString(GetEAOnlyFloatingProfit(POSITION_TYPE_BUY), 2);

   string sellTxt = "SELL Active:" + (g_sellCycleActive ? "Y" : "N") +
                    " MOnly:" + (g_sellManageOnly ? "Y" : "N") +
                    " Grid:" + IntegerToString(CountGridEntriesOnly(POSITION_TYPE_SELL)) +
                    " Timed:" + IntegerToString(CountByFamily(POSITION_TYPE_SELL, 1)) +
                    " Lot:" + DoubleToString(GetLotSum(POSITION_TYPE_SELL), 2) +
                    " High:" + DoubleToString(GetHighestEAOpenPrice(POSITION_TYPE_SELL), _Digits) +
                    " Low:" + DoubleToString(GetLowestEAOpenPrice(POSITION_TYPE_SELL), _Digits) +
                    " P/L:" + DoubleToString(GetEAOnlyFloatingProfit(POSITION_TYPE_SELL), 2);

   string timedBuy = "Timed BUY  Status:" + TimedBlockReason(POSITION_TYPE_BUY) +
                     " Neg:" + IntegerToString(CountNegativeTimedPositions(POSITION_TYPE_BUY)) + "/" + IntegerToString(MaxNegativeTimedOrders) +
                     " Float:" + DoubleToString(GetFamilyFloatingProfit(POSITION_TYPE_BUY, 1), 2);

   string timedSell = "Timed SELL Status:" + TimedBlockReason(POSITION_TYPE_SELL) +
                      " Neg:" + IntegerToString(CountNegativeTimedPositions(POSITION_TYPE_SELL)) + "/" + IntegerToString(MaxNegativeTimedOrders) +
                      " Float:" + DoubleToString(GetFamilyFloatingProfit(POSITION_TYPE_SELL, 1), 2);

   string gridTxt = "Grid Basket BUY:" + DoubleToString(GetFamilyFloatingProfit(POSITION_TYPE_BUY, 0), 2) +
                    " SELL:" + DoubleToString(GetFamilyFloatingProfit(POSITION_TYPE_SELL, 0), 2) +
                    " | TP:" + DoubleToString(GridBasketTP_USD, 2) +
                    " Trail:" + DoubleToString(GridBasketTrailStart_USD, 2) + "/" + DoubleToString(GridBasketTrailGap_USD, 2);

   string floatTxt = "Total EA Float:" + DoubleToString(GetAllEAProfit(), 2) +
                     " | Broker TP backup:ON | Remove TP on trail:" + (RemoveTPWhenTrailStarts ? "ON" : "OFF");

   CreateOrUpdateLabel("GFV3_TITLE", title, 10, 20, clrGold);
   CreateOrUpdateLabel("GFV3_BUY", buyTxt, 10, 40, clrLime);
   CreateOrUpdateLabel("GFV3_SELL", sellTxt, 10, 60, clrTomato);
   CreateOrUpdateLabel("GFV3_TIMED_BUY", timedBuy, 10, 80, clrAqua);
   CreateOrUpdateLabel("GFV3_TIMED_SELL", timedSell, 10, 100, clrAqua);
   CreateOrUpdateLabel("GFV3_GRID", gridTxt, 10, 120, clrWhite);
   CreateOrUpdateLabel("GFV3_FLOAT", floatTxt, 10, 140, clrWhite);
}

//---------------- MT5 EVENTS ----------------//
int OnInit()
{
   g_symbol = _Symbol;
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(SlippagePoints);
   UpdateLabels();
   Print("GodFather V3 initialized on ", g_symbol, " | Mode=", ModeText());
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   DeleteLabels();
}

void OnTick()
{
   DetectManualBaseOrders();
   CheckAutoStart();
   UpdateBaseAliveState();

   // Existing order management first
   ApplyBrokerTPBackup();
   ManageTrailing();

   // Independent engines
   HandleGridEntries();       // normal grid independent, not controlled by timed negative cap
   HandleTimedEntries();      // timed booster controlled by base-positive + timed negative cap
   HandleRecoveryEntries();   // optional, default OFF

   // Re-apply protection immediately after new orders
   ApplyBrokerTPBackup();
   ManageTrailing();

   // Grid basket is separate from timed entries
   ManageGridBasket();

   ValidateResetConditions();
   UpdateLabels();
}
//+------------------------------------------------------------------+
