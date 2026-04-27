# Diputs Chess Engine

A non-competitive troll UCI chess engine written in Julia with some vibecoding.
I have ~~1 week~~ 2 weeks to work on this project (mostly to rehash my Julia) and then I will stop (most likely).

## Strength
Commit 82bfebb against Stash 27 (~3050), 3+2. UHO_Lichess_4852_v1.epd.
```
Score of diputs.sh vs stash-27.0-linux-64: 63 - 17 - 26 [0.717]
...      diputs.sh playing White: 38 - 7 - 10  [0.782] 55
...      diputs.sh playing Black: 25 - 10 - 16  [0.647] 51
...      White vs Black: 48 - 32 - 26  [0.575] 106
Elo difference: 161.5 +/- 62.3, LOS: 100.0 %, DrawRatio: 24.5 %
SPRT: llr 0 (0.0%), lbound -inf, ubound inf

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

Point your UCI-compatible GUI (Arena, Cutechess, En Croissant, Nibbler etc.) to the wrapper script:

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

