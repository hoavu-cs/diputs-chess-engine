const NNUE_INPUT = 768
const NNUE_HL    = 1024
const NNUE_SCALE = 400
const NNUE_QA    = 255
const NNUE_QB    = 64

struct NNUENet
    fw::Matrix{Int16}   # NNUE_HL × NNUE_INPUT  (column j = feature j weight vector)
    fb::Vector{Int16}   # NNUE_HL
    ow::Vector{Int16}   # 2 * NNUE_HL
    ob::Int16
end

function load_nnue(path::String)::NNUENet
    open(path, "r") do io
        fw = Matrix{Int16}(undef, NNUE_HL, NNUE_INPUT)
        read!(io, fw)
        fb = Vector{Int16}(undef, NNUE_HL)
        read!(io, fb)
        ow = Vector{Int16}(undef, 2 * NNUE_HL)
        read!(io, ow)
        ob = read(io, Int16)
        NNUENet(fw, fb, ow, ob)
    end
end

# Accumulator: two NNUE_HL vectors — one per king orientation (white / black perspective)
mutable struct Accumulator
    w::Vector{Int32}   # white's perspective
    b::Vector{Int32}   # black's perspective
end
Accumulator() = Accumulator(zeros(Int32, NNUE_HL), zeros(Int32, NNUE_HL))

# Chess.jl sq.val (1-indexed, column-major, rank 8 first) → standard 0-based (A1=0, H8=63)
@inline _nnue_sq(v::Int) = ((7 - ((v - 1) & 7)) << 3) | ((v - 1) >> 3)

# 1-based feature index:  side=0 own / 1 opponent,  pt=0..5 (Pawn..King),  sq=0..63
@inline _feat(side::Int, pt::Int, sq::Int) = side * 384 + pt * 64 + sq + 1

# Accumulator addition
@inline function _acc_add!(v::Vector{Int32}, fw::Matrix{Int16}, side::Int, pt::Int, sq::Int)
    f = _feat(side, pt, sq)
    @inbounds @simd for j in 1:NNUE_HL
        v[j] += Int32(fw[j, f])
    end
end

# Accumulator subtraction
@inline function _acc_sub!(v::Vector{Int32}, fw::Matrix{Int16}, side::Int, pt::Int, sq::Int)
    f = _feat(side, pt, sq)
    @inbounds @simd for j in 1:NNUE_HL
        v[j] -= Int32(fw[j, f])
    end
end

# Full recomputation from board position
function refresh!(acc::Accumulator, b::Board, net::NNUENet)
    fw = net.fw
    @inbounds for i in 1:NNUE_HL
        acc.w[i] = acc.b[i] = Int32(net.fb[i])
    end
    for (pt_jl, pt) in ((PAWN,0),(KNIGHT,1),(BISHOP,2),(ROOK,3),(QUEEN,4),(KING,5))
        for sq in pieces(b, WHITE, pt_jl)
            std = _nnue_sq(sq.val)
            _acc_add!(acc.w, fw, 0, pt, std)
            _acc_add!(acc.b, fw, 1, pt, std ⊻ 56)
        end
        for sq in pieces(b, BLACK, pt_jl)
            std = _nnue_sq(sq.val)
            _acc_add!(acc.b, fw, 0, pt, std ⊻ 56)
            _acc_add!(acc.w, fw, 1, pt, std)
        end
    end
end

