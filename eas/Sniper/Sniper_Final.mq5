//+------------------------------------------------------------------+
//| Sniper_V2.mq5                                                    |
//| Auto BUY + SELL Grid, Dynamic Recovery, Profit Bank Smart Exit   |
//| Rapid Hedge + Hope-style Trend Burst                             |
//+------------------------------------------------------------------+
#property strict
#property version "2.00"

#include <Trade/Trade.mqh>
CTrade trade;

//---------------- ENUMS ----------------//
enum ENUM_SNIPER_MODE
{
   MODE_AUTO_BOTH      = 0,
   MODE_AUTO_BUY_ONLY  = 1,
   MODE_AUTO_SELL_ONLY = 2,
   MODE_MANUAL_BUY     = 3,
   MODE_MANUAL_SELL    = 4
};

//---------------- INPUTS ----------------//
input string EA_Name = "Sniper_V2";
input ENUM_SNIPER_MODE TradeMode = MODE_AUTO_BOTH;

input double LotSize = 0.01;
input int    MagicBuy  = 4540017;
input int    MagicSell = 4540027;

// Core grid
input bool   EnableGridEngine     = true;
input double GridSpacingUSD       = 2.0;
input int    GridMinIntervalSec   = 5;
input double DuplicateBlockUSD    = 0.30;
input int    MaxBuyOrders         = 200;
input int    MaxSellOrders        = 200;

// First orders individual TP / trailing
input int    FirstTPOrders        = 20;
input double FirstOrderTP_USD     = 2.0;
input double TrailStartUSD        = 2.0;
input double TrailGapUSD          = 1.0;
input double TrailLockUSD         = 0.5;

// Dynamic recovery after FirstTPOrders
input bool   EnableDynamicRecoveryTP = true;
input double DD_Level1_USD           = 100.0;
input double DD_Level2_USD           = 300.0;
input double BasketTP_Level0_USD     = 10.0;
input double BasketTP_Level1_USD     = 25.0;
input double BasketTP_Level2_USD     = 50.0;
input double BasketTrailStart_L0_USD = 15.0;
input double BasketTrailStart_L1_USD = 30.0;
input double BasketTrailStart_L2_USD = 70.0;
input double BasketTrailGap_L0_USD   = 5.0;
input double BasketTrailGap_L1_USD   = 10.0;
input double BasketTrailGap_L2_USD   = 20.0;

// Profit Bank Smart Exit
input bool   EnableProfitBankSmartExit = true;
input double ProfitBankDepositPercent  = 100.0; // 100 = all positive closed profit goes to bank
input double SmartExitCloseFactor      = 1.0;   // 1.0 exact, 0.8 aggressive, 1.5 conservative
input int    SmartExitMinHoldMinutes   = 60;
input double SmartExitMinLossUSD       = 1.0;
input double SmartExitMaxSingleLossUSD = 999999.0;

// Rapid hedge against stuck side
input bool   EnableRapidHedge      = true;
input double RapidHedgeDDTrigger   = 150.0;
input double RapidHedgeSpacingUSD  = 1.0;
input int    RapidHedgeIntervalSec = 5;
input int    RapidHedgeMaxOrders   = 10;

// Hope-style Trend Burst
input bool   EnableTrendBurst       = true;
input int    TrendBurstIntervalSec  = 5;
input int    TrendBurstMaxNegative  = 3;
input double TrendBurstResetUSD     = 25.0;
input double TrendBurstSpacingUSD   = 1.0;

// Trend / bias indicators
input ENUM_TIMEFRAMES SignalTF = PERIOD_M5;
input int    EMAFastPeriod = 50;
input int    EMASlowPeriod = 200;
input int    RSIPeriod     = 14;
input double BullRSILevel  = 55.0;
input double BearRSILevel  = 45.0;
input double SARStep       = 0.02;
input double SARMaximum    = 0.2;

//---------------- GLOBALS ----------------//
int hEmaFast = INVALID_HANDLE;
int hEmaSlow = INVALID_HANDLE;
int hRsi     = INVALID_HANDLE;
int hSar     = INVALID_HANDLE;

datetime lastBuyGridTime  = 0;
datetime lastSellGridTime = 0;
datetime lastRapidBuyTime = 0;
datetime lastRapidSellTime= 0;
datetime lastBurstTime    = 0;

bool   burstPausedBuy  = false;
bool   burstPausedSell = false;
double burstPausePriceBuy  = 0.0;
double burstPausePriceSell = 0.0;

