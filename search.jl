# search_exp.jl — experimental search; include from uci_exp.jl

const INF        = 10_000_000
const MATE_SCORE =  9_000_000


# Simple piece-type value for MVV-LVA (PAWN=1..KING=6 matches PieceType.val)
const _QS_PIECE_VAL = (100, 300, 300, 500, 900, 20000)

# ── Transposition Table ──────────────────────────────────────────────────────────

const TT_EXACT   = Int8(0)
const TT_LOWER   = Int8(1)
const TT_UPPER   = Int8(2)
const TT_EMPTY   = Int8(-1)
const TT_MAX_PLY = 256

struct TTEntry
    key::UInt64
    depth::Int32
    score::Int32
    flag::Int8
    best::Move
end

const TT_ENTRY_NULL = TTEntry(0, -1, 0, TT_EMPTY, Move(0))

tt      = Vector{TTEntry}(undef, 1 << 22)
tt_mask = UInt64((1 << 22) - 1)

function init_tt()
    global tt      = Vector{TTEntry}(undef, 1 << 22)
    global tt_mask = UInt64((1 << 22) - 1)
    fill!(tt, TT_ENTRY_NULL)
end

function clear_tt()
    fill!(tt, TT_ENTRY_NULL)
end

function resize_tt(mb::Int)
    target = div(mb * 1024 * 1024, sizeof(TTEntry))
    size = 1 << 16
    while size * 2 ≤ target
        size *= 2
    end
    global tt      = Vector{TTEntry}(undef, size)
    global tt_mask = UInt64(size - 1)
    fill!(tt, TT_ENTRY_NULL)
end

function probe_tt(key::UInt64, depth::Int, α::Int, β::Int, ply::Int)
    idx = Int(key & tt_mask) + 1
    entry = tt[idx]
    if entry.flag != TT_EMPTY && entry.key == key
        score = entry.score
        if abs(score) > MATE_SCORE - TT_MAX_PLY
            score += score > 0 ? -ply : ply
        end
        
        if entry.depth ≥ depth
            if entry.flag == TT_EXACT # exact flag, used as-is
                return (true, score, entry.best)
            end
            if entry.flag == TT_LOWER # lower bound, raise α
                α = max(α, score)
            elseif entry.flag == TT_UPPER
                β = min(β, score)
            end
            α ≥ β && return (true, score, entry.best)
        end
        return (false, 0, entry.best)
    end

    return (false, 0, Move(0))
end

function store_tt(key::UInt64, depth::Int, score::Int, flag::Int8, best::Move, ply::Int)
    idx = Int(key & tt_mask) + 1
    entry = tt[idx]
    if entry.flag == TT_EMPTY || depth ≥ entry.depth
        stored = score
        if abs(score) > MATE_SCORE - TT_MAX_PLY
            stored = score + (score > 0 ? ply : -ply)
        end
        tt[idx] = TTEntry(key, Int32(depth), Int32(stored), flag, best)
    end
end

init_tt()

search_deadline = Ref{UInt64}(typemax(UInt64))

# Move ordering scores
const _SCORE_HASH     = 1_000_000
const _SCORE_PROMO    =   900_000
const _SCORE_CAPTURE  =   100_000

function score_move(b::Board, m::Move, tt_move::Move)::Int
    m == tt_move && return _SCORE_HASH

    promo = promotion(m)
    if promo != PieceType(0)
        return _SCORE_PROMO + promo.val
    end

    if moveiscapture(b, m)
        vt = ptype(pieceon(b, to(m))).val
        victim = vt > 6 ? 1 : vt
        attacker = ptype(pieceon(b, from(m))).val
        return _SCORE_CAPTURE + _QS_PIECE_VAL[victim] * 10 - attacker
    end

    return 0
end

function quiescence(b::Board, α::Int, β::Int, ply::Int, node_count::Ref{Int}, key_history::Vector{UInt64})::Int
    node_count[] += 1
    search_stopped[] && return 0

    cnt = 0
    for k in key_history
        k == b.key && (cnt += 1)
        cnt ≥ 2 && return 0
    end

    if ischeckmate(b)
        return -(MATE_SCORE - ply)
    end
    isstalemate(b) && return 0

    stand_pat = static_eval(b)
    stand_pat ≥ β && return stand_pat
    α = max(α, stand_pat)

    captures = filter(m -> moveiscapture(b, m), moves(b))
    isempty(captures) && return α

    sort!(captures, by = m -> score_move(b, m, Move(0)), rev = true)

    best = stand_pat
    for m in captures
        search_stopped[] && break

        u  = domove!(b, m)
        push!(key_history, b.key)
        sc = -quiescence(b, -β, -α, ply + 1, node_count, key_history)
        pop!(key_history)
        undomove!(b, u)

        best  = max(best, sc)
        α = max(α, sc)
        α ≥ β && break
    end

    return best