# Helpers to apply/reverse a quiet or capture move on a single accumulator in place.
# Both must be called with the board in the PRE-move state.
# Val{true} = apply (update!), Val{false} = reverse (undo_update!).
@inline function _apply_move!(acc::Accumulator, b::Board, m::Move, net::NNUENet, ::Val{add}) where {add}
    piece  = pieceon(b, from(m))
    pt     = ptype(piece).val - 1
    color  = pcolor(piece)
    fw     = net.fw
    fsq    = _nnue_sq(from(m).val)
    tsq    = _nnue_sq(to(m).val)

    if color == WHITE
        add ? _acc_add!(acc.w, fw, 0, pt, tsq) : _acc_sub!(acc.w, fw, 0, pt, tsq)
        add ? _acc_sub!(acc.w, fw, 0, pt, fsq) : _acc_add!(acc.w, fw, 0, pt, fsq)
        add ? _acc_add!(acc.b, fw, 1, pt, tsq ⊻ 56) : _acc_sub!(acc.b, fw, 1, pt, tsq ⊻ 56)
        add ? _acc_sub!(acc.b, fw, 1, pt, fsq ⊻ 56) : _acc_add!(acc.b, fw, 1, pt, fsq ⊻ 56)
        if moveiscapture(b, m)
            cp = ptype(pieceon(b, to(m))).val - 1
            add ? _acc_sub!(acc.w, fw, 1, cp, tsq)      : _acc_add!(acc.w, fw, 1, cp, tsq)
            add ? _acc_sub!(acc.b, fw, 0, cp, tsq ⊻ 56) : _acc_add!(acc.b, fw, 0, cp, tsq ⊻ 56)
        end
    else
        add ? _acc_add!(acc.b, fw, 0, pt, tsq ⊻ 56) : _acc_sub!(acc.b, fw, 0, pt, tsq ⊻ 56)
        add ? _acc_sub!(acc.b, fw, 0, pt, fsq ⊻ 56) : _acc_add!(acc.b, fw, 0, pt, fsq ⊻ 56)
        add ? _acc_add!(acc.w, fw, 1, pt, tsq) : _acc_sub!(acc.w, fw, 1, pt, tsq)
        add ? _acc_sub!(acc.w, fw, 1, pt, fsq) : _acc_add!(acc.w, fw, 1, pt, fsq)
        if moveiscapture(b, m)
            cp = ptype(pieceon(b, to(m))).val - 1
            add ? _acc_sub!(acc.b, fw, 1, cp, tsq ⊻ 56) : _acc_add!(acc.b, fw, 1, cp, tsq ⊻ 56)
            add ? _acc_sub!(acc.w, fw, 0, cp, tsq)       : _acc_add!(acc.w, fw, 0, cp, tsq)
        end
    end
end

@inline function _apply_ep!(acc::Accumulator, b::Board, m::Move, net::NNUENet, ::Val{add}) where {add}
    fw   = net.fw
    fsq  = _nnue_sq(from(m).val)
    tsq  = _nnue_sq(to(m).val)
    ep_sq = _nnue_sq(((to(m).val - 1) >> 3) * 8 + ((from(m).val - 1) & 7) + 1)

    if pcolor(pieceon(b, from(m))) == WHITE
        add ? _acc_sub!(acc.w, fw, 0, 0, fsq)        : _acc_add!(acc.w, fw, 0, 0, fsq)
        add ? _acc_add!(acc.w, fw, 0, 0, tsq)        : _acc_sub!(acc.w, fw, 0, 0, tsq)
        add ? _acc_sub!(acc.w, fw, 1, 0, ep_sq)      : _acc_add!(acc.w, fw, 1, 0, ep_sq)
        add ? _acc_sub!(acc.b, fw, 1, 0, fsq ⊻ 56)  : _acc_add!(acc.b, fw, 1, 0, fsq ⊻ 56)
        add ? _acc_add!(acc.b, fw, 1, 0, tsq ⊻ 56)  : _acc_sub!(acc.b, fw, 1, 0, tsq ⊻ 56)
        add ? _acc_sub!(acc.b, fw, 0, 0, ep_sq ⊻ 56) : _acc_add!(acc.b, fw, 0, 0, ep_sq ⊻ 56)
    else
        add ? _acc_sub!(acc.b, fw, 0, 0, fsq ⊻ 56)  : _acc_add!(acc.b, fw, 0, 0, fsq ⊻ 56)
        add ? _acc_add!(acc.b, fw, 0, 0, tsq ⊻ 56)  : _acc_sub!(acc.b, fw, 0, 0, tsq ⊻ 56)
        add ? _acc_sub!(acc.b, fw, 1, 0, ep_sq ⊻ 56) : _acc_add!(acc.b, fw, 1, 0, ep_sq ⊻ 56)
        add ? _acc_sub!(acc.w, fw, 1, 0, fsq)        : _acc_add!(acc.w, fw, 1, 0, fsq)
        add ? _acc_add!(acc.w, fw, 1, 0, tsq)        : _acc_sub!(acc.w, fw, 1, 0, tsq)
        add ? _acc_sub!(acc.w, fw, 0, 0, ep_sq)      : _acc_add!(acc.w, fw, 0, 0, ep_sq)
    end
end