double profitBank = 0.0;
string gvBankName = "";

double buyBasketPeak  = 0.0;
double sellBasketPeak = 0.0;

//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(MagicBuy);

   hEmaFast = iMA(_Symbol, SignalTF, EMAFastPeriod, 0, MODE_EMA, PRICE_CLOSE);
   hEmaSlow = iMA(_Symbol, SignalTF, EMASlowPeriod, 0, MODE_EMA, PRICE_CLOSE);
   hRsi     = iRSI(_Symbol, SignalTF, RSIPeriod, PRICE_CLOSE);
   hSar     = iSAR(_Symbol, SignalTF, SARStep, SARMaximum);

   if(hEmaFast == INVALID_HANDLE || hEmaSlow == INVALID_HANDLE || hRsi == INVALID_HANDLE || hSar == INVALID_HANDLE)
   {
      Print("Indicator handle creation failed.");
      return INIT_FAILED;
   }

   gvBankName = EA_Name + "_" + _Symbol + "_ProfitBank";
   if(GlobalVariableCheck(gvBankName))
      profitBank = GlobalVariableGet(gvBankName);
   else
      GlobalVariableSet(gvBankName, profitBank);

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(hEmaFast != INVALID_HANDLE) IndicatorRelease(hEmaFast);
   if(hEmaSlow != INVALID_HANDLE) IndicatorRelease(hEmaSlow);
   if(hRsi     != INVALID_HANDLE) IndicatorRelease(hRsi);
   if(hSar     != INVALID_HANDLE) IndicatorRelease(hSar);
}

//+------------------------------------------------------------------+
void OnTick()
{
   ManageTrailing();
   ManageDynamicBasketTP();
   ManageProfitBankSmartExit();
   ManageGridEngine();
   ManageRapidHedge();
   ManageTrendBurst();
   DrawDashboard();
}

//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction& trans,
                        const MqlTradeRequest& request,
                        const MqlTradeResult& result)
{
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;
   if(!HistoryDealSelect(trans.deal)) return;

   long magic = HistoryDealGetInteger(trans.deal, DEAL_MAGIC);
   if(magic != MagicBuy && magic != MagicSell) return;

   long entry = HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
   if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_OUT_BY) return;

   double p = HistoryDealGetDouble(trans.deal, DEAL_PROFIT)
            + HistoryDealGetDouble(trans.deal, DEAL_SWAP)
            + HistoryDealGetDouble(trans.deal, DEAL_COMMISSION);

   if(p > 0.0)
   {
      profitBank += p * (ProfitBankDepositPercent / 100.0);
      GlobalVariableSet(gvBankName, profitBank);
   }
}

//+------------------------------------------------------------------+
bool IsOurMagic(long magic)
{
   return (magic == MagicBuy || magic == MagicSell);
}

//+------------------------------------------------------------------+
bool BuyAllowed()
{
   return (TradeMode == MODE_AUTO_BOTH || TradeMode == MODE_AUTO_BUY_ONLY || TradeMode == MODE_MANUAL_BUY);
}

//+------------------------------------------------------------------+
bool SellAllowed()
{
   return (TradeMode == MODE_AUTO_BOTH || TradeMode == MODE_AUTO_SELL_ONLY || TradeMode == MODE_MANUAL_SELL);
}

//+------------------------------------------------------------------+
bool ManualBuyPresent()
{
   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((int)PositionGetInteger(POSITION_TYPE) != POSITION_TYPE_BUY) continue;
      if((long)PositionGetInteger(POSITION_MAGIC) == 0) return true;
   }
   return false;
}

//+------------------------------------------------------------------+
bool ManualSellPresent()
{
   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((int)PositionGetInteger(POSITION_TYPE) != POSITION_TYPE_SELL) continue;
      if((long)PositionGetInteger(POSITION_MAGIC) == 0) return true;
   }
   return false;
}

//+------------------------------------------------------------------+
int CountPositions(int type, int magic)
{
   int count = 0;
   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((int)PositionGetInteger(POSITION_TYPE) != type) continue;
      if((int)PositionGetInteger(POSITION_MAGIC) != magic) continue;
      count++;
   }
   return count;
}

//+------------------------------------------------------------------+
int CountNegativePositions(int type, int magic)
{
   int count = 0;
   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((int)PositionGetInteger(POSITION_TYPE) != type) continue;
      if((int)PositionGetInteger(POSITION_MAGIC) != magic) continue;

      double profit = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      if(profit < 0.0) count++;
   }
   return count;
}

