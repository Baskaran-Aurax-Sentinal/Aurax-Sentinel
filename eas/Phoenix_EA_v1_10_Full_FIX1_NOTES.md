# Phoenix EA v1.10 Full FIX1

Status: Demo testing build

## File
`Phoenix_EA_v1_10_Full_FIX1.mq5`

## Version Purpose
Full reaction test build for Phoenix EA.

## Included Modules
- Auto BUY dynamic grid
- BUY trailing
- Broker TP backup
- Auto SELL tactical module
- Auto Hedge imbalance module
- Profit bank tracking
- Profit bank split by BUY / SELL / HEDGE
- Reset bank button
- Open-order dashboard
- Stack-zone view
- 24H high/low structural filter
- SELL/Hedge enabled by default for demo reaction testing

## FIX1
- Fixed MQL5 compile error: arrays must be passed by reference using `&`.

## Testing Notes
Test on demo first. Main things to observe:
- BUY spacing behavior
- BUY trailing behavior
- SELL trigger quality
- Hedge imbalance behavior
- Profit bank tracking accuracy
- Dashboard open-order clarity
- Whether SELL/Hedge creates both-side trap or stays controlled

## Risk Note
This is not a final live-risk version. Use for controlled demo testing and collect issue notes before next patch.
