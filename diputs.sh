#!/bin/bash
DIR="$(cd "$(dirname "$0")" && pwd)"
exec julia --project="$DIR" "$DIR/src/uci.jl"
