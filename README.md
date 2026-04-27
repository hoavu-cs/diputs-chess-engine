# diputs-chess-engine

A non-competitive troll chess engine written in Julia with some vibecoding.
I have 1 week to work on this project (mostly to rehash my Julia) and then I will stop (most likely).

## Strength
Commit c400cf9 against Stash 27 (~3050), 40/5.
```
Score of diputs.sh vs stash-27.0-linux-64: 28 - 19 - 13 [0.575]
...      diputs.sh playing White: 21 - 3 - 6  [0.800] 30
...      diputs.sh playing Black: 7 - 16 - 7  [0.350] 30
...      White vs Black: 37 - 10 - 13  [0.725] 60
Elo difference: 52.5 +/- 79.8, LOS: 90.5 %, DrawRatio: 21.7 %
SPRT: llr 0 (0.0%), lbound -inf, ubound inf
60 of 60 games finished.

```

## Requirements

- [Julia](https://julialang.org/downloads/) 1.9+. Make sure to add it to your PATH.

## Setup (one time)

```bash
julia --project=. -e 'import Pkg; Pkg.instantiate()'
```

## Running

```bash
julia --project=. src/uci.jl
```

Communicates via the UCI protocol on stdin/stdout. Quick smoke test:

```bash
julia --project=. src/uci.jl 
uci
isready
position startpos
go depth 6
...
quit
```

## Adding to a GUI

Point your UCI-compatible GUI (Arena, cutechess, fastchess, etc.) to the wrapper script:

```
diputs.sh
```

Make it executable first:

```bash
chmod +x diputs.sh
```

Or run directly from the terminal:

```bash
bash diputs.sh
```

