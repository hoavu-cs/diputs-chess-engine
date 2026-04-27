# search.jl — NNUE search

const INF        = 10_000_000
const MATE_SCORE =  9_000_000

"""__________________________________________________

    Transposition Table
__________________________________________________"""

# Simple piece-type value for MVV-LVA (PAWN=1..KING=6 matches PieceType.val)
const _QS_PIECE_VAL = (100, 300, 300, 500, 900, 20000)

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

tt::Vector{TTEntry}  = Vector{TTEntry}(undef, 1 << 22)
tt_mask::UInt64      = UInt64((1 << 22) - 1)

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

# Mate scores are stored relative to root; adjust by ply on probe/store.
@inline function probe_tt(key::UInt64, depth::Int, ply::Int)
    idx = Int(key & tt_mask) + 1
    entry = tt[idx]
    (entry.flag == TT_EMPTY || entry.key != key) && return (false, 0, TT_EMPTY, Move(0))
    score = entry.score
    if abs(score) > MATE_SCORE - TT_MAX_PLY
        score += score > 0 ? -ply : ply
    end
    return (entry.depth ≥ depth, score, entry.flag, entry.best)
end

@inline function store_tt(key::UInt64, depth::Int, score::Int, flag::Int8, best::Move, ply::Int)
    idx = Int(key & tt_mask) + 1
    stored = score
    if abs(score) > MATE_SCORE - TT_MAX_PLY
        stored = score + (score > 0 ? ply : -ply)
    end
    tt[idx] = TTEntry(key, Int32(depth), Int32(stored), flag, best)
end

init_tt()

"""__________________________________________________

    Late Move Reductions
__________________________________________________"""

const LMR_DEPTH_MAX = 99
const LMR_MOVES_MAX = 256
const LMR_TABLE = zeros(Int, LMR_DEPTH_MAX, LMR_MOVES_MAX)

function init_lmr_table!()
    for d in 1:LMR_DEPTH_MAX
        for i in 1:LMR_MOVES_MAX
            R = 1 + log(d) * log(i) / 3
            LMR_TABLE[d, i] = clamp(round(Int, R), 1, d - 1)
        end
    end
end

init_lmr_table!()

@inline function lmr_reduction(depth::Int, i::Int, in_check::Bool, is_capture::Bool)::Int
    r = LMR_TABLE[depth, min(i, LMR_MOVES_MAX)]
    in_check   && (r = max(1, r - 1))
    is_capture && (r = max(1, r - 1))
    return min(r, depth - 1)
end

"""__________________________________________________
                        
    NNUE
__________________________________________________"""

const nnue_net = load_nnue(joinpath(@__DIR__, "nnue_hl_1024.bin"))
const nnue_acc = Accumulator()

"""__________________________________________________

    History Heuristics
__________________________________________________"""

const MAX_HISTORY = 16384

const history    = zeros(Int, 2, 64, 64)
const cont_hist  = zeros(Int16, 64, 7, 64, 7, 2)  # [cur_to, cur_pt, prev_to, prev_pt, stm]
const eval_stack = zeros(Int, 256)
const killers    = fill(Move(0), 2, 256)
const move_stack = fill((0, 0), 256)

function clear_history()
    fill!(history, 0)
    fill!(cont_hist, Int16(0))
    fill!(killers, Move(0))
    fill!(move_stack, (0, 0))
end

@inline function update_history!(color::Int, from_sq::Int, to_sq::Int, bonus::Int)
    clamped = clamp(bonus, -MAX_HISTORY, MAX_HISTORY)
    @inbounds history[color, from_sq, to_sq] +=
        clamped - history[color, from_sq, to_sq] * abs(clamped) ÷ MAX_HISTORY
end

@inline function update_cont_hist!(stm::Int, prev_pt::Int, prev_to::Int, cur_pt::Int, cur_to::Int, bonus::Int)
    prev_pt == 0 && return
    clamped = clamp(bonus, -MAX_HISTORY, MAX_HISTORY)
    @inbounds begin
        old = Int(cont_hist[cur_to, cur_pt, prev_to, prev_pt, stm])
        cont_hist[cur_to, cur_pt, prev_to, prev_pt, stm] = Int16(old + clamped - old * abs(clamped) ÷ MAX_HISTORY)
    end
end

const search_deadline = Ref{UInt64}(typemax(UInt64))

"""__________________________________________________

    Move Ordering
__________________________________________________"""

const _SCORE_HASH     = 1_000_000
const _SCORE_PROMO    =   900_000
const _SCORE_CAPTURE  =   100_000  # + MVV-LVA offset
const _SCORE_KILLER   =    90_000
const _MOVE_SCORES = zeros(Int, 256, 256) # [ply, move_index]

