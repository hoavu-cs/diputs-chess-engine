# diputs-chess-engine

A troll chess engine written in Julia with some vibecoding.
I have 1 week to work on this project (mostly to rehash my Julia) and then I will stop (most likely).

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
julia --project=. src/uci.jl <<'EOF'
uci
isready
position startpos
go depth 6
quit
EOF
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