@inline function _apply_castle!(acc::Accumulator, b::Board, m::Move, net::NNUENet, ::Val{add}) where {add}
    fw = net.fw
    fsq = _nnue_sq(from(m).val)
    tsq = _nnue_sq(to(m).val)

    from_rank = (from(m).val - 1) & 7
    to_file   = (to(m).val   - 1) >> 3
    if to_file == 6  # kingside
        rfsq = _nnue_sq(7 * 8 + from_rank + 1)
        rtsq = _nnue_sq(5 * 8 + from_rank + 1)
    else             # queenside
        rfsq = _nnue_sq(from_rank + 1)
        rtsq = _nnue_sq(3 * 8 + from_rank + 1)
    end

    if pcolor(pieceon(b, from(m))) == WHITE
        add ? _acc_sub!(acc.w, fw, 0, 5, fsq)        : _acc_add!(acc.w, fw, 0, 5, fsq)
        add ? _acc_add!(acc.w, fw, 0, 5, tsq)        : _acc_sub!(acc.w, fw, 0, 5, tsq)
        add ? _acc_sub!(acc.b, fw, 1, 5, fsq ⊻ 56)  : _acc_add!(acc.b, fw, 1, 5, fsq ⊻ 56)
        add ? _acc_add!(acc.b, fw, 1, 5, tsq ⊻ 56)  : _acc_sub!(acc.b, fw, 1, 5, tsq ⊻ 56)
        add ? _acc_sub!(acc.w, fw, 0, 3, rfsq)       : _acc_add!(acc.w, fw, 0, 3, rfsq)
        add ? _acc_add!(acc.w, fw, 0, 3, rtsq)       : _acc_sub!(acc.w, fw, 0, 3, rtsq)
        add ? _acc_sub!(acc.b, fw, 1, 3, rfsq ⊻ 56) : _acc_add!(acc.b, fw, 1, 3, rfsq ⊻ 56)
        add ? _acc_add!(acc.b, fw, 1, 3, rtsq ⊻ 56) : _acc_sub!(acc.b, fw, 1, 3, rtsq ⊻ 56)
    else
        add ? _acc_sub!(acc.b, fw, 0, 5, fsq ⊻ 56)  : _acc_add!(acc.b, fw, 0, 5, fsq ⊻ 56)
        add ? _acc_add!(acc.b, fw, 0, 5, tsq ⊻ 56)  : _acc_sub!(acc.b, fw, 0, 5, tsq ⊻ 56)
        add ? _acc_sub!(acc.w, fw, 1, 5, fsq)        : _acc_add!(acc.w, fw, 1, 5, fsq)
        add ? _acc_add!(acc.w, fw, 1, 5, tsq)        : _acc_sub!(acc.w, fw, 1, 5, tsq)
        add ? _acc_sub!(acc.b, fw, 0, 3, rfsq ⊻ 56) : _acc_add!(acc.b, fw, 0, 3, rfsq ⊻ 56)
        add ? _acc_add!(acc.b, fw, 0, 3, rtsq ⊻ 56) : _acc_sub!(acc.b, fw, 0, 3, rtsq ⊻ 56)
        add ? _acc_sub!(acc.w, fw, 1, 3, rfsq)       : _acc_add!(acc.w, fw, 1, 3, rfsq)
        add ? _acc_add!(acc.w, fw, 1, 3, rtsq)       : _acc_sub!(acc.w, fw, 1, 3, rtsq)
    end
end