//+------------------------------------------------------------------+
double SideLots(int type, int magic)
{
   double lots = 0.0;
   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((int)PositionGetInteger(POSITION_TYPE) != type) continue;
      if((int)PositionGetInteger(POSITION_MAGIC) != magic) continue;
      lots += PositionGetDouble(POSITION_VOLUME);
   }
   return lots;
}

//+------------------------------------------------------------------+
double SideProfit(int type, int magic)
{
   double profit = 0.0;
   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((int)PositionGetInteger(POSITION_TYPE) != type) continue;
      if((int)PositionGetInteger(POSITION_MAGIC) != magic) continue;

      profit += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
   }
   return profit;
}

//+------------------------------------------------------------------+
double SideNegativeLossAbs(int type, int magic)
{
   double loss = 0.0;
   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((int)PositionGetInteger(POSITION_TYPE) != type) continue;
      if((int)PositionGetInteger(POSITION_MAGIC) != magic) continue;

      double p = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      if(p < 0.0) loss += MathAbs(p);
   }
   return loss;
}

//+------------------------------------------------------------------+
double LowestPrice(int type, int magic)
{
   double price = 0.0;
   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((int)PositionGetInteger(POSITION_TYPE) != type) continue;
      if((int)PositionGetInteger(POSITION_MAGIC) != magic) continue;

      double open = PositionGetDouble(POSITION_PRICE_OPEN);
      if(price == 0.0 || open < price) price = open;
   }
   return price;
}

//+------------------------------------------------------------------+
double HighestPrice(int type, int magic)
{
   double price = 0.0;
   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((int)PositionGetInteger(POSITION_TYPE) != type) continue;
      if((int)PositionGetInteger(POSITION_MAGIC) != magic) continue;

      double open = PositionGetDouble(POSITION_PRICE_OPEN);
      if(price == 0.0 || open > price) price = open;
   }
   return price;
}

//+------------------------------------------------------------------+
bool HasNearbyOrder(int type, int magic, double price, double blockUSD)
{
   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((int)PositionGetInteger(POSITION_TYPE) != type) continue;
      if((int)PositionGetInteger(POSITION_MAGIC) != magic) continue;

      double open = PositionGetDouble(POSITION_PRICE_OPEN);
      if(MathAbs(open - price) <= blockUSD) return true;
   }
   return false;
}

//+------------------------------------------------------------------+
bool PriceIsOutsideGridZone(int type, int magic, double price, double spacing)
{
   int count = CountPositions(type, magic);
   if(count == 0) return true;

   double low  = LowestPrice(type, magic);
   double high = HighestPrice(type, magic);

   if(price <= low - spacing)  return true;
   if(price >= high + spacing) return true;

   return false;
}

//+------------------------------------------------------------------+
bool GetSignal(double &emaFast, double &emaSlow, double &rsi, double &sar)
{
   double b1[1], b2[1], b3[1], b4[1];

   if(CopyBuffer(hEmaFast, 0, 0, 1, b1) <= 0) return false;
   if(CopyBuffer(hEmaSlow, 0, 0, 1, b2) <= 0) return false;
   if(CopyBuffer(hRsi,     0, 0, 1, b3) <= 0) return false;
   if(CopyBuffer(hSar,     0, 0, 1, b4) <= 0) return false;

   emaFast = b1[0];
   emaSlow = b2[0];
   rsi     = b3[0];
   sar     = b4[0];

   return true;
}

//+------------------------------------------------------------------+
int TrendBias()
{
   double emaFast, emaSlow, rsi, sar;
   if(!GetSignal(emaFast, emaSlow, rsi, sar)) return 0;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   bool bull = (emaFast > emaSlow && rsi >= BullRSILevel && sar < bid);
   bool bear = (emaFast < emaSlow && rsi <= BearRSILevel && sar > bid);

   if(bull) return 1;
   if(bear) return -1;
   return 0;
}

//+------------------------------------------------------------------+
void OpenBuy(string tag)
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   int count = CountPositions(POSITION_TYPE_BUY, MagicBuy);

   double tp = 0.0;
   if(count < FirstTPOrders)
      tp = NormalizeDouble(ask + FirstOrderTP_USD, _Digits);

   trade.SetExpertMagicNumber(MagicBuy);
   bool ok = trade.Buy(LotSize, _Symbol, ask, 0.0, tp, EA_Name + "_" + tag);
   if(!ok) Print("BUY failed. Retcode=", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
}

