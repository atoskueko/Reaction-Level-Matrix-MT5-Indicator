//+------------------------------------------------------------------+
//|                                          ReactionLevelMatrix.mq5 |
//|  MQL5 port of "Reaction Level Matrix [WillyAlgoTrader]" v1.0.2   |
//|  (TradingView Pine v6, overlay).                                 |
//|                                                                  |
//|  - Level engine: confirmed swings (pivot high/low) are clustered |
//|    online into weighted price bands (center = weighted mean,     |
//|    half-width = weighted stdev clamped to [0.15, tol] x ATR),    |
//|    strength decays with a half-life, crosses cost strength,      |
//|    overlapping levels merge, memory capped at 60 levels.         |
//|  - Score = 100 x (1 - e^(-s/6)), polarity bonus x1.25.           |
//|  - Signals: rejection at the nearest shown support / resistance  |
//|    (close strength, min score, cooldown).                        |
//|  - Trade engine: one trade at a time, SL Wick-Anchored / ATR,    |
//|    TP1-3 in R (presets), BE after TP1, TP priority, reversal on  |
//|    opposite signal, session stats (wins/losses/win-rate/form).   |
//|  - Visuals: level bands + mid lines + score labels, Long/Short   |
//|    entry labels, Entry/SL/TP lines + labels, dashboard (Market / |
//|    Levels / Trade / Stats sections), watermark, alerts.          |
//|                                                                  |
//|  Design: all state updates on CLOSED bars only (== Pine          |
//|  barstate.isconfirmed), every closed bar processed exactly once. |
//|  Drawings are rendered from state; the history pass creates only |
//|  the objects that still exist. Level bands / dashboard follow    |
//|  the last closed bar (Pine re-selects on the live close too).    |
//+------------------------------------------------------------------+
#property copyright "Port of Reaction Level Matrix [WillyAlgoTrader]"
#property version   "1.02"
#property indicator_chart_window
#property indicator_buffers 6
#property indicator_plots   6
#property indicator_label1  "long_entry"
#property indicator_type1   DRAW_NONE
#property indicator_label2  "short_entry"
#property indicator_type2   DRAW_NONE
#property indicator_label3  "long_signal"
#property indicator_type3   DRAW_NONE
#property indicator_label4  "short_signal"
#property indicator_type4   DRAW_NONE
#property indicator_label5  "entry_sl"
#property indicator_type5   DRAW_NONE
#property indicator_label6  "entry_tp1"
#property indicator_type6   DRAW_NONE

//============================ CONSTANTS =============================
#define STRUCT_ATR_LEN     34
#define MIN_HALF_WIDTH_ATR 0.15
#define REACTION_CAP       2.5
#define SCORE_SCALE        6.0
#define POLARITY_BONUS     1.25
#define CROSS_PENALTY      0.7
#define MIN_STRENGTH       0.25
#define MAX_LEVELS         60
#define MERGE_PASSES       5
#define LEVEL_RIGHT_EXT    5
#define WICK_BUFFER_ATR    0.25
#define WICK_MIN_ATR       0.5
#define LINE_FORWARD_BARS  20
#define LINE_UPDATE_BARS   8
#define LABEL_OFFSET_BARS  1
#define BE_DIM_TRANSP      70
#define FORM_LEN           10
#define GAUGE_WIDTH        8
#define STATS_PRUNE_DAYS   31
#define HTF_EMA_LEN        50
#define SHORT_NAME         "RLM"
#define INDICATOR_VERSION  "v1.0.2"

//============================ INPUTS ================================
enum ENUM_FSIZE   { FS_TINY=0, FS_SMALL=1, FS_NORMAL=2, FS_LARGE=3, FS_HUGE=4 };
enum ENUM_DFSIZE  { DF_SMALL=1, DF_NORMAL=2, DF_LARGE=3, DF_HUGE=4 };
enum ENUM_PRESET  { RP_CONSERVATIVE=0, RP_BALANCED=1, RP_AGGRESSIVE=2, RP_SCALPING=3, RP_CUSTOM=4 };
enum ENUM_SLMODE  { SL_WICK=0, SL_ATR=1 };
enum ENUM_LSTYLE  { LS_SOLID=0, LS_DASHED=1, LS_DOTTED=2 };
enum ENUM_DPOS    { DP_TOP_LEFT=0, DP_TOP_RIGHT=1, DP_BOTTOM_LEFT=2, DP_BOTTOM_RIGHT=3, DP_MIDDLE_RIGHT=4 };
enum ENUM_SPERIOD { SP_24H=0, SP_30D=1, SP_ALL=2 };

input group "Main Settings"
input int            InpSwingLen     = 6;      // Swing Length (2-30)
input double         InpLevelTol     = 0.6;    // Level Tolerance (x ATR)
input int            InpMinTouches   = 2;      // Touches to Activate
input int            InpHalfLife     = 500;    // Level Half-Life (bars)
input int            InpLevelsSide   = 3;      // Levels Above / Below Price
input ENUM_TIMEFRAMES InpHtfTF       = PERIOD_CURRENT; // HTF Bias Timeframe (current = off)

input group "Visual Settings"
input bool           InpShowLevels   = true;     // Show Levels
input bool           InpDrawFromFirst= true;     // Draw Levels From First Touch
input bool           InpShowLvlLabels= true;     // Show Level Score
input int            InpZoneTransp   = 0;        // Level Transparency (0 = Auto, 60-95)
input bool           InpShowSignals  = true;     // Show Buy/Sell Labels
input ENUM_FSIZE     InpSignalFont   = FS_SMALL; // Signal Label Size
input ENUM_FSIZE     InpLabelFont    = FS_SMALL; // SL/TP Label Font Size
input ENUM_FSIZE     InpLevelFont    = FS_SMALL; // Level Label Size

input group "Filters"
input int            InpMinScore     = 50;     // Min Level Score for Signals (0-100)
input double         InpRejectClv    = 0.6;    // Rejection Close Strength (0.5-0.9)
input int            InpCooldown     = 10;     // Cooldown per Level (bars)

input group "Support & More"
input string         InpInfoTelegram = "https://t.me/algotoolbox";  // Telegram
input string         InpInfoHomepage = "https://algotoolbox.com";   // Homepage

input group "Risk Management"
input ENUM_PRESET    InpPreset       = RP_BALANCED; // Risk Preset
input ENUM_SLMODE    InpSlMode       = SL_WICK;     // SL Mode
input int            InpAtrLenRisk   = 14;          // ATR Length (Risk)
input double         InpSlMult       = 1.5;         // SL Multiplier (x ATR) - Custom
input double         InpTp1Mult      = 1.0;         // TP1 Multiplier (x Risk) - Custom
input double         InpTp2Mult      = 2.0;         // TP2 Multiplier (x Risk) - Custom
input double         InpTp3Mult      = 3.0;         // TP3 Multiplier (x Risk) - Custom
input bool           InpBE           = true;        // Break-Even After TP1
input double         InpBeOffset     = 0.0;         // BE Offset (x ATR)
input bool           InpShowSlTp     = true;        // Show SL/TP Lines
input bool           InpShowSlTpLbl  = true;        // Show SL/TP Labels
input bool           InpShowPct      = true;        // Show % Distance on Labels
input ENUM_LSTYLE    InpEntryStyle   = LS_DOTTED;   // Entry Line Style
input ENUM_LSTYLE    InpSlStyle      = LS_SOLID;    // SL Line Style
input ENUM_LSTYLE    InpTpStyle      = LS_DASHED;   // TP Line Style

input group "Dashboard"
input bool           InpShowDash     = true;         // Show Dashboard (top-left, dark)
// fixed dashboard settings (hard-coded)
#define InpDashPos    DP_TOP_LEFT
#define InpDashFont   DF_SMALL
#define InpSecMarket  true
#define InpSecLevels  true
#define InpSecTrade   true
#define InpSecStats   true
#define InpStatsPeriod SP_ALL

input group "Alerts (MT5 Alert())"
input bool           InpAlertsOn     = false;  // Enable alerts
input bool           InpWebhookJson  = false;  // Entry alert as JSON text
input bool           InpAlertBreak   = true;   // Alert on Level Breaks
input bool           InpAlertSlRev   = true;   // Alert on SL Hit & Reversal
input bool           InpAlertTpBe    = true;   // Alert on TP & Break-Even

input group "Colors"
input color          InpBullColor    = C'0,230,118';   // Buy       #00E676
input color          InpBearColor    = C'255,82,82';   // Sell      #FF5252
input color          InpSupColor     = C'8,153,129';   // Support Level    #089981
input color          InpResColor     = C'242,54,69';   // Resistance Level #F23645

input group "Misc"
input int            InpMaxSigMarks  = 300;    // Max entry labels kept on chart

//============================ BUFFERS ===============================
double BufLongEntry[],BufShortEntry[],BufLongSig[],BufShortSig[],BufSL[],BufTP1[];

//============================ THEME =================================
bool  gDark=true; color gBg=clrBlack;
color TEXT_COLOR,TEXT_MUTED,TEXT_BRIGHT,BULL_TEXT,BEAR_TEXT,NEUTRAL_TEXT,BULL_LABEL_TEXT,BEAR_LABEL_TEXT;
color TABLE_BG,TABLE_BORDER,TABLE_ROW_ALT,HEADER_BG,HEADER_BG_BULL,HEADER_BG_BEAR,HEADER_TEXT,LINE_SUBTLE,WM_COLOR;
color SL_COLOR,TP1_COLOR,TP2_COLOR,TP3_COLOR,ENTRY_COLOR,TP_LABEL_COLOR,TP_HIT_COLOR,BE_COLOR,LABEL_TEXT;
int   ZONE_TRANSP=88;