@inline function _apply_promo!(acc::Accumulator, b::Board, m::Move, net::NNUENet, ::Val{add}) where {add}
    fw       = net.fw
    fsq      = _nnue_sq(from(m).val)
    tsq      = _nnue_sq(to(m).val)
    promo_pt = promotion(m).val - 1

    if pcolor(pieceon(b, from(m))) == WHITE
        add ? _acc_sub!(acc.w, fw, 0, 0, fsq)              : _acc_add!(acc.w, fw, 0, 0, fsq)
        add ? _acc_sub!(acc.b, fw, 1, 0, fsq ⊻ 56)        : _acc_add!(acc.b, fw, 1, 0, fsq ⊻ 56)
        add ? _acc_add!(acc.w, fw, 0, promo_pt, tsq)       : _acc_sub!(acc.w, fw, 0, promo_pt, tsq)
        add ? _acc_add!(acc.b, fw, 1, promo_pt, tsq ⊻ 56) : _acc_sub!(acc.b, fw, 1, promo_pt, tsq ⊻ 56)
        if moveiscapture(b, m)
            cp = ptype(pieceon(b, to(m))).val - 1
            add ? _acc_sub!(acc.w, fw, 1, cp, tsq)        : _acc_add!(acc.w, fw, 1, cp, tsq)
            add ? _acc_sub!(acc.b, fw, 0, cp, tsq ⊻ 56)  : _acc_add!(acc.b, fw, 0, cp, tsq ⊻ 56)
        end
    else
        add ? _acc_sub!(acc.b, fw, 0, 0, fsq ⊻ 56)        : _acc_add!(acc.b, fw, 0, 0, fsq ⊻ 56)
        add ? _acc_sub!(acc.w, fw, 1, 0, fsq)              : _acc_add!(acc.w, fw, 1, 0, fsq)
        add ? _acc_add!(acc.b, fw, 0, promo_pt, tsq ⊻ 56) : _acc_sub!(acc.b, fw, 0, promo_pt, tsq ⊻ 56)
        add ? _acc_add!(acc.w, fw, 1, promo_pt, tsq)       : _acc_sub!(acc.w, fw, 1, promo_pt, tsq)
        if moveiscapture(b, m)
            cp = ptype(pieceon(b, to(m))).val - 1
            add ? _acc_sub!(acc.b, fw, 1, cp, tsq ⊻ 56)  : _acc_add!(acc.b, fw, 1, cp, tsq ⊻ 56)
            add ? _acc_sub!(acc.w, fw, 0, cp, tsq)        : _acc_add!(acc.w, fw, 0, cp, tsq)
        end
    end
end

# Incremental update in place. Call BEFORE domove!(b, m).
function update!(acc::Accumulator, b::Board, m::Move, net::NNUENet)
    piece   = pieceon(b, from(m))
    from_f  = (from(m).val - 1) >> 3
    to_f    = (to(m).val   - 1) >> 3
    is_ep   = ptype(piece) == PAWN && from_f != to_f && !moveiscapture(b, m)
    is_cast = ptype(piece) == KING && abs(from_f - to_f) > 1

    if is_ep
        _apply_ep!(acc, b, m, net, Val(true))
    elseif is_cast
        _apply_castle!(acc, b, m, net, Val(true))
    elseif promotion(m) != PieceType(0)
        _apply_promo!(acc, b, m, net, Val(true))
    else
        _apply_move!(acc, b, m, net, Val(true))
    end
end

# Reverse the update. Call AFTER undomove!(b, u) — board is back to pre-move state.
function undo_update!(acc::Accumulator, b::Board, m::Move, net::NNUENet)
    piece   = pieceon(b, from(m))
    from_f  = (from(m).val - 1) >> 3
    to_f    = (to(m).val   - 1) >> 3
    is_ep   = ptype(piece) == PAWN && from_f != to_f && !moveiscapture(b, m)
    is_cast = ptype(piece) == KING && abs(from_f - to_f) > 1

    if is_ep
        _apply_ep!(acc, b, m, net, Val(false))
    elseif is_cast
        _apply_castle!(acc, b, m, net, Val(false))
    elseif promotion(m) != PieceType(0)
        _apply_promo!(acc, b, m, net, Val(false))
    else
        _apply_move!(acc, b, m, net, Val(false))
    end
end

# Evaluate from a pre-built accumulator. Returns centipawns from side-to-move perspective.
function nnue_eval(acc::Accumulator, b::Board, net::NNUENet)::Int
    us, them = sidetomove(b) == WHITE ? (acc.w, acc.b) : (acc.b, acc.w)
    ow  = net.ow
    out = Int64(0)
    @inbounds @simd for i in 1:NNUE_HL
        uv = clamp(us[i],   Int32(0), Int32(NNUE_QA))
        tv = clamp(them[i], Int32(0), Int32(NNUE_QA))
        out += Int64(uv) * uv * Int64(ow[i])
        out += Int64(tv) * tv * Int64(ow[NNUE_HL + i])
    end
    out = div(out, Int64(NNUE_QA)) + Int64(net.ob)
    return Int(div(out * Int64(NNUE_SCALE), Int64(NNUE_QA * NNUE_QB)))
end

# Convenience: full recompute then evaluate (for root / testing)
function nnue_eval(b::Board, net::NNUENet)::Int
    acc = Accumulator()
    refresh!(acc, b, net)
    nnue_eval(acc, b, net)
end