//+------------------------------------------------------------------+
void OpenSell(string tag)
{
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   int count = CountPositions(POSITION_TYPE_SELL, MagicSell);

   double tp = 0.0;
   if(count < FirstTPOrders)
      tp = NormalizeDouble(bid - FirstOrderTP_USD, _Digits);

   trade.SetExpertMagicNumber(MagicSell);
   bool ok = trade.Sell(LotSize, _Symbol, bid, 0.0, tp, EA_Name + "_" + tag);
   if(!ok) Print("SELL failed. Retcode=", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
}

//+------------------------------------------------------------------+
void ManageGridEngine()
{
   if(!EnableGridEngine) return;

   bool allowBuy = BuyAllowed();
   bool allowSell = SellAllowed();

   if(TradeMode == MODE_MANUAL_BUY)  allowBuy  = ManualBuyPresent();
   if(TradeMode == MODE_MANUAL_SELL) allowSell = ManualSellPresent();

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   if(allowBuy && CountPositions(POSITION_TYPE_BUY, MagicBuy) < MaxBuyOrders)
   {
      if(TimeCurrent() - lastBuyGridTime >= GridMinIntervalSec)
      {
         if(PriceIsOutsideGridZone(POSITION_TYPE_BUY, MagicBuy, ask, GridSpacingUSD) &&
            !HasNearbyOrder(POSITION_TYPE_BUY, MagicBuy, ask, DuplicateBlockUSD))
         {
            OpenBuy("BUY_GRID");
            lastBuyGridTime = TimeCurrent();
         }
      }
   }

   if(allowSell && CountPositions(POSITION_TYPE_SELL, MagicSell) < MaxSellOrders)
   {
      if(TimeCurrent() - lastSellGridTime >= GridMinIntervalSec)
      {
         if(PriceIsOutsideGridZone(POSITION_TYPE_SELL, MagicSell, bid, GridSpacingUSD) &&
            !HasNearbyOrder(POSITION_TYPE_SELL, MagicSell, bid, DuplicateBlockUSD))
         {
            OpenSell("SELL_GRID");
            lastSellGridTime = TimeCurrent();
         }
      }
   }
}

//+------------------------------------------------------------------+
bool ModifyPositionByTicket(ulong ticket, double sl, double tp)
{
   MqlTradeRequest req;
   MqlTradeResult  res;
   ZeroMemory(req);
   ZeroMemory(res);

   req.action   = TRADE_ACTION_SLTP;
   req.position = ticket;
   req.symbol   = _Symbol;
   req.sl       = sl;
   req.tp       = tp;

   bool ok = OrderSend(req, res);
   if(!ok) Print("Modify failed ticket=", ticket, " ret=", res.retcode);
   return ok;
}

//+------------------------------------------------------------------+
void ManageTrailing()
{
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;

      long magic = PositionGetInteger(POSITION_MAGIC);
      if(!IsOurMagic(magic)) continue;

      int type = (int)PositionGetInteger(POSITION_TYPE);
      double open = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl   = PositionGetDouble(POSITION_SL);

      if(type == POSITION_TYPE_BUY)
      {
         double move = bid - open;
         if(move >= TrailStartUSD)
         {
            double newSL = NormalizeDouble(bid - TrailGapUSD, _Digits);
            double minSL = NormalizeDouble(open + TrailLockUSD, _Digits);
            if(newSL < minSL) newSL = minSL;

            // TP removed once trailing starts
            if(sl == 0.0 || newSL > sl)
               ModifyPositionByTicket(ticket, newSL, 0.0);
         }
      }
      else if(type == POSITION_TYPE_SELL)
      {
         double move = open - ask;
         if(move >= TrailStartUSD)
         {
            double newSL = NormalizeDouble(ask + TrailGapUSD, _Digits);
            double maxSL = NormalizeDouble(open - TrailLockUSD, _Digits);
            if(newSL > maxSL) newSL = maxSL;

            // TP removed once trailing starts
            if(sl == 0.0 || newSL < sl)
               ModifyPositionByTicket(ticket, newSL, 0.0);
         }
      }
   }
}