@inline function score_move(b::Board, m::Move, tt_move::Move, k1::Move, k2::Move, prev_pt::Int = 0, prev_to::Int = 0)::Int
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

    m == k1 && return _SCORE_KILLER
    m == k2 && return _SCORE_KILLER - 1

    color = sidetomove(b) == WHITE ? 1 : 2
    cur_pt = ptype(pieceon(b, from(m))).val
    ch = prev_pt > 0 ? @inbounds(Int(cont_hist[to(m).val, cur_pt, prev_to, prev_pt, color])) : 0
    return @inbounds(history[color, from(m).val, to(m).val]) + ch ÷ 2
end

function sort_moves!(b::Board, ml::Vector{Move}, ply::Int, tt_best::Move, k1::Move, k2::Move, prev_pt::Int, prev_to::Int)
    n = length(ml)
    scores = @view _MOVE_SCORES[ply, 1:n]
    
    for i in 1:n
        scores[i] = score_move(b, ml[i], tt_best, k1, k2, prev_pt, prev_to)
    end

    for i in 2:n
        tmp_m = ml[i]
        tmp_s = scores[i]
        j = i - 1
        while j >= 1 && scores[j] < tmp_s
            ml[j+1] = ml[j]
            scores[j+1] = scores[j]
            j -= 1
        end
        ml[j+1] = tmp_m
        scores[j+1] = tmp_s
    end
end

"""__________________________________________________

    Quiescence Search
__________________________________________________"""

function quiescence(b::Board, α::Int, β::Int, ply::Int, node_count::Ref{Int}, key_history::Vector{UInt64})::Int
    node_count[] += 1
    search_stopped[] && return 0

    # Repetition draw
    cnt = 0
    for k in key_history
        k == b.key && (cnt += 1)
        cnt ≥ 2 && return 0
    end

    if ischeckmate(b)
        return -(MATE_SCORE - ply)
    end
    isstalemate(b) && return 0

    # Stand-pat: static eval as a lower bound
    stand_pat = nnue_eval(nnue_acc, b, nnue_net)
    stand_pat ≥ β && return stand_pat
    α = max(α, stand_pat)

    captures = filter(m -> moveiscapture(b, m), moves(b))
    isempty(captures) && return α

    sort!(captures, by = m -> score_move(b, m, Move(0), Move(0), Move(0)), rev = true)

    best = stand_pat
    for m in captures
        search_stopped[] && break

        update!(nnue_acc, b, m, nnue_net)
        u  = domove!(b, m)
        push!(key_history, b.key)
        sc = -quiescence(b, -β, -α, ply + 1, node_count, key_history)
        pop!(key_history)
        undomove!(b, u)
        undo_update!(nnue_acc, b, m, nnue_net)

        best  = max(best, sc)
        α = max(α, sc)
        α ≥ β && break
    end

    return best
end

"""__________________________________________________

    Negamax
__________________________________________________"""