color RGB(const int r,const int g,const int b){ return((color)(r|(g<<8)|(b<<16))); }
color Blend(const color c,const int transp)
  {
   double t=MathMax(0,MathMin(100,transp))/100.0;
   int r=(int)MathRound(((c)&0xFF)*(1-t)+((gBg)&0xFF)*t);
   int g=(int)MathRound(((c>>8)&0xFF)*(1-t)+((gBg>>8)&0xFF)*t);
   int b=(int)MathRound(((c>>16)&0xFF)*(1-t)+((gBg>>16)&0xFF)*t);
   return(RGB(r,g,b));
  }
void SetupTheme()
  {
   gBg=(color)ChartGetInteger(0,CHART_COLOR_BACKGROUND);
   gDark=true;   // dark theme only
   TEXT_COLOR  =gDark ? RGB(0xE0,0xE0,0xE0) : RGB(0x1A,0x1A,0x1A);
   TEXT_MUTED  =gDark ? RGB(0x9E,0x9E,0x9E) : RGB(0x75,0x75,0x75);
   TEXT_BRIGHT =gDark ? clrWhite : clrBlack;
   BULL_TEXT   =gDark ? RGB(0x00,0xE6,0x76) : RGB(0x00,0xA1,0x52);
   BEAR_TEXT   =gDark ? RGB(0xFF,0x52,0x52) : RGB(0xD3,0x2F,0x2F);
   NEUTRAL_TEXT=gDark ? RGB(0xFF,0xEB,0x3B) : RGB(0xF5,0x7F,0x17);
   BULL_LABEL_TEXT=RGB(0x00,0x4D,0x25); BEAR_LABEL_TEXT=clrWhite;
   TABLE_BG    =Blend(gDark ? RGB(0x13,0x17,0x22) : clrWhite,5);
   TABLE_BORDER=gDark ? RGB(0x2A,0x2E,0x39) : RGB(0xD0,0xD0,0xD0);
   TABLE_ROW_ALT=gDark ? RGB(0x1C,0x20,0x30) : RGB(0xF0,0xF4,0xF8);
   HEADER_BG   =gDark ? RGB(0x0D,0x47,0xA1) : RGB(0x15,0x65,0xC0);
   HEADER_BG_BULL=RGB(0x0F,0x6E,0x56); HEADER_BG_BEAR=RGB(0xA3,0x2D,0x2D); HEADER_TEXT=clrWhite;
   LINE_SUBTLE =gDark ? RGB(0x66,0x66,0x66) : RGB(0x99,0x99,0x99);
   WM_COLOR    =Blend(gDark ? clrWhite : clrBlack,80);
   SL_COLOR    =gDark ? RGB(0xE5,0x73,0x73) : RGB(0xB7,0x1C,0x1C);
   TP1_COLOR   =Blend(gDark ? RGB(0x66,0xBB,0x6A) : RGB(0x38,0x8E,0x3C),30);
   TP2_COLOR   =Blend(gDark ? RGB(0x66,0xBB,0x6A) : RGB(0x38,0x8E,0x3C),40);
   TP3_COLOR   =gDark ? RGB(0x66,0xBB,0x6A) : RGB(0x38,0x8E,0x3C);
   ENTRY_COLOR =gDark ? RGB(0x5C,0x8A,0xAE) : RGB(0x34,0x49,0x5E);
   TP_LABEL_COLOR=gDark ? RGB(0x66,0xBB,0x6A) : RGB(0x38,0x8E,0x3C);
   TP_HIT_COLOR=gDark ? RGB(0x4D,0xB6,0xAC) : RGB(0x00,0x69,0x5C);
   BE_COLOR    =gDark ? RGB(0xFF,0xA7,0x26) : RGB(0xE6,0x51,0x00);
   LABEL_TEXT  =gDark ? RGB(0x1A,0x1A,0x1A) : clrWhite;
   int fillT=gDark ? 88 : 82;
   ZONE_TRANSP=(InpZoneTransp==0) ? fillT : (int)MathMax(60,MathMin(95,InpZoneTransp));
  }

//============================ STATE =================================
struct Level
  {
   double lo,hi,mid,sumW,sumWP,sumWP2,strength;
   int touches,highTouches,lowTouches;
   datetime firstTime; int firstBar; datetime activeTime; int lastTouchBar;
   int crosses,side,sideBar,lastSignalBar; bool shown;
  };
Level    gLv[];
int      gSelRes[],gSelSup[];          // indices into gLv (nearest first)
int      gTrendDir=0,gTrendStartBar=-1,gLastBreakDir=0,gLastBreakBar=-1; double gLastBreakLvl=0;
string   gLastSigType=""; double gLastSigScore=0; int gLastSigBar=-1;
//--- trade engine
int      gActiveDir=0,gEntryBar=-1; double gEntry=0,gSL=0,gTP1=0,gTP2=0,gTP3=0,gEntryAtr=0;
bool     gTp1R=false,gTp2R=false,gTp3R=false,gBeActive=false;
int      gWins=0,gLosses=0; string gForm=""; datetime gTradeTimes[]; bool gTradeWins[];
//--- last trade drawing record (persists after close until next entry)
struct TradeDraw { bool valid; int dir; int bar; int x2; double entry,sl,tp1,tp2,tp3; bool h1,h2,h3,be; bool active; };
TradeDraw gTD;
//--- entry marks
struct SigMark { datetime t; double price; int dir; string tip; int id; };
SigMark  gMarks[]; int gMarkSeq=0;
//--- effective risk multipliers
double   gSlMult=1.5,gTp1m=1.0,gTp2m=2.0,gTp3m=3.0;
//--- processing
int      gProcessed=0; datetime gProcessedTime=0; int gArr=0;
double   gStructAtr[],gRiskAtr[],gTR[];
double   gDecay=1.0; int gWarmup=34;
string   gPrefix; bool gHeadless=false;
int      gHtfHandle=INVALID_HANDLE; bool gHtfOn=false; datetime gHtfBarT=0; int gHtfBias=0;
int      gLastProcessedBar=-1;
//--- dashboard
#define DMAX 40
int    gDashRows=0, gDashW=0, gDashH=0;
int    dType[DMAX]; string dL[DMAX]; string dR[DMAX]; color dCol[DMAX]; color dBg[DMAX]; bool dZebra[DMAX];
string cT[DMAX*3]; color cC[DMAX*3]; color cB[DMAX*3];     // change-detection caches (left,right,bg)

//============================ HELPERS ===============================
int  FontPx(const ENUM_FSIZE s){ return(s==FS_TINY ? 7 : (s==FS_SMALL ? 8 : (s==FS_NORMAL ? 10 : (s==FS_LARGE ? 12 : 14)))); }
int  DashFs(){ return(InpDashFont==DF_SMALL ? 8 : (InpDashFont==DF_NORMAL ? 10 : (InpDashFont==DF_LARGE ? 12 : 14))); }
int  DashFsSub(){ return(InpDashFont==DF_SMALL ? 7 : (InpDashFont==DF_NORMAL ? 8 : (InpDashFont==DF_LARGE ? 10 : 12))); }
ENUM_LINE_STYLE LStyle(const ENUM_LSTYLE s){ return(s==LS_DASHED ? STYLE_DASH : (s==LS_DOTTED ? STYLE_DOT : STYLE_SOLID)); }
string Px(const double v){ return(DoubleToString(v,_Digits)); }
string F1(const double v){ return(DoubleToString(v,1)); }
string F2(const double v){ return(DoubleToString(v,2)); }
string Score(const double s){ return(IntegerToString((int)MathRound(s))); }
string SignedPct(const double p){ return((p>=0 ? "+" : "")+F2(p)+"%"); }
string PctFromEntry(const double lvl,const double entry)
  {
   if(!InpShowPct || entry==0) return("");
   double pct=(lvl-entry)/entry*100.0;
   return(" ("+(pct>=0 ? "+" : "")+F2(pct)+"%)");
  }
string Gauge(const double v,const double mx,const int w)
  {
   string r=""; int filled=(mx<=0) ? 0 : (int)MathRound(MathMin(w,MathMax(0.0,v/mx*w)));
   for(int i=0;i<w;i++) r+=(i<filled ? "#" : "-");
   return(r);
  }
datetime TimeAtBar(const int idx,const datetime &time[],const int n)
  {
   if(idx<0) return(time[0]);
   if(idx<n) return(time[idx]);
   return((datetime)(time[n-1]+(idx-n+1)*PeriodSeconds(_Period)));
  }
void DelObj(const string nm){ if(ObjectFind(0,nm)>=0) ObjectDelete(0,nm); }
void ObjCommon(const string nm,const bool back)
  {
   ObjectSetInteger(0,nm,OBJPROP_SELECTABLE,false); ObjectSetInteger(0,nm,OBJPROP_SELECTED,false);
   ObjectSetInteger(0,nm,OBJPROP_HIDDEN,true); ObjectSetInteger(0,nm,OBJPROP_BACK,back);
  }
void PutRect(const string nm,const datetime t1,const double p1,const datetime t2,const double p2,const color c,const bool fill)
  {
   if(ObjectFind(0,nm)<0){ ObjectCreate(0,nm,OBJ_RECTANGLE,0,t1,p1,t2,p2); ObjCommon(nm,true); }
   ObjectSetInteger(0,nm,OBJPROP_TIME,0,t1); ObjectSetDouble(0,nm,OBJPROP_PRICE,0,p1);
   ObjectSetInteger(0,nm,OBJPROP_TIME,1,t2); ObjectSetDouble(0,nm,OBJPROP_PRICE,1,p2);
   ObjectSetInteger(0,nm,OBJPROP_COLOR,c); ObjectSetInteger(0,nm,OBJPROP_FILL,fill); ObjectSetInteger(0,nm,OBJPROP_WIDTH,1);
  }