//+------------------------------------------------------------------+
void DynamicParams(double sideLossAbs, double &basketTP, double &trailStart, double &trailGap, int &level)
{
   level = 0;
   basketTP   = BasketTP_Level0_USD;
   trailStart = BasketTrailStart_L0_USD;
   trailGap   = BasketTrailGap_L0_USD;

   if(sideLossAbs >= DD_Level2_USD)
   {
      level = 2;
      basketTP   = BasketTP_Level2_USD;
      trailStart = BasketTrailStart_L2_USD;
      trailGap   = BasketTrailGap_L2_USD;
   }
   else if(sideLossAbs >= DD_Level1_USD)
   {
      level = 1;
      basketTP   = BasketTP_Level1_USD;
      trailStart = BasketTrailStart_L1_USD;
      trailGap   = BasketTrailGap_L1_USD;
   }
}

//+------------------------------------------------------------------+
void CloseSide(int type, int magic, string reason)
{
   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((int)PositionGetInteger(POSITION_TYPE) != type) continue;
      if((int)PositionGetInteger(POSITION_MAGIC) != magic) continue;

      trade.PositionClose(ticket);
   }

   Print(reason);
}

//+------------------------------------------------------------------+
void ManageDynamicBasketTP()
{
   if(!EnableDynamicRecoveryTP) return;

   int buyCount  = CountPositions(POSITION_TYPE_BUY, MagicBuy);
   int sellCount = CountPositions(POSITION_TYPE_SELL, MagicSell);

   double buyPL  = SideProfit(POSITION_TYPE_BUY, MagicBuy);
   double sellPL = SideProfit(POSITION_TYPE_SELL, MagicSell);

   if(buyCount > FirstTPOrders)
   {
      double sideLoss = SideNegativeLossAbs(POSITION_TYPE_BUY, MagicBuy);
      double basketTP, trailStart, trailGap;
      int level;
      DynamicParams(sideLoss, basketTP, trailStart, trailGap, level);

      if(buyPL >= basketTP)
      {
         CloseSide(POSITION_TYPE_BUY, MagicBuy, "BUY dynamic basket TP closed.");
         buyBasketPeak = 0.0;
      }
      else if(buyPL >= trailStart)
      {
         if(buyPL > buyBasketPeak) buyBasketPeak = buyPL;
         if(buyBasketPeak - buyPL >= trailGap)
         {
            CloseSide(POSITION_TYPE_BUY, MagicBuy, "BUY dynamic basket trailing closed.");
            buyBasketPeak = 0.0;
         }
      }
      else
      {
         buyBasketPeak = 0.0;
      }
   }

   if(sellCount > FirstTPOrders)
   {
      double sideLoss = SideNegativeLossAbs(POSITION_TYPE_SELL, MagicSell);
      double basketTP, trailStart, trailGap;
      int level;
      DynamicParams(sideLoss, basketTP, trailStart, trailGap, level);

      if(sellPL >= basketTP)
      {
         CloseSide(POSITION_TYPE_SELL, MagicSell, "SELL dynamic basket TP closed.");
         sellBasketPeak = 0.0;
      }
      else if(sellPL >= trailStart)
      {
         if(sellPL > sellBasketPeak) sellBasketPeak = sellPL;
         if(sellBasketPeak - sellPL >= trailGap)
         {
            CloseSide(POSITION_TYPE_SELL, MagicSell, "SELL dynamic basket trailing closed.");
            sellBasketPeak = 0.0;
         }
      }
      else
      {
         sellBasketPeak = 0.0;
      }
   }
}

//+------------------------------------------------------------------+
ulong WorstTicket(int type, int magic, double &lossAbs, double &openPrice, datetime &openTime)
{
   ulong bestTicket = 0;
   lossAbs = 0.0;
   openPrice = 0.0;
   openTime = 0;

   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((int)PositionGetInteger(POSITION_TYPE) != type) continue;
      if((int)PositionGetInteger(POSITION_MAGIC) != magic) continue;

      double p = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      if(p >= -SmartExitMinLossUSD) continue;

      double open = PositionGetDouble(POSITION_PRICE_OPEN);
      datetime t  = (datetime)PositionGetInteger(POSITION_TIME);

      if((TimeCurrent() - t) < SmartExitMinHoldMinutes * 60) continue;

      // Worst BUY = highest buy price. Worst SELL = lowest sell price.
      bool isBetter = false;
      if(bestTicket == 0) isBetter = true;
      else if(type == POSITION_TYPE_BUY  && open > openPrice) isBetter = true;
      else if(type == POSITION_TYPE_SELL && open < openPrice) isBetter = true;

      if(isBetter)
      {
         bestTicket = ticket;
         lossAbs = MathAbs(p);
         openPrice = open;
         openTime = t;
      }
   }

   return bestTicket;
}

