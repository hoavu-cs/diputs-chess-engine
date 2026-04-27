using Chess
using Base.Threads

const ENGINE_NAME   = "Diputs Chess Engine"
const ENGINE_AUTHOR = "H."

"""__________________________________________________

    Global State
__________________________________________________"""

board                        = startboard()
game_key_history             = UInt64[board.key]
num_threads::Int             = 4
max_depth::Int               = 99
search_stopped::Atomic{Bool} = Atomic{Bool}(false)
search_running::Atomic{Bool} = Atomic{Bool}(false)

"""__________________________________________________

    Position & Options
__________________________________________________"""

function process_position(command::String)
    tokens = String.(split(command))
    idx = 2
    if idx > length(tokens)
        return
    end

    if tokens[idx] == "startpos"
        global board = startboard()
        idx += 1
    elseif tokens[idx] == "fen"
        fen_parts = String[]
        idx += 1
        while idx <= length(tokens) && tokens[idx] != "moves"
            push!(fen_parts, tokens[idx])
            idx += 1
        end
        fen_str = join(fen_parts, " ")
        global board = fromfen(fen_str)
        if board === nothing
            global board = startboard()
            return
        end
    else
        return
    end

    global game_key_history = UInt64[board.key]

    if idx <= length(tokens) && tokens[idx] == "moves"
        idx += 1
        while idx <= length(tokens)
            try
                move = movefromstring(tokens[idx])
                domove!(board, move)
                push!(game_key_history, board.key)
            catch
            end
            idx += 1
        end
    end
end

function process_option(tokens::Vector{String})
    if length(tokens) < 5
        return
    end
    option_name = tokens[3]
    value_str   = tokens[5]
    if option_name == "Threads"
        global num_threads = parse(Int, value_str)
    elseif option_name == "Depth"
        global max_depth = parse(Int, value_str)
    elseif option_name == "Hash"
        resize_tt(parse(Int, value_str))
    end
end

include("nnue.jl")
include("search.jl")

"""__________________________________________________

    Search Thread
__________________________________________________"""

function search_thread(search_board::Board, search_depth::Int, time_limit::Int)
    try
        best_move = search(search_board, search_depth, time_limit)
        println(best_move != Move(0) ? "bestmove $(tostring(best_move))" : "bestmove 0000")
        flush(stdout)
    catch e
        println("info string ERROR: $e")
        println("bestmove 0000")
        flush(stdout)
    finally
        search_running[] = false
    end
end

function process_go(tokens::Vector{String})
    search_stopped[] = false
    search_running[] = true

    time_limit    = 30000
    search_depth  = max_depth
    depth_limited = false
    wtime = btime = winc = binc = movestogo = movetime = 0

    idx = 2
    while idx <= length(tokens)
        if tokens[idx] == "wtime" && idx + 1 <= length(tokens)
            wtime = parse(Int, tokens[idx + 1]); idx += 2
        elseif tokens[idx] == "btime" && idx + 1 <= length(tokens)
            btime = parse(Int, tokens[idx + 1]); idx += 2
        elseif tokens[idx] == "winc" && idx + 1 <= length(tokens)
            winc = parse(Int, tokens[idx + 1]); idx += 2
        elseif tokens[idx] == "binc" && idx + 1 <= length(tokens)
            binc = parse(Int, tokens[idx + 1]); idx += 2
        elseif tokens[idx] == "movestogo" && idx + 1 <= length(tokens)
            movestogo = parse(Int, tokens[idx + 1]); idx += 2
        elseif tokens[idx] == "movetime" && idx + 1 <= length(tokens)
            movetime = parse(Int, tokens[idx + 1]); idx += 2
        elseif tokens[idx] == "depth" && idx + 1 <= length(tokens)
            search_depth  = parse(Int, tokens[idx + 1])
            depth_limited = true
            time_limit    = typemax(Int)
            idx += 2
        else
            idx += 1
        end
    end

    if !depth_limited
        if movetime > 0
            time_limit = movetime
        else
            my_time = sidetomove(board) == WHITE ? wtime : btime
            my_inc  = sidetomove(board) == WHITE ? winc  : binc
            if my_time > 0
                time_limit = clamp(div(my_time, 20) + div(my_inc, 2), 0, div(my_time, 2))
            end
        end
    end

    Threads.@spawn search_thread(deepcopy(board), search_depth, time_limit)
end

function process_stop()
    search_running[] && (search_stopped[] = true)
end

"""__________________________________________________

    UCI Loop
__________________________________________________"""

function process_uci()
    println("id name $(ENGINE_NAME)")
    println("id author $(ENGINE_AUTHOR)")
    println("option name Threads type spin default 4 min 1 max 10")
    println("option name Depth type spin default 99 min 1 max 99")
    println("option name Hash type spin default 256 min 64 max 1024")
    println("uciok")
    flush(stdout)
end

function uci_loop()
    while true
        try
            line = String(strip(readline()))
            isempty(line) && continue

            if line == "uci"
                process_uci()
            elseif line == "isready"
                println("readyok"); flush(stdout)
            elseif line == "ucinewgame"
                global board = startboard()
                clear_tt()
                clear_history()
            elseif startswith(line, "position")
                process_position(line)
            elseif startswith(line, "setoption")
                process_option(String.(split(line)))
            elseif startswith(line, "go")
                process_go(String.(split(line)))
            elseif line == "stop"
                process_stop()
            elseif line == "quit"
                search_stopped[] = true
                break
            end
        catch e
            println(stderr, "UCI loop error: $e")
        end
    end
end

function julia_main()::Cint
    uci_loop()
    return 0
end

if abspath(PROGRAM_FILE) == @__FILE__
    uci_loop()
end