void PutLine(const string nm,const datetime t1,const datetime t2,const double p,const color c,const int w,const ENUM_LINE_STYLE st)
  {
   if(ObjectFind(0,nm)<0){ ObjectCreate(0,nm,OBJ_TREND,0,t1,p,t2,p); ObjectSetInteger(0,nm,OBJPROP_RAY_RIGHT,false); ObjCommon(nm,true); }
   ObjectSetInteger(0,nm,OBJPROP_TIME,0,t1); ObjectSetDouble(0,nm,OBJPROP_PRICE,0,p);
   ObjectSetInteger(0,nm,OBJPROP_TIME,1,t2); ObjectSetDouble(0,nm,OBJPROP_PRICE,1,p);
   ObjectSetInteger(0,nm,OBJPROP_COLOR,c); ObjectSetInteger(0,nm,OBJPROP_WIDTH,w); ObjectSetInteger(0,nm,OBJPROP_STYLE,st);
  }
void PutText(const string nm,const datetime t,const double p,const string txt,const color c,const int fs,const ENUM_ANCHOR_POINT a,const bool bold=false,const string tip="")
  {
   if(ObjectFind(0,nm)<0){ ObjectCreate(0,nm,OBJ_TEXT,0,t,p); ObjCommon(nm,false); }
   ObjectSetString(0,nm,OBJPROP_FONT,bold ? "Arial Black" : "Arial");
   ObjectSetInteger(0,nm,OBJPROP_TIME,0,t); ObjectSetDouble(0,nm,OBJPROP_PRICE,0,p);
   ObjectSetString(0,nm,OBJPROP_TEXT,txt); ObjectSetInteger(0,nm,OBJPROP_COLOR,c);
   ObjectSetInteger(0,nm,OBJPROP_FONTSIZE,fs); ObjectSetInteger(0,nm,OBJPROP_ANCHOR,a);
   if(tip!="") ObjectSetString(0,nm,OBJPROP_TOOLTIP,tip);
  }

//============================ HTF BIAS ==============================
int HtfBiasAt(const datetime t)
  {
   if(!gHtfOn || gHtfHandle==INVALID_HANDLE) return(0);
   int k=iBarShift(_Symbol,InpHtfTF,t,false); if(k<0) return(0);
   datetime bt=iTime(_Symbol,InpHtfTF,k);
   if(bt==gHtfBarT) return(gHtfBias);
   double e[]; if(CopyBuffer(gHtfHandle,0,k+1,1,e)<1) return(0);
   double c=iClose(_Symbol,InpHtfTF,k+1);
   if(c<=0 || e[0]<=0) return(0);
   gHtfBarT=bt; gHtfBias=(c>e[0] ? 1 : -1);
   return(gHtfBias);
  }

//============================ LEVEL MATH ============================
bool   IsPolar(const Level &lv){ return(lv.highTouches>0 && lv.lowTouches>0); }
double LevelScore(const Level &lv){ double s=lv.strength*(IsPolar(lv) ? POLARITY_BONUS : 1.0); return(100.0*(1.0-MathExp(-s/SCORE_SCALE))); }
string LevelLabel(const Level &lv){ return(Score(LevelScore(lv))+" - "+IntegerToString(lv.touches)+"T"+(IsPolar(lv) ? " S/R" : "")); }
string LevelTooltip(const Level &lv)
  {
   return("Score "+Score(LevelScore(lv))+"/100\nTouches: "+IntegerToString(lv.touches)+" ("+IntegerToString(lv.highTouches)+" highs, "+IntegerToString(lv.lowTouches)+" lows)\nCrossed: "+IntegerToString(lv.crosses)+"x\nBand: "+Px(lv.lo)+" - "+Px(lv.hi)+"\nFirst touch: "+TimeToString(lv.firstTime,TIME_DATE|TIME_MINUTES));
  }
string LevelTag(const Level &lv){ return(LevelLabel(lv)+" @ "+Px(lv.mid)); }
string LevelDashStr(const Level &lv,const double close){ return(Px(lv.mid)+" ("+SignedPct(close!=0 ? (lv.mid-close)/close*100.0 : 0)+") - "+Score(LevelScore(lv))); }

void RefitBand(Level &lv,const double a)
  {
   double m=(lv.sumW!=0) ? lv.sumWP/lv.sumW : lv.mid;
   double vr=(lv.sumW!=0) ? lv.sumWP2/lv.sumW-m*m : 0;
   double hw=MathMin(MathMax(MathSqrt(MathMax(vr,0.0)),a*MIN_HALF_WIDTH_ATR),a*InpLevelTol);
   lv.mid=m; lv.lo=m-hw; lv.hi=m+hw;
  }
void AddTouch(Level &lv,const double price,const double w,const bool isHigh,const double a,const int bar,const datetime t)
  {
   lv.sumW+=w; lv.sumWP+=w*price; lv.sumWP2+=w*price*price; lv.strength+=w; lv.touches++;
   if(isHigh) lv.highTouches++; else lv.lowTouches++;
   lv.lastTouchBar=bar;
   if(lv.activeTime==0 && lv.touches>=InpMinTouches) lv.activeTime=t;
   RefitBand(lv,a);
  }
void NewLevel(Level &lv,const double price,const double w,const bool isHigh,const int pBar,const datetime pTime,const double a,const int bar,const datetime t,const double close)
  {
   lv.mid=price; lv.lo=price; lv.hi=price; lv.sumW=0; lv.sumWP=0; lv.sumWP2=0; lv.strength=0;
   lv.touches=0; lv.highTouches=0; lv.lowTouches=0; lv.firstTime=pTime; lv.firstBar=pBar; lv.activeTime=0;
   lv.lastTouchBar=pBar; lv.crosses=0; lv.side=(close>price ? 1 : -1); lv.sideBar=bar; lv.lastSignalBar=-1; lv.shown=false;
   AddTouch(lv,price,w,isHigh,a,bar,t);
  }
void MergeLevels(Level &t,const Level &o,const double a,const datetime now)
  {
   t.sumW+=o.sumW; t.sumWP+=o.sumWP; t.sumWP2+=o.sumWP2; t.strength+=o.strength; t.touches+=o.touches;
   t.highTouches+=o.highTouches; t.lowTouches+=o.lowTouches;
   t.firstTime=MathMin(t.firstTime,o.firstTime); t.firstBar=MathMin(t.firstBar,o.firstBar);
   t.lastTouchBar=MathMax(t.lastTouchBar,o.lastTouchBar); t.crosses=MathMax(t.crosses,o.crosses); t.shown=(t.shown||o.shown);
   if(o.activeTime!=0) t.activeTime=(t.activeTime==0) ? o.activeTime : MathMin(t.activeTime,o.activeTime);
   if(o.lastSignalBar>=0) t.lastSignalBar=(t.lastSignalBar<0) ? o.lastSignalBar : MathMax(t.lastSignalBar,o.lastSignalBar);
   if(t.activeTime==0 && t.touches>=InpMinTouches) t.activeTime=now;
   RefitBand(t,a);
  }
void RegisterSwing(const double price,const double w,const bool isHigh,const int pBar,const datetime pTime,const double a,const int bar,const datetime t,const double close)
  {
   double tol=a*InpLevelTol; int tIdx=-1; double bestD=tol; int n=ArraySize(gLv);
   for(int i=0;i<n;i++){ double d=MathAbs(gLv[i].mid-price); if(d<=bestD){ bestD=d; tIdx=i; } }
   if(tIdx>=0)
     {
      AddTouch(gLv[tIdx],price,w,isHigh,a,bar,t);
      bool again=true; int passes=0;
      while(again && passes<MERGE_PASSES)
        {
         again=false; passes++;
         for(int k=ArraySize(gLv)-1;k>=0;k--)
           {
            if(k==tIdx) continue;
            if(gLv[k].lo<=gLv[tIdx].hi && gLv[tIdx].lo<=gLv[k].hi)
              {
               MergeLevels(gLv[tIdx],gLv[k],a,t);
               ArrayRemove(gLv,k,1);
               if(k<tIdx) tIdx--;
               again=true;
              }
           }
        }
     }
   else
     {
      int k=ArraySize(gLv); ArrayResize(gLv,k+1);
      NewLevel(gLv[k],price,w,isHigh,pBar,pTime,a,bar,t,close);
     }
   while(ArraySize(gLv)>MAX_LEVELS)
     {
      int weak=0; double ws=gLv[0].strength;
      for(int j=1;j<ArraySize(gLv);j++) if(gLv[j].strength<ws){ ws=gLv[j].strength; weak=j; }
      ArrayRemove(gLv,weak,1);
     }
  }
// returns crosses of shown levels: nUp,lvlUp,nDn,lvlDn
void AgeAndCross(const double close,const int bar,int &nUp,double &lvlUp,int &nDn,double &lvlDn)
  {
   nUp=0; nDn=0; lvlUp=0; lvlDn=0;
   for(int k=ArraySize(gLv)-1;k>=0;k--)
     {
      gLv[k].strength*=gDecay;
      int newSide=(close>gLv[k].hi) ? 1 : (close<gLv[k].lo ? -1 : gLv[k].side);
      if(newSide!=gLv[k].side)
        {
         if(gLv[k].touches>=InpMinTouches)
           {
            gLv[k].crosses++; gLv[k].strength*=CROSS_PENALTY;
            if(gLv[k].shown && newSide==1){ nUp++; lvlUp=gLv[k].mid; }
            if(gLv[k].shown && newSide==-1){ nDn++; lvlDn=gLv[k].mid; }
           }
         gLv[k].side=newSide; gLv[k].sideBar=bar;
        }
      if(gLv[k].strength<MIN_STRENGTH) ArrayRemove(gLv,k,1);
     }
  }