//+------------------------------------------------------------------+
void ManageProfitBankSmartExit()
{
   if(!EnableProfitBankSmartExit) return;
   if(profitBank <= 0.0) return;

   double buyLoss, buyOpen;
   double sellLoss, sellOpen;
   datetime buyTime, sellTime;

   ulong buyTicket  = WorstTicket(POSITION_TYPE_BUY,  MagicBuy,  buyLoss,  buyOpen,  buyTime);
   ulong sellTicket = WorstTicket(POSITION_TYPE_SELL, MagicSell, sellLoss, sellOpen, sellTime);

   ulong closeTicket = 0;
   double closeLoss = 0.0;

   if(buyTicket > 0 && sellTicket > 0)
   {
      if(buyLoss >= sellLoss)
      {
         closeTicket = buyTicket;
         closeLoss = buyLoss;
      }
      else
      {
         closeTicket = sellTicket;
         closeLoss = sellLoss;
      }
   }
   else if(buyTicket > 0)
   {
      closeTicket = buyTicket;
      closeLoss = buyLoss;
   }
   else if(sellTicket > 0)
   {
      closeTicket = sellTicket;
      closeLoss = sellLoss;
   }

   if(closeTicket == 0) return;
   if(closeLoss > SmartExitMaxSingleLossUSD) return;

   double needed = closeLoss * SmartExitCloseFactor;
   if(profitBank >= needed)
   {
      bool ok = trade.PositionClose(closeTicket);
      if(ok)
      {
         profitBank -= closeLoss;
         if(profitBank < 0.0) profitBank = 0.0;
         GlobalVariableSet(gvBankName, profitBank);
         Print("Profit Bank Smart Exit closed ticket=", closeTicket, " loss=", closeLoss, " bank=", profitBank);
      }
   }
}

//+------------------------------------------------------------------+
int CountRapidOrders(int type)
{
   int magic = (type == POSITION_TYPE_BUY ? MagicBuy : MagicSell);
   string key = (type == POSITION_TYPE_BUY ? "RAPID_BUY" : "RAPID_SELL");

   int count = 0;
   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((int)PositionGetInteger(POSITION_TYPE) != type) continue;
      if((int)PositionGetInteger(POSITION_MAGIC) != magic) continue;

      string c = PositionGetString(POSITION_COMMENT);
      if(StringFind(c, key) >= 0) count++;
   }
   return count;
}

//+------------------------------------------------------------------+
void ManageRapidHedge()
{
   if(!EnableRapidHedge) return;

   int bias = TrendBias();
   double buyLoss  = SideNegativeLossAbs(POSITION_TYPE_BUY, MagicBuy);
   double sellLoss = SideNegativeLossAbs(POSITION_TYPE_SELL, MagicSell);

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   // SELL stuck + bullish trend = rapid BUY hedge
   if(sellLoss >= RapidHedgeDDTrigger && bias == 1)
   {
      if(CountPositions(POSITION_TYPE_BUY, MagicBuy) < MaxBuyOrders &&
         CountRapidOrders(POSITION_TYPE_BUY) < RapidHedgeMaxOrders &&
         TimeCurrent() - lastRapidBuyTime >= RapidHedgeIntervalSec &&
         PriceIsOutsideGridZone(POSITION_TYPE_BUY, MagicBuy, ask, RapidHedgeSpacingUSD) &&
         !HasNearbyOrder(POSITION_TYPE_BUY, MagicBuy, ask, DuplicateBlockUSD))
      {
         OpenBuy("RAPID_BUY");
         lastRapidBuyTime = TimeCurrent();
      }
   }

   // BUY stuck + bearish trend = rapid SELL hedge
   if(buyLoss >= RapidHedgeDDTrigger && bias == -1)
   {
      if(CountPositions(POSITION_TYPE_SELL, MagicSell) < MaxSellOrders &&
         CountRapidOrders(POSITION_TYPE_SELL) < RapidHedgeMaxOrders &&
         TimeCurrent() - lastRapidSellTime >= RapidHedgeIntervalSec &&
         PriceIsOutsideGridZone(POSITION_TYPE_SELL, MagicSell, bid, RapidHedgeSpacingUSD) &&
         !HasNearbyOrder(POSITION_TYPE_SELL, MagicSell, bid, DuplicateBlockUSD))
      {
         OpenSell("RAPID_SELL");
         lastRapidSellTime = TimeCurrent();
      }
   }
}