end

function negamax(b::Board, depth::Int, α::Int, β::Int, ply::Int, pv::Vector{Move}, node_count::Ref{Int}, key_history::Vector{UInt64})::Int
    node_count[] += 1
    if search_stopped[]
        return 0
    end
    if time_ns() ≥ search_deadline[]
        search_stopped[] = true
        return 0
    end

    cnt = 0
    for k in key_history
        k == b.key && (cnt += 1)
        cnt ≥ 2 && return 0
    end
    isdraw(b) && return 0

    ml = collect(moves(b))

    if isempty(ml)
        empty!(pv)
        return ischeck(b) ? -(MATE_SCORE - ply) : 0
    end

    if depth == 0
        empty!(pv)
        return quiescence(b, α, β, ply, node_count, key_history)
    end

    hit, tt_score, tt_best = probe_tt(b.key, depth, α, β, ply)
    hit && return tt_score

    # Reverse futility pruning ~ 280 Elo
    in_check = ischeck(b)
    if depth ≤ 3 && !in_check
        eval = static_eval(b)
        margin = 150 * depth
        eval ≥ β + margin && return eval
    end

    # Null move pruning — skip if side to move has only king + pawns
    if depth ≥ 6 && !in_check && static_eval(b) ≥ β
        has_piece = false
        side = sidetomove(b)
        for pt in (QUEEN, ROOK, BISHOP, KNIGHT)
            for _ in pieces(b, side, pt)
                has_piece = true
                break
            end
            has_piece && break
        end
        if has_piece
            R = 3 + div(depth, 4)
            u = donullmove!(b)
            sc = -negamax(b, depth - 1 - R, -β, -β + 1, ply + 1, Move[], node_count, key_history)
            undomove!(b, u)
            sc ≥ β && return β
        end
    end

    sort!(ml, by = m -> score_move(b, m, tt_best), rev = true)

    child_pv = Move[]
    best_move = Move(0)
    flag = TT_UPPER

    for m in ml
        empty!(child_pv)
        u  = domove!(b, m)
        push!(key_history, b.key)
        sc = -negamax(b, depth - 1, -β, -α, ply + 1, child_pv, node_count, key_history)
        pop!(key_history)
        undomove!(b, u)

        if sc > α
            α = sc
            best_move = m
            empty!(pv)
            push!(pv, m)
            append!(pv, child_pv)
            flag = TT_EXACT

            α ≥ β && (flag = TT_LOWER; break)
        end
    end

    !search_stopped[] && store_tt(b.key, depth, α, flag, best_move, ply)
    return α
end

function search(b::Board, max_depth::Int, time_limit::Int)::Move
    start_ns  = time_ns()
    if time_limit ≥ typemax(Int) >> 20
        deadline = start_ns + 30_000_000_000 # 30 seconds if time limit is not set
    else
        deadline = start_ns + UInt64(time_limit) * 1_000_000
    end

    best_move   = Move(0)
    ml          = moves(b)
    node_count  = Ref(0)
    key_history = copy(game_key_history)
    isempty(ml) && return best_move
    search_deadline[] = deadline

    for depth in 1:max_depth
        search_stopped[] && break

        α = -INF
        depth_best = Move(0)
        pv = Move[]
        child_pv = Move[]

        for m in ml
            search_stopped[] && break

            empty!(child_pv)
            u  = domove!(b, m)
            push!(key_history, b.key)
            sc = -negamax(b, depth - 1, -INF, -α, 1, child_pv, node_count, key_history)
            pop!(key_history)
            undomove!(b, u)

            if sc > α
                α = sc
                depth_best = m
                empty!(pv)
                push!(pv, m)
                append!(pv, child_pv)
            end
        end

        if !search_stopped[] && depth_best != Move(0)
            best_move  = depth_best
            elapsed_ms = div(time_ns() - start_ns, 1_000_000)
            nps = elapsed_ms > 0 ? div(node_count[] * 1000, elapsed_ms) : 0
            pv_str = join(tostring.(pv), " ")
            println("info depth $depth score cp $α time $elapsed_ms nodes $(node_count[]) nps $nps pv $pv_str")
            flush(stdout)
        end

        time_ns() ≥ deadline && break
    end

    return best_move
end