void SelectNearest(const double close,const int sideWanted,const int n,int &out[])
  {
   ArrayResize(out,0); int m=ArraySize(gLv); if(m==0) return;
   bool used[]; ArrayResize(used,m); for(int u=0;u<m;u++) used[u]=false;
   for(int k=0;k<n;k++)
     {
      int best=-1; double bestD=0;
      for(int i=0;i<m;i++)
        {
         if(used[i] || gLv[i].touches<InpMinTouches || gLv[i].side!=sideWanted) continue;
         double d=MathAbs(close-gLv[i].mid);
         if(best<0 || d<bestD){ bestD=d; best=i; }
        }
      if(best<0) break;
      used[best]=true; gLv[best].shown=true;
      int s=ArraySize(out); ArrayResize(out,s+1); out[s]=best;
     }
  }

//============================ DRAW: LEVELS ==========================
void DeleteLevelDrawings(){ ObjectsDeleteAll(0,gPrefix+"L_",0,-1); }
void DrawLevelSet(const int &sel[],const color base,const string tag,const datetime lastT)
  {
   datetime rightT=(datetime)(lastT+LEVEL_RIGHT_EXT*PeriodSeconds(_Period));
   int fs=FontPx(InpLevelFont);
   for(int i=0;i<ArraySize(sel);i++)
     {
      Level lv=gLv[sel[i]];
      datetime leftT=InpDrawFromFirst ? lv.firstTime : (lv.activeTime!=0 ? lv.activeTime : lv.firstTime);
      string nm=gPrefix+"L_"+tag+IntegerToString(i);
      PutRect(nm+"B",leftT,lv.hi,rightT,lv.lo,Blend(base,ZONE_TRANSP),true);
      PutLine(nm+"M",leftT,rightT,lv.mid,Blend(base,35),1,STYLE_DOT);
      if(InpShowLvlLabels) PutText(nm+"T",rightT,lv.mid," "+LevelLabel(lv),base,fs,ANCHOR_LEFT,false,LevelTooltip(lv));
     }
  }
void RenderLevels(const datetime lastT)
  {
   if(gHeadless) return;
   DeleteLevelDrawings();
   if(!InpShowLevels) return;
   DrawLevelSet(gSelRes,InpResColor,"R",lastT);
   DrawLevelSet(gSelSup,InpSupColor,"S",lastT);
  }

//============================ DRAW: ENTRY MARKS =====================
void RenderMark(const SigMark &m)
  {
   if(gHeadless || !InpShowSignals) return;
   string nm=gPrefix+"S_"+IntegerToString(m.id);
   int fs=FontPx(InpSignalFont);
   if(m.dir==1) PutText(nm,m.t,m.price,"BUY",InpBullColor,fs,ANCHOR_UPPER,true,m.tip);
   else         PutText(nm,m.t,m.price,"SELL",InpBearColor,fs,ANCHOR_LOWER,true,m.tip);
  }
void AddMark(const datetime t,const double price,const int dir,const string tip,const bool bulk)
  {
   int k=ArraySize(gMarks); ArrayResize(gMarks,k+1);
   gMarks[k].t=t; gMarks[k].price=price; gMarks[k].dir=dir; gMarks[k].tip=tip; gMarks[k].id=++gMarkSeq;
   while(ArraySize(gMarks)>MathMax(1,InpMaxSigMarks)){ if(!bulk) DelObj(gPrefix+"S_"+IntegerToString(gMarks[0].id)); ArrayRemove(gMarks,0,1); }
   if(!bulk) RenderMark(gMarks[ArraySize(gMarks)-1]);
  }

//============================ DRAW: TRADE LINES =====================
void RenderTrade(const datetime &time[],const int n,const int lastBar)
  {
   if(gHeadless) return;
   string p=gPrefix+"T_";
   if(!gTD.valid || !InpShowSlTp){ ObjectsDeleteAll(0,p,0,-1); return; }
   if(gTD.active) gTD.x2=lastBar+LINE_UPDATE_BARS;      // open trade: lines end LINE_UPDATE_BARS after the current bar; frozen after close
   int x2=gTD.x2;
   datetime t1=TimeAtBar(gTD.bar,time,n), t2=TimeAtBar(x2,time,n), tl=TimeAtBar(x2+LABEL_OFFSET_BARS,time,n);
   int fs=FontPx(InpLabelFont);
   color slc=gTD.be ? Blend(SL_COLOR,BE_DIM_TRANSP) : SL_COLOR;
   PutLine(p+"EN",t1,t2,gTD.entry,ENTRY_COLOR,1,LStyle(InpEntryStyle));
   PutLine(p+"SL",t1,t2,gTD.sl,slc,2,LStyle(InpSlStyle));
   PutLine(p+"T1",t1,t2,gTD.tp1,gTD.h1 ? TP_HIT_COLOR : TP1_COLOR,1,gTD.h1 ? STYLE_SOLID : LStyle(InpTpStyle));
   PutLine(p+"T2",t1,t2,gTD.tp2,gTD.h2 ? TP_HIT_COLOR : TP2_COLOR,1,gTD.h2 ? STYLE_SOLID : LStyle(InpTpStyle));
   PutLine(p+"T3",t1,t2,gTD.tp3,gTD.h3 ? TP_HIT_COLOR : TP3_COLOR,1,gTD.h3 ? STYLE_SOLID : LStyle(InpTpStyle));
   if(InpShowSlTpLbl)
     {
      PutText(p+"LE",tl,gTD.entry,"ENTRY "+Px(gTD.entry)+(gTD.be ? "  -> SL (BE)" : ""),gTD.be ? BE_COLOR : ENTRY_COLOR,fs,ANCHOR_LEFT);
      PutText(p+"LS",tl,gTD.sl,"SL "+Px(gTD.sl)+PctFromEntry(gTD.sl,gTD.entry),gTD.be ? TEXT_COLOR : SL_COLOR,fs,ANCHOR_LEFT);
      PutText(p+"L1",tl,gTD.tp1,(gTD.h1 ? "TP1 (hit)" : "TP1"),gTD.h1 ? TP_HIT_COLOR : TP_LABEL_COLOR,fs,ANCHOR_LEFT);
      PutText(p+"L2",tl,gTD.tp2,(gTD.h2 ? "TP2 (hit)" : "TP2"),gTD.h2 ? TP_HIT_COLOR : TP_LABEL_COLOR,fs,ANCHOR_LEFT);
      PutText(p+"L3",tl,gTD.tp3,(gTD.h3 ? "TP3 (hit)" : "TP3"),gTD.h3 ? TP_HIT_COLOR : TP_LABEL_COLOR,fs,ANCHOR_LEFT);
     }
   else { DelObj(p+"LE"); DelObj(p+"LS"); DelObj(p+"L1"); DelObj(p+"L2"); DelObj(p+"L3"); }
  }

//============================ STATS =================================
void RecordTrade(const bool win,const datetime t)
  {
   if(win) gWins++; else gLosses++;
   gForm+=(win ? "#" : "-");
   if(StringLen(gForm)>FORM_LEN) gForm=StringSubstr(gForm,StringLen(gForm)-FORM_LEN);
   int k=ArraySize(gTradeTimes); ArrayResize(gTradeTimes,k+1); ArrayResize(gTradeWins,k+1); gTradeTimes[k]=t; gTradeWins[k]=win;
   while(ArraySize(gTradeTimes)>0 && gTradeTimes[0]<t-86400*STATS_PRUNE_DAYS){ ArrayRemove(gTradeTimes,0,1); ArrayRemove(gTradeWins,0,1); }
  }
void PeriodStats(const datetime cutoff,int &w,int &l)
  {
   w=0; l=0;
   for(int i=0;i<ArraySize(gTradeTimes);i++) if(gTradeTimes[i]>=cutoff){ if(gTradeWins[i]) w++; else l++; }
  }
void ResetTrade()
  {
   gActiveDir=0; gEntry=0; gSL=0; gTP1=0; gTP2=0; gTP3=0; gEntryBar=-1; gEntryAtr=0;
   gTp1R=false; gTp2R=false; gTp3R=false; gBeActive=false;
  }

//============================ RESET =================================
void ResetAll()
  {
   ArrayResize(gLv,0); ArrayResize(gSelRes,0); ArrayResize(gSelSup,0);
   gTrendDir=0; gTrendStartBar=-1; gLastBreakDir=0; gLastBreakBar=-1; gLastBreakLvl=0;
   gLastSigType=""; gLastSigScore=0; gLastSigBar=-1;
   ResetTrade(); gWins=0; gLosses=0; gForm=""; ArrayResize(gTradeTimes,0); ArrayResize(gTradeWins,0);
   gTD.valid=false; gTD.active=false; ArrayResize(gMarks,0); gMarkSeq=0;
   gProcessed=0; gProcessedTime=0; gHtfBarT=0; gHtfBias=0; gLastProcessedBar=-1;
   if(!gHeadless) ObjectsDeleteAll(0,gPrefix,-1,-1);
   gDashRows=0; gDashW=0;
  }