//+------------------------------------------------------------------+
void ManageTrendBurst()
{
   if(!EnableTrendBurst) return;

   int bias = TrendBias();
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   // Reset pause after 25$ move into fresh zone.
   if(burstPausedBuy && burstPausePriceBuy > 0.0 && ask <= burstPausePriceBuy - TrendBurstResetUSD)
   {
      burstPausedBuy = false;
      burstPausePriceBuy = 0.0;
   }

   if(burstPausedSell && burstPausePriceSell > 0.0 && bid >= burstPausePriceSell + TrendBurstResetUSD)
   {
      burstPausedSell = false;
      burstPausePriceSell = 0.0;
   }

   if(TimeCurrent() - lastBurstTime < TrendBurstIntervalSec) return;

   if(bias == 1 && BuyAllowed() && CountPositions(POSITION_TYPE_BUY, MagicBuy) < MaxBuyOrders)
   {
      int neg = CountNegativePositions(POSITION_TYPE_BUY, MagicBuy);
      if(neg >= TrendBurstMaxNegative)
      {
         if(!burstPausedBuy)
         {
            burstPausedBuy = true;
            burstPausePriceBuy = ask;
         }
         return;
      }

      if(!burstPausedBuy &&
         PriceIsOutsideGridZone(POSITION_TYPE_BUY, MagicBuy, ask, TrendBurstSpacingUSD) &&
         !HasNearbyOrder(POSITION_TYPE_BUY, MagicBuy, ask, DuplicateBlockUSD))
      {
         OpenBuy("BURST_BUY");
         lastBurstTime = TimeCurrent();
      }
   }
   else if(bias == -1 && SellAllowed() && CountPositions(POSITION_TYPE_SELL, MagicSell) < MaxSellOrders)
   {
      int neg = CountNegativePositions(POSITION_TYPE_SELL, MagicSell);
      if(neg >= TrendBurstMaxNegative)
      {
         if(!burstPausedSell)
         {
            burstPausedSell = true;
            burstPausePriceSell = bid;
         }
         return;
      }

      if(!burstPausedSell &&
         PriceIsOutsideGridZone(POSITION_TYPE_SELL, MagicSell, bid, TrendBurstSpacingUSD) &&
         !HasNearbyOrder(POSITION_TYPE_SELL, MagicSell, bid, DuplicateBlockUSD))
      {
         OpenSell("BURST_SELL");
         lastBurstTime = TimeCurrent();
      }
   }
}

//+------------------------------------------------------------------+
string BiasText()
{
   int b = TrendBias();
   if(b == 1) return "BULL / BUY";
   if(b == -1) return "BEAR / SELL";
   return "NEUTRAL";
}

//+------------------------------------------------------------------+
string ModeText()
{
   if(TradeMode == MODE_AUTO_BOTH) return "AUTO BOTH";
   if(TradeMode == MODE_AUTO_BUY_ONLY) return "AUTO BUY ONLY";
   if(TradeMode == MODE_AUTO_SELL_ONLY) return "AUTO SELL ONLY";
   if(TradeMode == MODE_MANUAL_BUY) return "MANUAL BUY";
   if(TradeMode == MODE_MANUAL_SELL) return "MANUAL SELL";
   return "UNKNOWN";
}

