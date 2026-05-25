# Aurax Sentinel

**Aurax Sentinel** is the master project repository for organizing, versioning, documenting, and improving all MT5 Expert Advisors created under the Aurax / Gold Snipers trading system.

This repository is intended to keep every EA cleanly separated by name, logic, version, risk model, and test history.

## Project Purpose

Aurax Sentinel acts as the control center for:

- MT5 EA source code storage
- Version tracking
- Strategy documentation
- Input-setting documentation
- Backtest and forward-test notes
- Risk rules and safety logic
- Dashboard and monitoring ideas
- Future master-control architecture

## EA Collection

| EA Name | Main Purpose | Status |
|---|---|---|
| Aurax | Grid, hybrid TP, profit-bank assisted exit, side-wise pause/manage logic | Active |
| Falcon | Auto buy/sell hedge grid with cycle controls and dashboard | Active |
| Madness Ver 1 | PSAR trend system with close-all on flip | Saved core version |
| Madness V2 | PSAR reverse-cycle system without forced close on flip | Experimental |
| GodFather | Manual-trigger dual-side grid with recovery and timed entries | Active/reference |
| Sniper / Sniper_AutoBuy | Auto buy/grid + manual sell/rapid hedge concepts | Active |
| Hope | Strict spacing/grid recovery EA | Active/reference |
| IronMan | Manual base order triggers both buy and sell together | New/reference |
| Bumblebee | Time-gap based multi-layer TP/trailing system | Reference |
| Lovely Hedge EA | Partial hedge EA reacting to manual/other EA drawdown | Active/reference |
| Gold_Sniper | Indicator-based single-order/scalping logic | Experimental |
| Relentless PRO | Hybrid grid + step trailing + basket logic | Reference |
| Boss Dashboard | Monitoring dashboard for orders, P/L, stacking zones | Utility |
| Master Control EA | Global multi-EA dashboard and control concept | Future |

## Repository Structure

```text
Aurax-Sentinel/
├── README.md
├── EA_INDEX.md
├── docs/
├── eas/
├── templates/
└── tests/
```

## Golden Rules

1. Do not change any EA core logic unless clearly marked as a new version.
2. Every EA must have its own folder.
3. Every major change must be documented in a changelog.
4. Magic numbers must remain isolated between EAs.
5. Broker-level TP should be used wherever possible as backup protection.
6. Dashboard and risk controls should be documented before live testing.
7. Never mix experimental code with saved stable versions.

## Project Owner

**Aurax Sentinel / Gold Snipers**

Created for long-term EA development, risk control, and trading system growth.