//============================ ENGINE (one confirmed bar) ============
void ProcessBar(const int i,const datetime &time[],const double &open[],const double &high[],const double &low[],const double &close[],const int n,const bool bulk)
  {
   int L=MathMax(2,InpSwingLen);
   double a=gStructAtr[i], riskAtr=gRiskAtr[i];
   bool atrOk=(a>0);
   bool warmed=(i>=gWarmup);
   //--- swings confirmed on this bar
   bool gotHigh=false,gotLow=false; double swHigh=0,swLow=0,wHigh=0,wLow=0;
   if(i>=2*L)
     {
      int c=i-L; double ph=high[c], pl=low[c]; bool okH=true, okL=true;
      for(int j=c-L;j<c && (okH||okL);j++){ if(high[j]>=ph) okH=false; if(low[j]<=pl) okL=false; }
      for(int j=c+1;j<=i && (okH||okL);j++){ if(high[j]>ph) okH=false; if(low[j]<pl) okL=false; }
      double lowestAfter=low[i], highestAfter=high[i];
      for(int j=i-L+1;j<=i;j++){ lowestAfter=MathMin(lowestAfter,low[j]); highestAfter=MathMax(highestAfter,high[j]); }
      double atrAtSwing=(gStructAtr[c]>0) ? gStructAtr[c] : a;
      if(okH){ gotHigh=true; swHigh=ph; wHigh=1.0+MathMin(atrAtSwing>0 ? (ph-lowestAfter)/atrAtSwing : 0.0,REACTION_CAP); }
      if(okL){ gotLow=true;  swLow=pl;  wLow =1.0+MathMin(atrAtSwing>0 ? (highestAfter-pl)/atrAtSwing : 0.0,REACTION_CAP); }
     }
   //--- level maintenance
   int upCrosses=0,dnCrosses=0; double upLevel=0,dnLevel=0;
   if(atrOk)
     {
      AgeAndCross(close[i],i,upCrosses,upLevel,dnCrosses,dnLevel);
      if(gotHigh) RegisterSwing(swHigh,wHigh,true, i-L,time[i-L],a,i,time[i],close[i]);
      if(gotLow)  RegisterSwing(swLow, wLow, false,i-L,time[i-L],a,i,time[i],close[i]);
     }
   //--- trend / last break
   int breakDir=(upCrosses>0 && dnCrosses==0) ? 1 : ((dnCrosses>0 && upCrosses==0) ? -1 : 0);
   if(breakDir!=0)
     {
      gLastBreakDir=breakDir; gLastBreakLvl=(breakDir==1 ? upLevel : dnLevel); gLastBreakBar=i;
      if(breakDir!=gTrendDir){ gTrendDir=breakDir; gTrendStartBar=i; }
     }
   //--- selection
   for(int k=0;k<ArraySize(gLv);k++) gLv[k].shown=false;
   SelectNearest(close[i],-1,InpLevelsSide,gSelRes);
   SelectNearest(close[i], 1,InpLevelsSide,gSelSup);
   //--- signals
   bool gate=warmed && atrOk;
   bool longHit=false,shortHit=false; double longScore=0,shortScore=0; string longInfo="",shortInfo="";
   double rng=high[i]-low[i];
   if(gate && ArraySize(gSelSup)>0)
     {
      double clv=(rng>0) ? (close[i]-low[i])/rng : 0.5;
      for(int s=0;s<ArraySize(gSelSup);s++)
        {
         int ix=gSelSup[s];
         bool approached=(gLv[ix].side==1 && gLv[ix].sideBar<i);
         bool touched=(low[i]<=gLv[ix].hi), held=(close[i]>gLv[ix].hi), strong=(clv>=InpRejectClv);
         bool scoreOk=(LevelScore(gLv[ix])>=InpMinScore);
         bool rested=(gLv[ix].lastSignalBar<0 || i-gLv[ix].lastSignalBar>=InpCooldown);
         if(approached && touched && held && strong && scoreOk && rested){ gLv[ix].lastSignalBar=i; longHit=true; longScore=LevelScore(gLv[ix]); longInfo=LevelTag(gLv[ix]); break; }
        }
     }
   if(gate && ArraySize(gSelRes)>0)
     {
      double clv=(rng>0) ? (high[i]-close[i])/rng : 0.5;
      for(int s=0;s<ArraySize(gSelRes);s++)
        {
         int ix=gSelRes[s];
         bool approached=(gLv[ix].side==-1 && gLv[ix].sideBar<i);
         bool touched=(high[i]>=gLv[ix].lo), held=(close[i]<gLv[ix].lo), strong=(clv>=InpRejectClv);
         bool scoreOk=(LevelScore(gLv[ix])>=InpMinScore);
         bool rested=(gLv[ix].lastSignalBar<0 || i-gLv[ix].lastSignalBar>=InpCooldown);
         if(approached && touched && held && strong && scoreOk && rested){ gLv[ix].lastSignalBar=i; shortHit=true; shortScore=LevelScore(gLv[ix]); shortInfo=LevelTag(gLv[ix]); break; }
        }
     }
   bool longSig=longHit, shortSig=(shortHit && !longHit);
   if(longSig){ gLastSigType="BUY"; gLastSigScore=longScore; gLastSigBar=i; }
   if(shortSig){ gLastSigType="SELL"; gLastSigScore=shortScore; gLastSigBar=i; }

   //--- trade engine
   double slDistance=riskAtr*gSlMult;
   bool beAtStart=gBeActive; double effSL=gSL;
   bool canHit=(gActiveDir!=0 && gEntryBar>=0 && i>gEntryBar);
   bool slHitRaw =canHit && (gActiveDir==1 ? low[i]<=effSL : high[i]>=effSL);
   bool tp1HitRaw=canHit && (gActiveDir==1 ? high[i]>=gTP1 : low[i]<=gTP1);
   bool tp2HitRaw=canHit && (gActiveDir==1 ? high[i]>=gTP2 : low[i]<=gTP2);
   bool tp3HitRaw=canHit && (gActiveDir==1 ? high[i]>=gTP3 : low[i]<=gTP3);
   bool tp1First=tp1HitRaw && !gTp1R, tp2First=tp2HitRaw && !gTp2R, tp3First=tp3HitRaw && !gTp3R;
   if(tp1First) gTp1R=true; if(tp2First) gTp2R=true; if(tp3First) gTp3R=true;
   bool beJust=false; double beLevel=0;
   if(InpBE && tp1First && !gBeActive && gActiveDir!=0){ gSL=gEntry+gActiveDir*InpBeOffset*gEntryAtr; gBeActive=true; beJust=true; beLevel=gSL; }
   double hitSL=effSL, hitEntry=gEntry;
   double exitEntry=gEntry,exitTP1=gTP1,exitTP2=gTP2,exitTP3=gTP3; int exitDir=gActiveDir; bool exitBe=beAtStart;
   // update drawing record with reached flags / BE
   if(gTD.valid && gTD.active){ gTD.h1=gTp1R; gTD.h2=gTp2R; gTD.h3=gTp3R; if(beJust){ gTD.be=true; gTD.sl=gSL; } }
   bool closeBySl=slHitRaw && !tp1First && !tp3First;
   bool evSlHit=closeBySl, evTp3=false;
   if((tp3HitRaw||closeBySl) && gActiveDir!=0)
     {
      evTp3=tp3HitRaw;
      RecordTrade(gTp1R,time[i]);
      ResetTrade(); gTD.active=false;
     }
   int sigDir=longSig ? 1 : (shortSig ? -1 : 0);
   bool evRev=false, revWin=false;
   if((sigDir==-1 && gActiveDir==1) || (sigDir==1 && gActiveDir==-1))
     {
      evRev=true; revWin=gTp1R; RecordTrade(gTp1R,time[i]); ResetTrade(); gTD.active=false;
     }
   bool evLong=false,evShort=false;
   if(longSig && gActiveDir==0 && slDistance>0)
     {
      double slAtr=close[i]-slDistance, slWick=MathMin(low[i]-riskAtr*WICK_BUFFER_ATR,close[i]-riskAtr*WICK_MIN_ATR);
      double sl=(InpSlMode==SL_ATR) ? slAtr : slWick, risk=close[i]-sl;
      if(risk>0){ gEntry=close[i]; gSL=sl; gTP1=close[i]+risk*gTp1m; gTP2=close[i]+risk*gTp2m; gTP3=close[i]+risk*gTp3m; gActiveDir=1; gEntryBar=i; gEntryAtr=riskAtr; gTp1R=false; gTp2R=false; gTp3R=false; gBeActive=false; evLong=true; }
     }
   if(shortSig && gActiveDir==0 && slDistance>0)
     {
      double slAtr=close[i]+slDistance, slWick=MathMax(high[i]+riskAtr*WICK_BUFFER_ATR,close[i]+riskAtr*WICK_MIN_ATR);
      double sl=(InpSlMode==SL_ATR) ? slAtr : slWick, risk=sl-close[i];
      if(risk>0){ gEntry=close[i]; gSL=sl; gTP1=close[i]-risk*gTp1m; gTP2=close[i]-risk*gTp2m; gTP3=close[i]-risk*gTp3m; gActiveDir=-1; gEntryBar=i; gEntryAtr=riskAtr; gTp1R=false; gTp2R=false; gTp3R=false; gBeActive=false; evShort=true; }
     }
   bool newEntry=evLong||evShort;
   if(newEntry)
     {
      gTD.valid=true; gTD.active=true; gTD.dir=gActiveDir; gTD.bar=i; gTD.entry=gEntry; gTD.sl=gSL; gTD.tp1=gTP1; gTD.tp2=gTP2; gTD.tp3=gTP3;
      gTD.h1=false; gTD.h2=false; gTD.h3=false; gTD.be=false; gTD.x2=i+LINE_UPDATE_BARS;
      string kind=evLong ? (evRev ? "BUY entry (reversal from SELL)" : "BUY entry - support rejection") : (evRev ? "SELL entry (reversal from BUY)" : "SELL entry - resistance rejection");
      string tip=kind+"\nScore: "+Score(evLong ? longScore : shortScore)+"/100\nLevel: "+(evLong ? longInfo : shortInfo)+"\nSL: "+Px(gSL)+" | TP1: "+Px(gTP1);
      AddMark(time[i],evLong ? low[i] : high[i],evLong ? 1 : -1,tip,bulk);
      if(!bulk) ObjectsDeleteAll(0,gPrefix+"T_",0,-1);   // replace the previous trade's lines
     }
   //--- buffers
   BufLongEntry[i]=evLong ? 1.0 : EMPTY_VALUE; BufShortEntry[i]=evShort ? 1.0 : EMPTY_VALUE;
   BufLongSig[i]=longSig ? 1.0 : EMPTY_VALUE;  BufShortSig[i]=shortSig ? 1.0 : EMPTY_VALUE;
   BufSL[i]=newEntry ? gSL : EMPTY_VALUE;      BufTP1[i]=newEntry ? gTP1 : EMPTY_VALUE;
   gLastProcessedBar=i;
   //--- alerts (confirmed bar, live only)
   if(!bulk && InpAlertsOn)
     {
      string tk=_Symbol, tf=EnumToString(_Period), ap=Px(close[i]);
      string exDir=(exitDir==1 ? "BUY" : (exitDir==-1 ? "SELL" : "-"));
      if(beJust && InpAlertTpBe)   Alert("BREAK-EVEN | ",tk," | TF: ",tf," | ",exDir," | SL moved to ",Px(beLevel));
      if(tp1First && InpAlertTpBe) Alert("TP1 HIT | ",tk," | TF: ",tf," | ",exDir," | TP1: ",Px(exitTP1));
      if(tp2First && InpAlertTpBe) Alert("TP2 HIT | ",tk," | TF: ",tf," | ",exDir," | TP2: ",Px(exitTP2));
      if(evTp3 && InpAlertTpBe)    Alert("TP3 HIT | ",tk," | TF: ",tf," | ",exDir," | Entry: ",Px(exitEntry)," | TP3: ",Px(exitTP3));
      if(evSlHit && InpAlertSlRev) Alert(exitBe ? "BE STOP-OUT | " : "SL HIT | ",tk," | TF: ",tf," | ",exDir," | Entry: ",Px(hitEntry)," | SL: ",Px(hitSL));
      if(evRev && InpAlertSlRev)   Alert("REVERSAL | ",tk," | TF: ",tf," | ",exDir," -> ",(exitDir==1 ? "SELL" : "BUY")," | ",(revWin ? "Closed after TP1 (win)" : "Closed before TP1 (loss)")," | Exit: ",ap);
      if(newEntry)
        {
         string sc=Score(evLong ? longScore : shortScore);
         if(InpWebhookJson) Alert("{\"action\":\"",(evLong ? "buy" : "sell"),"\",\"ticker\":\"",tk,"\",\"tf\":\"",tf,"\",\"price\":",ap,",\"score\":",sc,",\"sl\":",Px(gSL),",\"tp1\":",Px(gTP1),",\"tp2\":",Px(gTP2),",\"tp3\":",Px(gTP3),",\"rr\":",F1(gTp1m),"}");
         else Alert((evLong ? "BUY | " : "SELL | "),tk," | TF: ",tf," | Price: ",ap," | Score: ",sc,"/100 | SL: ",Px(gSL)," | TP1: ",Px(gTP1)," | TP2: ",Px(gTP2)," | TP3: ",Px(gTP3)," | R:R: ",F1(gTp1m));
        }
      if(InpAlertBreak && upCrosses>0 && !evLong) Alert("LEVEL BROKEN UP | ",tk," | TF: ",tf," | Level: ",Px(upLevel)," | Price: ",ap," | Now support");
      if(InpAlertBreak && dnCrosses>0 && !evShort) Alert("LEVEL BROKEN DOWN | ",tk," | TF: ",tf," | Level: ",Px(dnLevel)," | Price: ",ap," | Now resistance");
     }
  }