//+------------------------------------------------------------------+
void DrawDashboard()
{
   int buyOrders  = CountPositions(POSITION_TYPE_BUY, MagicBuy);
   int sellOrders = CountPositions(POSITION_TYPE_SELL, MagicSell);

   double buyLots  = SideLots(POSITION_TYPE_BUY, MagicBuy);
   double sellLots = SideLots(POSITION_TYPE_SELL, MagicSell);

   double buyPL  = SideProfit(POSITION_TYPE_BUY, MagicBuy);
   double sellPL = SideProfit(POSITION_TYPE_SELL, MagicSell);

   int negBuy  = CountNegativePositions(POSITION_TYPE_BUY, MagicBuy);
   int negSell = CountNegativePositions(POSITION_TYPE_SELL, MagicSell);

   double buyLoss  = SideNegativeLossAbs(POSITION_TYPE_BUY, MagicBuy);
   double sellLoss = SideNegativeLossAbs(POSITION_TYPE_SELL, MagicSell);

   double buyWorstLoss, buyWorstOpen;
   double sellWorstLoss, sellWorstOpen;
   datetime t1, t2;
   WorstTicket(POSITION_TYPE_BUY, MagicBuy, buyWorstLoss, buyWorstOpen, t1);
   WorstTicket(POSITION_TYPE_SELL, MagicSell, sellWorstLoss, sellWorstOpen, t2);

   double btp, bts, btg;
   int blevel;
   DynamicParams(MathMax(buyLoss, sellLoss), btp, bts, btg, blevel);

   string burstStatus = "OFF";
   if(EnableTrendBurst)
   {
      if(TrendBias() == 1) burstStatus = burstPausedBuy ? "BUY PAUSED" : "BUY READY";
      else if(TrendBias() == -1) burstStatus = burstPausedSell ? "SELL PAUSED" : "SELL READY";
      else burstStatus = "WAITING TREND";
   }

   string resetBuy = "OFF";
   if(burstPausedBuy && burstPausePriceBuy > 0.0)
      resetBuy = DoubleToString(burstPausePriceBuy - TrendBurstResetUSD, _Digits);

   string resetSell = "OFF";
   if(burstPausedSell && burstPausePriceSell > 0.0)
      resetSell = DoubleToString(burstPausePriceSell + TrendBurstResetUSD, _Digits);

   double emaF, emaS, rsi, sar;
   bool sig = GetSignal(emaF, emaS, rsi, sar);

   string dash =
      "\n===================================="
      "\n         SNIPER V2 DASHBOARD"
      "\n===================================="
      "\nMode          : " + ModeText() +
      "\nTrend Bias    : " + BiasText() +
      "\nSignal TF     : " + EnumToString(SignalTF) +
      "\nEMA Fast/Slow : " + (sig ? DoubleToString(emaF, _Digits) + " / " + DoubleToString(emaS, _Digits) : "NA") +
      "\nRSI / SAR     : " + (sig ? DoubleToString(rsi, 1) + " / " + DoubleToString(sar, _Digits) : "NA") +
      "\n------------------------------------"
      "\nBUY SIDE"
      "\nOrders/Lots   : " + IntegerToString(buyOrders) + " / " + DoubleToString(buyLots, 2) +
      "\nP/L           : " + DoubleToString(buyPL, 2) +
      "\nNeg Orders    : " + IntegerToString(negBuy) +
      "\nNeg Loss      : " + DoubleToString(buyLoss, 2) +
      "\nLowest/Highest: " + DoubleToString(LowestPrice(POSITION_TYPE_BUY, MagicBuy), _Digits) + " / " + DoubleToString(HighestPrice(POSITION_TYPE_BUY, MagicBuy), _Digits) +
      "\nWorst BUY     : " + DoubleToString(buyWorstOpen, _Digits) + " / -" + DoubleToString(buyWorstLoss, 2) +
      "\n------------------------------------"
      "\nSELL SIDE"
      "\nOrders/Lots   : " + IntegerToString(sellOrders) + " / " + DoubleToString(sellLots, 2) +
      "\nP/L           : " + DoubleToString(sellPL, 2) +
      "\nNeg Orders    : " + IntegerToString(negSell) +
      "\nNeg Loss      : " + DoubleToString(sellLoss, 2) +
      "\nLowest/Highest: " + DoubleToString(LowestPrice(POSITION_TYPE_SELL, MagicSell), _Digits) + " / " + DoubleToString(HighestPrice(POSITION_TYPE_SELL, MagicSell), _Digits) +
      "\nWorst SELL    : " + DoubleToString(sellWorstOpen, _Digits) + " / -" + DoubleToString(sellWorstLoss, 2) +
      "\n------------------------------------"
      "\nRECOVERY"
      "\nProfit Bank   : " + DoubleToString(profitBank, 2) +
      "\nDynamic Level : " + IntegerToString(blevel) +
      "\nBasket TP     : " + DoubleToString(btp, 2) +
      "\nTrail Start/G : " + DoubleToString(bts, 2) + " / " + DoubleToString(btg, 2) +
      "\nRapid Hedge   : " + (EnableRapidHedge ? "ON" : "OFF") +
      "\nTrend Burst   : " + burstStatus +
      "\nBurst Reset B : " + resetBuy +
      "\nBurst Reset S : " + resetSell +
      "\n------------------------------------"
      "\nTOTAL P/L     : " + DoubleToString(buyPL + sellPL, 2) +
      "\nTOTAL ORDERS  : " + IntegerToString(buyOrders + sellOrders) +
      "\n====================================";

   Comment(dash);
}
//+------------------------------------------------------------------+