function negamax(b::Board, depth::Int, α::Int, β::Int, ply::Int, pv::Vector{Move}, node_count::Ref{Int}, key_history::Vector{UInt64})::Int
    node_count[] += 1
    if search_stopped[]
        return 0
    end
    if time_ns() ≥ search_deadline[]
        search_stopped[] = true
        return 0
    end

    # Repetition / fifty-move draw
    cnt = 0
    for k in key_history
        k == b.key && (cnt += 1)
        cnt ≥ 2 && return 0
    end
    isdraw(b) && return 0

    ml = collect(moves(b))

    # Terminal node: checkmate or stalemate
    if isempty(ml)
        empty!(pv)
        return ischeck(b) ? -(MATE_SCORE - ply) : 0
    end

    in_check = ischeck(b)

    # Check extension: don't drop into QS while in check
    if depth == 0
        if !in_check
            empty!(pv)
            return quiescence(b, α, β, ply, node_count, key_history)
        end
        depth = 1
    end

    # Probe TT; use cached score/bound if depth-sufficient
    hit, tt_score, tt_flag, tt_best = probe_tt(b.key, depth, ply)
    if hit
        if tt_flag == TT_EXACT
            return tt_score
        elseif tt_flag == TT_LOWER
            α = max(α, tt_score)
        elseif tt_flag == TT_UPPER
            β = min(β, tt_score)
        end
        α ≥ β && return tt_score
    end

    # IIR — no hash move at sufficient depth, reduce by 1
    depth -= (tt_best == Move(0) && depth ≥ 4) ? 1 : 0

    eval = nnue_eval(nnue_acc, b, nnue_net)
    eval_stack[ply] = eval
    improving = !in_check && ply >= 3 && eval > eval_stack[ply - 2]

    # Reverse futility pruning
    if depth ≤ 6 && !in_check
        eval ≥ β + (175 * depth - 25 * improving) && return div(eval + β, 2)
    end

    # Null move pruning — skip if side to move has only king + pawns
    if depth ≥ 3 && !in_check && eval ≥ β
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
            R = min(4 + div(depth, 3) + min(div(eval - β, 200), 3), depth - 1)
            u = donullmove!(b)
            move_stack[ply + 1] = (0, 0)
            sc = -negamax(b, depth - 1 - R, -β, -β + 1, ply + 1, Move[], node_count, key_history)
            undomove!(b, u)
            sc ≥ β && return sc
        end
    end

    # Move loop
    k1  = ply ≤ 256 ? killers[1, ply] : Move(0)
    k2  = ply ≤ 256 ? killers[2, ply] : Move(0)
    stm = sidetomove(b) == WHITE ? 1 : 2
    prev_pt, prev_to = ply > 1 ? move_stack[ply] : (0, 0)

    sort_moves!(b, ml, ply, tt_best, k1, k2, prev_pt, prev_to)  

    child_pv = Move[]
    best_score = -INF
    best_move = Move(0)
    flag = TT_UPPER
    searched_quiets = Move[]

    for (i, m) in enumerate(ml)
        lmr = i > 2 && depth ≥ 3 && promotion(m) == PieceType(0)
        is_capture = moveiscapture(b, m)
        is_quiet = !is_capture && promotion(m) == PieceType(0)

        cur_pt = ptype(pieceon(b, from(m))).val
        update!(nnue_acc, b, m, nnue_net)
        u  = domove!(b, m)
        push!(key_history, b.key)
        move_stack[ply + 1] = (cur_pt, to(m).val)

        R = lmr ? lmr_reduction(depth, i, ischeck(b), is_capture) : 0

        empty!(child_pv)
        sc = -negamax(b, depth - 1 - R, -β, -α, ply + 1, child_pv, node_count, key_history)

        # LMR re-search at full depth if the reduced search raised α
        if R > 0 && sc > α
            empty!(child_pv)
            sc = -negamax(b, depth - 1, -β, -α, ply + 1, child_pv, node_count, key_history)
        end

        pop!(key_history)
        undomove!(b, u)
        undo_update!(nnue_acc, b, m, nnue_net)

        if sc > best_score
            best_score = sc
            best_move = m

            if sc > α
                α = sc
                empty!(pv)
                push!(pv, m)
                append!(pv, child_pv)
                flag = TT_EXACT

                if α ≥ β
                    flag = TT_LOWER
                    # Update killers, history, and cont_hist on quiet beta cutoff
                    if is_quiet
                        if ply ≤ 256
                            killers[2, ply] = killers[1, ply]
                            killers[1, ply] = m
                        end
                        bonus = depth * depth
                        update_history!(stm, from(m).val, to(m).val, bonus)
                        update_cont_hist!(stm, prev_pt, prev_to, cur_pt, to(m).val, bonus)
                        for qm in searched_quiets
                            qm_pt = ptype(pieceon(b, from(qm))).val
                            update_history!(stm, from(qm).val, to(qm).val, -bonus)
                            update_cont_hist!(stm, prev_pt, prev_to, qm_pt, to(qm).val, -bonus)
                        end
                    end
                    break
                end
            end
        end

        is_quiet && push!(searched_quiets, m)
    end

    !search_stopped[] && store_tt(b.key, depth, best_score, flag, best_move, ply)
    return best_score
end


"""__________________________________________________

    Iterative Deepening Root
__________________________________________________"""

function search(b::Board, max_depth::Int, time_limit::Int)::Move
    @inbounds for i in eachindex(history)
        history[i] >>= 1
    end
    @inbounds for i in eachindex(cont_hist)
        cont_hist[i] >>= 1
    end
    fill!(killers, Move(0))
    refresh!(nnue_acc, b, nnue_net)

    start_ns  = time_ns()
    if time_limit ≥ typemax(Int) >> 20
        deadline = start_ns + 30_000_000_000
    else
        deadline = start_ns + UInt64(time_limit) * 1_000_000
    end

    best_move   = Move(0)
    ml          = collect(moves(b))
    node_count  = Ref(0)
    key_history = copy(game_key_history)
    isempty(ml) && return best_move
    search_deadline[] = deadline

    for depth in 1:max_depth
        search_stopped[] && break

        α          = -INF
        depth_best = Move(0)
        pv         = Move[]
        child_pv   = Move[]

        k1 = killers[1, 1]
        k2 = killers[2, 1]
        sort!(ml, by = m -> score_move(b, m, best_move, k1, k2), rev = true)

        for (i, m) in enumerate(ml)
            search_stopped[] && break
            empty!(child_pv)

            lmr = i > 2 && depth ≥ 3 && promotion(m) == PieceType(0)

            cur_pt = ptype(pieceon(b, from(m))).val
            update!(nnue_acc, b, m, nnue_net)
            u  = domove!(b, m)
            push!(key_history, b.key)
            move_stack[1] = (cur_pt, to(m).val)

            R = lmr ? lmr_reduction(depth, i, ischeck(b), false) : 0
            sc = -negamax(b, depth - 1 - R, -INF, -α, 1, child_pv, node_count, key_history)
            if R > 0 && sc > α
                empty!(child_pv)
                sc = -negamax(b, depth - 1, -INF, -α, 1, child_pv, node_count, key_history)
            end

            pop!(key_history)
            undomove!(b, u)
            undo_update!(nnue_acc, b, m, nnue_net)

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