//============================ DASHBOARD =============================
// row types: 0 header, 1 divider, 2 label/value, 3 merged text, 4 footer
int TextW(const string txt,const int fs,const bool bold=false){ TextSetFont(bold ? "Arial Black" : "Arial",-fs*10); uint tw=0,th=0; TextGetSize(txt,tw,th); return((int)tw); }
int TextH(const int fs){ TextSetFont("Arial",-fs*10); uint tw=0,th=0; TextGetSize("Ag",tw,th); return((int)th); }
string DN(const int r,const string s){ return(gPrefix+"D_"+IntegerToString(r)+s); }
void DashClear(){ ObjectsDeleteAll(0,gPrefix+"D_",0,-1); gDashRows=0; gDashW=0; }
int  AddRow(int r,const int type,const string l,const string rt,const color c,const bool zebra)
  {
   if(r>=DMAX) return(r);
   dType[r]=type; dL[r]=l; dR[r]=rt; dCol[r]=c; dZebra[r]=zebra; return(r+1);
  }
void DashBuild(const int rows,const int w)
  {
   DashClear();
   int fs=DashFs(), fsSub=DashFsSub(), pad=6;
   int rowH=TextH(fs)+6, subH=TextH(fsSub)+4;
   int h=0; for(int r=0;r<rows;r++) h+=((dType[r]==1||dType[r]==4) ? subH : rowH);
   ENUM_BASE_CORNER corner=CORNER_RIGHT_UPPER; int x0=8,y0=8;
   if(InpDashPos==DP_TOP_LEFT) corner=CORNER_LEFT_UPPER;
   if(InpDashPos==DP_BOTTOM_LEFT) corner=CORNER_LEFT_LOWER;
   if(InpDashPos==DP_BOTTOM_RIGHT) corner=CORNER_RIGHT_LOWER;
   if(InpDashPos==DP_MIDDLE_RIGHT){ long ch=ChartGetInteger(0,CHART_HEIGHT_IN_PIXELS); y0=(int)MathMax(8,ch/2-h/2); }
   bool right=(corner==CORNER_RIGHT_UPPER||corner==CORNER_RIGHT_LOWER);
   bool lower=(corner==CORNER_LEFT_LOWER||corner==CORNER_RIGHT_LOWER);
   // frame
   string fr=DN(-1,"F");
   ObjectCreate(0,fr,OBJ_RECTANGLE_LABEL,0,0,0); ObjectSetInteger(0,fr,OBJPROP_CORNER,corner);
   ObjectSetInteger(0,fr,OBJPROP_XDISTANCE,x0-1); ObjectSetInteger(0,fr,OBJPROP_YDISTANCE,y0-1);
   ObjectSetInteger(0,fr,OBJPROP_XSIZE,w+2); ObjectSetInteger(0,fr,OBJPROP_YSIZE,h+2);
   ObjectSetInteger(0,fr,OBJPROP_BGCOLOR,TABLE_BORDER); ObjectSetInteger(0,fr,OBJPROP_COLOR,TABLE_BORDER); ObjectSetInteger(0,fr,OBJPROP_BORDER_TYPE,BORDER_FLAT);
   ObjectSetInteger(0,fr,OBJPROP_ZORDER,99); ObjCommon(fr,false);
   int y=0;
   for(int r=0;r<rows;r++)
     {
      bool small=(dType[r]==1||dType[r]==4); int rh=small ? subH : rowH; int f=small ? fsSub : fs;
      int yd=lower ? y0+(h-y-rh) : y0+y;
      string bg=DN(r,"B");
      ObjectCreate(0,bg,OBJ_RECTANGLE_LABEL,0,0,0); ObjectSetInteger(0,bg,OBJPROP_CORNER,corner);
      ObjectSetInteger(0,bg,OBJPROP_XDISTANCE,x0); ObjectSetInteger(0,bg,OBJPROP_YDISTANCE,yd);
      ObjectSetInteger(0,bg,OBJPROP_XSIZE,w); ObjectSetInteger(0,bg,OBJPROP_YSIZE,rh);
      ObjectSetInteger(0,bg,OBJPROP_BORDER_TYPE,BORDER_FLAT); ObjectSetInteger(0,bg,OBJPROP_ZORDER,100); ObjCommon(bg,false);
      // left / centered label
      string ln=DN(r,"L");
      ObjectCreate(0,ln,OBJ_LABEL,0,0,0); ObjectSetInteger(0,ln,OBJPROP_CORNER,corner);
      ObjectSetString(0,ln,OBJPROP_FONT,"Arial"); ObjectSetInteger(0,ln,OBJPROP_FONTSIZE,f); ObjectSetInteger(0,ln,OBJPROP_ZORDER,101); ObjCommon(ln,false);
      if(dType[r]==2)
        {
         // left column: its LEFT edge sits pad px inside the panel (distance measured from the corner)
         ObjectSetInteger(0,ln,OBJPROP_ANCHOR,lower ? ANCHOR_LEFT_LOWER : ANCHOR_LEFT_UPPER);
         ObjectSetInteger(0,ln,OBJPROP_XDISTANCE,right ? x0+w-pad : x0+pad);
         ObjectSetInteger(0,ln,OBJPROP_YDISTANCE,lower ? yd+rh-3 : yd+3);
         string rn=DN(r,"R");
         ObjectCreate(0,rn,OBJ_LABEL,0,0,0); ObjectSetInteger(0,rn,OBJPROP_CORNER,corner);
         ObjectSetString(0,rn,OBJPROP_FONT,"Arial"); ObjectSetInteger(0,rn,OBJPROP_FONTSIZE,f); ObjectSetInteger(0,rn,OBJPROP_ZORDER,101); ObjCommon(rn,false);
         // right column: its RIGHT edge sits pad px inside the panel
         ObjectSetInteger(0,rn,OBJPROP_ANCHOR,lower ? ANCHOR_RIGHT_LOWER : ANCHOR_RIGHT_UPPER);
         ObjectSetInteger(0,rn,OBJPROP_XDISTANCE,right ? x0+pad : x0+w-pad);
         ObjectSetInteger(0,rn,OBJPROP_YDISTANCE,lower ? yd+rh-3 : yd+3);
        }
      else
        {
         ObjectSetInteger(0,ln,OBJPROP_ANCHOR,lower ? ANCHOR_LOWER : ANCHOR_UPPER);
         ObjectSetInteger(0,ln,OBJPROP_XDISTANCE,x0+w/2);
         ObjectSetInteger(0,ln,OBJPROP_YDISTANCE,lower ? yd+rh-2 : yd+2);
        }
      y+=rh;
     }
   for(int k=0;k<DMAX*3;k++){ cT[k]=""; cC[k]=clrNONE; cB[k]=clrNONE; }
   // brand box under the dashboard (full width, gold text, left aligned)
   int bh=TextH(fsSub)+8;
   int by=lower ? y0+h+4+bh : y0+h+4;
   string bb=DN(-2,"F"), bl=DN(-2,"L");
   ObjectCreate(0,bb,OBJ_RECTANGLE_LABEL,0,0,0); ObjectSetInteger(0,bb,OBJPROP_CORNER,corner);
   ObjectSetInteger(0,bb,OBJPROP_XDISTANCE,x0-1); ObjectSetInteger(0,bb,OBJPROP_YDISTANCE,(lower ? y0+h+4+bh+1 : by-1));
   ObjectSetInteger(0,bb,OBJPROP_XSIZE,w+2); ObjectSetInteger(0,bb,OBJPROP_YSIZE,bh+2);
   ObjectSetInteger(0,bb,OBJPROP_BGCOLOR,TABLE_BG); ObjectSetInteger(0,bb,OBJPROP_COLOR,TABLE_BORDER); ObjectSetInteger(0,bb,OBJPROP_BORDER_TYPE,BORDER_FLAT);
   ObjectSetInteger(0,bb,OBJPROP_ZORDER,99); ObjCommon(bb,false);
   ObjectCreate(0,bl,OBJ_LABEL,0,0,0); ObjectSetInteger(0,bl,OBJPROP_CORNER,corner);
   ObjectSetInteger(0,bl,OBJPROP_ANCHOR,lower ? ANCHOR_LEFT_LOWER : ANCHOR_LEFT_UPPER);
   ObjectSetInteger(0,bl,OBJPROP_XDISTANCE,right ? x0+w-pad : x0+pad); ObjectSetInteger(0,bl,OBJPROP_YDISTANCE,lower ? by-4 : by+4);
   ObjectSetString(0,bl,OBJPROP_FONT,"Arial"); ObjectSetInteger(0,bl,OBJPROP_FONTSIZE,fsSub);
   ObjectSetInteger(0,bl,OBJPROP_COLOR,C'255,200,60'); ObjectSetString(0,bl,OBJPROP_TEXT,"t.me/algotoolbox | algotoolbox.com");
   ObjectSetInteger(0,bl,OBJPROP_ZORDER,101); ObjCommon(bl,false);
   gDashRows=rows; gDashW=w; gDashH=h;
  }
