# diputs-chess-engine

A troll chess engine written in Julia with some vibecoding.
I have 1 week to work on this project (mostly to rehash my Julia) and then I will stop (most likely).

## Requirements

- [Julia](https://julialang.org/downloads/) 1.9+

## Setup (one time)

```bash
julia --project=. -e 'import Pkg; Pkg.instantiate()'
```

## Running

```bash
julia --project=. uci.jl
```

Communicates via the UCI protocol on stdin/stdout. Quick smoke test:

```bash
julia --project=. uci.jl <<'EOF'
uci
isready
position startpos
go depth 6
quit
EOF
```

## Adding to a GUI

Point your UCI-compatible GUI (Arena, cutechess, etc.) to the wrapper script:

```
diputs.sh
```