void DashApply(const int rows)
  {
   for(int r=0;r<rows;r++)
     {
      string bg=DN(r,"B"), ln=DN(r,"L"), rn=DN(r,"R");
      color bgc=(dType[r]==0) ? dBg[r] : ((dType[r]==1||dZebra[r]) ? TABLE_ROW_ALT : TABLE_BG);
      if(cB[r]!=bgc){ ObjectSetInteger(0,bg,OBJPROP_BGCOLOR,bgc); ObjectSetInteger(0,bg,OBJPROP_COLOR,bgc); cB[r]=bgc; }
      color lc=(dType[r]==0) ? HEADER_TEXT : ((dType[r]==2) ? TEXT_MUTED : dCol[r]);
      if(cT[r]!=dL[r]){ ObjectSetString(0,ln,OBJPROP_TEXT,dL[r]); cT[r]=dL[r]; }
      if(cC[r]!=lc){ ObjectSetInteger(0,ln,OBJPROP_COLOR,lc); cC[r]=lc; }
      if(dType[r]==2)
        {
         if(cT[DMAX+r]!=dR[r]){ ObjectSetString(0,rn,OBJPROP_TEXT,dR[r]); cT[DMAX+r]=dR[r]; }
         if(cC[DMAX+r]!=dCol[r]){ ObjectSetInteger(0,rn,OBJPROP_COLOR,dCol[r]); cC[DMAX+r]=dCol[r]; }
        }
     }
  }
void UpdateDashboard(const int last,const datetime &time[],const double &close[])
  {
   if(gHeadless) return;
   if(!InpShowDash){ if(gDashRows>0) DashClear(); return; }
   int i=gLastProcessedBar; if(i<0) return;
   double c=close[i];
   int r=0;
   string trendWord=(gTrendDir==1 ? "Bullish" : (gTrendDir==-1 ? "Bearish" : "Neutral"));
   color trendCol=(gTrendDir==1 ? BULL_TEXT : (gTrendDir==-1 ? BEAR_TEXT : TEXT_MUTED));
   color headerBg=(gTrendDir==1 ? HEADER_BG_BULL : (gTrendDir==-1 ? HEADER_BG_BEAR : HEADER_BG));
   r=AddRow(r,0,SHORT_NAME+" - "+trendWord,"",HEADER_TEXT,false); dBg[0]=headerBg;
   if(InpSecMarket)
     {
      string ageStr=(gTrendDir!=0 && gTrendStartBar>=0) ? IntegerToString(i-gTrendStartBar)+" bars" : "-";
      int htf=HtfBiasAt(time[i]);
      string htfName=EnumToString(InpHtfTF); StringReplace(htfName,"PERIOD_","");
      string htfStr=!gHtfOn ? "Off" : (htf==1 ? "Bullish - "+htfName : (htf==-1 ? "Bearish - "+htfName : "-"));
      color htfCol=(gHtfOn && htf==1) ? BULL_TEXT : ((gHtfOn && htf==-1) ? BEAR_TEXT : TEXT_MUTED);
      string posStr=(gActiveDir==1 ? "BUY" : (gActiveDir==-1 ? "SELL" : "Flat"));
      color posCol=(gActiveDir==1 ? BULL_TEXT : (gActiveDir==-1 ? BEAR_TEXT : TEXT_MUTED));
      string lastStr=(gLastSigBar<0) ? "-" : gLastSigType+" - "+Score(gLastSigScore)+" ("+IntegerToString(i-gLastSigBar)+")";
      color lastCol=(gLastSigType=="BUY" ? BULL_TEXT : (gLastSigType=="SELL" ? BEAR_TEXT : TEXT_MUTED));
      string tfs=EnumToString(_Period); StringReplace(tfs,"PERIOD_","");
      r=AddRow(r,1,"- Market -","",TEXT_MUTED,false);
      r=AddRow(r,2,"Trend",trendWord,trendCol,false);
      r=AddRow(r,2,"Age",ageStr,TEXT_COLOR,true);
      r=AddRow(r,2,"HTF Bias",htfStr,htfCol,false);
      r=AddRow(r,2,"Position",posStr,posCol,true);
      r=AddRow(r,2,"Last Signal",lastStr,lastCol,false);
      r=AddRow(r,2,"Timeframe",tfs,TEXT_COLOR,true);
     }
   if(InpSecLevels)
     {
      string resStr="-",supStr="-"; color resCol=TEXT_MUTED,supCol=TEXT_MUTED;
      if(ArraySize(gSelRes)>0){ resStr=LevelDashStr(gLv[gSelRes[0]],c); resCol=BEAR_TEXT; }
      if(ArraySize(gSelSup)>0){ supStr=LevelDashStr(gLv[gSelSup[0]],c); supCol=BULL_TEXT; }
      string countStr="R "+IntegerToString(ArraySize(gSelRes))+" - S "+IntegerToString(ArraySize(gSelSup));
      string brk=(gLastBreakDir==1) ? "Up "+Px(gLastBreakLvl)+" ("+IntegerToString(i-gLastBreakBar)+")" : (gLastBreakDir==-1 ? "Down "+Px(gLastBreakLvl)+" ("+IntegerToString(i-gLastBreakBar)+")" : "-");
      color brkCol=(gLastBreakDir==1 ? BULL_TEXT : (gLastBreakDir==-1 ? BEAR_TEXT : TEXT_MUTED));
      r=AddRow(r,1,"- Levels -","",TEXT_MUTED,false);
      r=AddRow(r,2,"Resistance",resStr,resCol,false);
      r=AddRow(r,2,"Support",supStr,supCol,true);
      r=AddRow(r,2,"Shown",countStr,TEXT_COLOR,false);
      r=AddRow(r,2,"Last Break",brk,brkCol,true);
     }
   if(InpSecTrade)
     {
      r=AddRow(r,1,"- Trade -","",TEXT_MUTED,false);
      if(gActiveDir!=0)
        {
         string slStr=gBeActive ? "BE @ "+Px(gSL) : Px(gSL)+PctFromEntry(gSL,gEntry);
         double riskPct=(gEntry!=0) ? MathAbs(gEntry-gSL)/gEntry*100.0 : 0;
         r=AddRow(r,2,"Entry",(gActiveDir==1 ? "BUY @ " : "SELL @ ")+Px(gEntry),ENTRY_COLOR,false);
         r=AddRow(r,2,"SL",slStr,gBeActive ? BE_COLOR : SL_COLOR,true);
         r=AddRow(r,2,"TP1",(gTp1R ? "hit " : "")+Px(gTP1),gTp1R ? TP_HIT_COLOR : TP_LABEL_COLOR,false);
         r=AddRow(r,2,"TP2",(gTp2R ? "hit " : "")+Px(gTP2),gTp2R ? TP_HIT_COLOR : TP_LABEL_COLOR,true);
         r=AddRow(r,2,"TP3",(gTp3R ? "hit " : "")+Px(gTP3),gTp3R ? TP_HIT_COLOR : TP_LABEL_COLOR,false);
         r=AddRow(r,2,"R:R",F1(gTp1m)+"R - "+F1(gTp2m)+"R - "+F1(gTp3m)+"R",gTp1m>=1.5 ? BULL_TEXT : (gTp1m>=1.0 ? NEUTRAL_TEXT : BEAR_TEXT),true);
         r=AddRow(r,2,"SL Dist",F2(riskPct)+"%",riskPct>3.0 ? BEAR_TEXT : (riskPct>1.0 ? NEUTRAL_TEXT : BULL_TEXT),false);
        }
      else r=AddRow(r,3,"Flat - waiting for signal","",TEXT_MUTED,false);
     }
   if(InpSecStats)
     {
      string tag=(InpStatsPeriod==SP_24H ? "24H" : (InpStatsPeriod==SP_30D ? "30D" : "All-Time"));
      int pw=gWins,pl=gLosses;
      if(InpStatsPeriod!=SP_ALL){ datetime cut=(InpStatsPeriod==SP_24H) ? time[i]-86400 : time[i]-86400*30; PeriodStats(cut,pw,pl); }
      int tot=pw+pl; double wr=(tot>0) ? pw*100.0/tot : 0;
      color wrCol=(tot==0) ? TEXT_MUTED : (wr>=55.0 ? BULL_TEXT : (wr>=45.0 ? NEUTRAL_TEXT : BEAR_TEXT));
      r=AddRow(r,1,"- Stats - "+tag+" -","",TEXT_MUTED,false);
      r=AddRow(r,2,"Trades",tot>0 ? IntegerToString(tot) : "-",tot>0 ? TEXT_COLOR : TEXT_MUTED,false);
      r=AddRow(r,2,"Wins",tot>0 ? IntegerToString(pw) : "-",tot>0 ? BULL_TEXT : TEXT_MUTED,true);
      r=AddRow(r,2,"Losses",tot>0 ? IntegerToString(pl) : "-",tot>0 ? BEAR_TEXT : TEXT_MUTED,false);
      r=AddRow(r,2,"Win Rate",tot>0 ? F1(wr)+"%  "+Gauge(wr,100.0,GAUGE_WIDTH) : "-",wrCol,true);
      r=AddRow(r,2,"Form",StringLen(gForm)>0 ? gForm : "-",TEXT_COLOR,false);
     }
   r=AddRow(r,4,SHORT_NAME+" - "+INDICATOR_VERSION,"",TEXT_MUTED,false);
   //--- width from content
   int fs=DashFs(), fsSub=DashFsSub(), need=0;
   for(int k=0;k<r;k++)
     {
      int w=(dType[k]==2) ? TextW(dL[k],fs)+24+TextW(dR[k],fs) : TextW(dL[k],(dType[k]==1||dType[k]==4) ? fsSub : fs)+12;
      need=MathMax(need,w);
     }
   need+=12;
   if(gDashRows!=r || need>gDashW || need<gDashW-30 || ObjectFind(0,DN(0,"B"))<0) DashBuild(r,need);
   DashApply(r);
  }
//============================ INIT ==================================
int OnInit()
  {
   gPrefix="RLM_"+IntegerToString(ChartID()%100000)+"_";
   gHeadless=(MQLInfoInteger(MQL_TESTER) && !MQLInfoInteger(MQL_VISUAL_MODE)) || MQLInfoInteger(MQL_OPTIMIZATION);
   SetupTheme();
   //--- presets
   switch(InpPreset)
     {
      case RP_CONSERVATIVE: gSlMult=2.5; gTp1m=1.0; gTp2m=2.0; gTp3m=4.0; break;
      case RP_AGGRESSIVE:   gSlMult=1.0; gTp1m=1.5; gTp2m=2.5; gTp3m=4.0; break;
      case RP_SCALPING:     gSlMult=0.8; gTp1m=0.8; gTp2m=1.5; gTp3m=2.0; break;
      case RP_CUSTOM:       gSlMult=InpSlMult; gTp1m=InpTp1Mult; gTp2m=InpTp2Mult; gTp3m=InpTp3Mult; break;
      default:              gSlMult=1.5; gTp1m=1.0; gTp2m=2.0; gTp3m=3.0;
     }
   if(InpPreset==RP_CUSTOM && (InpTp1Mult>=InpTp2Mult || InpTp2Mult>=InpTp3Mult)){ Print("Invalid TP multipliers: required TP1 < TP2 < TP3"); return(INIT_PARAMETERS_INCORRECT); }
   if(gSlMult<=0){ Print("SL Multiplier must be greater than 0"); return(INIT_PARAMETERS_INCORRECT); }
   if(InpBE && InpBeOffset>=gTp1m*(InpSlMode==SL_ATR ? gSlMult : WICK_MIN_ATR)){ Print("BE Offset too large: break-even level would be at or beyond TP1"); return(INIT_PARAMETERS_INCORRECT); }
   if(InpZoneTransp!=0 && InpZoneTransp<60){ Print("Level Transparency must be 0 (Auto) or between 60 and 95"); return(INIT_PARAMETERS_INCORRECT); }
   gHtfOn=(InpHtfTF!=PERIOD_CURRENT && InpHtfTF!=_Period);
   if(InpHtfTF!=PERIOD_CURRENT && PeriodSeconds(InpHtfTF)<PeriodSeconds(_Period)){ Print("HTF Bias Timeframe must be >= chart timeframe - HTF bias off"); gHtfOn=false; }
   if(gHtfOn){ gHtfHandle=iMA(_Symbol,InpHtfTF,HTF_EMA_LEN,0,MODE_EMA,PRICE_CLOSE); if(gHtfHandle==INVALID_HANDLE) gHtfOn=false; }
   gDecay=MathPow(0.5,1.0/MathMax(50,InpHalfLife));
   gWarmup=MathMax(STRUCT_ATR_LEN,2*MathMax(2,InpSwingLen)+1);
   SetIndexBuffer(0,BufLongEntry,INDICATOR_DATA); SetIndexBuffer(1,BufShortEntry,INDICATOR_DATA);
   SetIndexBuffer(2,BufLongSig,INDICATOR_DATA);   SetIndexBuffer(3,BufShortSig,INDICATOR_DATA);
   SetIndexBuffer(4,BufSL,INDICATOR_DATA);        SetIndexBuffer(5,BufTP1,INDICATOR_DATA);
   for(int b=0;b<6;b++) PlotIndexSetDouble(b,PLOT_EMPTY_VALUE,EMPTY_VALUE);
   IndicatorSetString(INDICATOR_SHORTNAME,"Reaction Level Matrix [WillyAlgoTrader]");
   IndicatorSetInteger(INDICATOR_DIGITS,_Digits);
   gArr=0; ResetAll();
   return(INIT_SUCCEEDED);
  }
void OnDeinit(const int reason)
  {
   ObjectsDeleteAll(0,gPrefix,-1,-1);
   if(gHtfHandle!=INVALID_HANDLE) IndicatorRelease(gHtfHandle);
  }

//============================ MAIN ==================================
int OnCalculate(const int rates_total,const int prev_calculated,
                const datetime &time[],const double &open[],const double &high[],
                const double &low[],const double &close[],const long &tick_volume[],
                const long &volume[],const int &spread[])
  {
   if(rates_total<gWarmup+5) return(0);
   if(gHtfOn && BarsCalculated(gHtfHandle)<=0) return(0);
   ArraySetAsSeries(time,false); ArraySetAsSeries(open,false); ArraySetAsSeries(high,false); ArraySetAsSeries(low,false); ArraySetAsSeries(close,false);
   ArraySetAsSeries(BufLongEntry,false); ArraySetAsSeries(BufShortEntry,false); ArraySetAsSeries(BufLongSig,false); ArraySetAsSeries(BufShortSig,false); ArraySetAsSeries(BufSL,false); ArraySetAsSeries(BufTP1,false);
   int n=rates_total, last=n-1;
   bool full=(prev_calculated<=0 || prev_calculated>n || gProcessed>n-1 || (gProcessed>0 && time[gProcessed-1]!=gProcessedTime));
   if(full){ ResetAll(); gArr=0; SetupTheme(); }
   if(gArr!=n){ ArrayResize(gStructAtr,n); ArrayResize(gRiskAtr,n); ArrayResize(gTR,n); gArr=n; }
   //--- series
   int from=(full ? 0 : MathMax(0,prev_calculated-1));
   int pS=STRUCT_ATR_LEN, pR=MathMax(1,InpAtrLenRisk);
   for(int i=from;i<n;i++)
     {
      double tr=high[i]-low[i];
      if(i>0){ tr=MathMax(tr,MathAbs(high[i]-close[i-1])); tr=MathMax(tr,MathAbs(low[i]-close[i-1])); }
      gTR[i]=tr;
      if(i<pS-1) gStructAtr[i]=0; else if(i==pS-1 || gStructAtr[i-1]<=0){ double s=0; for(int j=i-pS+1;j<=i;j++) s+=gTR[j]; gStructAtr[i]=s/pS; } else gStructAtr[i]=(gStructAtr[i-1]*(pS-1)+tr)/pS;
      if(i<pR-1) gRiskAtr[i]=0;   else if(i==pR-1 || gRiskAtr[i-1]<=0){ double s=0; for(int j=i-pR+1;j<=i;j++) s+=gTR[j]; gRiskAtr[i]=s/pR; }     else gRiskAtr[i]=(gRiskAtr[i-1]*(pR-1)+tr)/pR;
      if(i>=gProcessed){ BufLongEntry[i]=EMPTY_VALUE; BufShortEntry[i]=EMPTY_VALUE; BufLongSig[i]=EMPTY_VALUE; BufShortSig[i]=EMPTY_VALUE; BufSL[i]=EMPTY_VALUE; BufTP1[i]=EMPTY_VALUE; }
     }
   //--- engine: closed bars once
   int closedBars=n-1; bool processedAny=false;
   for(int i=gProcessed;i<closedBars;i++)
     {
      ProcessBar(i,time,open,high,low,close,n,full && i<closedBars-1);
      gProcessed=i+1; gProcessedTime=time[i]; processedAny=true;
     }
   //--- render
   if(!gHeadless)
     {
      if(full)
        {
         for(int m=0;m<ArraySize(gMarks);m++) RenderMark(gMarks[m]);
        }
      if(full || processedAny)
        {
         RenderLevels(time[closedBars-1]);
         RenderTrade(time,n,last);
         UpdateDashboard(last,time,close);
         ChartRedraw(0);
        }
     }
   return(rates_total);
  }
void OnChartEvent(const int id,const long &lparam,const double &dparam,const string &sparam)
  {
   if(id==CHARTEVENT_CHART_CHANGE && !gHeadless){ ChartRedraw(0); }
  }
//+------------------------------------------------------------------+
