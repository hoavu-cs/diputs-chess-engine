using Chess
using Base.Threads

# Engine metadata
const ENGINE_NAME = "Diputs Chess Engine"
const ENGINE_AUTHOR = "H."

# Global state
board = startboard()
game_key_history = UInt64[board.key]
num_threads::Int = 4
max_depth::Int = 99
search_stopped::Atomic{Bool} = Atomic{Bool}(false)
search_running::Atomic{Bool} = Atomic{Bool}(false)



"""
    process_position(command::String)

Parses and processes the 'position' command to set the board state.
"""
function process_position(command::String)
    tokens = String.(split(command))
    
    # Skip "position" token
    idx = 2
    if idx > length(tokens)
        return
    end
    
    if tokens[idx] == "startpos"
        global board = startboard()
        idx += 1
    elseif tokens[idx] == "fen"
        # Collect FEN tokens until we hit "moves" or end of command
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

    # Process moves if present
    if idx <= length(tokens) && tokens[idx] == "moves"
        idx += 1
        while idx <= length(tokens)
            try
                move = movefromstring(tokens[idx])
                domove!(board, move)
                push!(game_key_history, board.key)
            catch
                # Invalid move, skip it
            end
            idx += 1
        end
    end
end

"""
    process_option(tokens::Vector{String})

Parses and processes the 'setoption' command.
"""
function process_option(tokens::Vector{String})
    if length(tokens) < 5
        return
    end
    
    option_name = tokens[3]
    value_str = tokens[5]
    
    if option_name == "Threads"
        global num_threads = parse(Int, value_str)
    elseif option_name == "Depth"
        global max_depth = parse(Int, value_str)
    elseif option_name == "Hash"
        resize_tt(parse(Int, value_str))
    else
        # Unknown option
    end
end

include("nnue.jl")
include("search.jl")

"""
    search_thread(search_board::Board, search_depth::Int, time_limit::Int)

Runs search in a separate thread and outputs the best move.
"""
function search_thread(search_board::Board, search_depth::Int, time_limit::Int)
    try
        best_move = search(search_board, search_depth, time_limit)
        
        if best_move != Move(0)
            println("bestmove $(tostring(best_move))")
        else
            println("bestmove 0000")
        end
        flush(stdout)
    catch e
        println("info string ERROR: $e")
        println("bestmove 0000")
        flush(stdout)
    finally
        search_running[] = false
    end
end

"""
    process_go(tokens::Vector{String})

Parses and processes the 'go' command to start the search.
"""
function process_go(tokens::Vector{String})
    search_stopped[] = false
    search_running[] = true
    
    time_limit = 30000  # Default to 30 seconds
    search_depth = max_depth
    depth_limited = false
    
    # Parse go command parameters
    wtime = 0
    btime = 0
    winc = 0
    binc = 0
    movestogo = 0
    movetime = 0
    
    idx = 2
    while idx <= length(tokens)
        if tokens[idx] == "wtime" && idx + 1 <= length(tokens)
            wtime = parse(Int, tokens[idx + 1])
            idx += 2
        elseif tokens[idx] == "btime" && idx + 1 <= length(tokens)
            btime = parse(Int, tokens[idx + 1])
            idx += 2
        elseif tokens[idx] == "winc" && idx + 1 <= length(tokens)
            winc = parse(Int, tokens[idx + 1])
            idx += 2
        elseif tokens[idx] == "binc" && idx + 1 <= length(tokens)
            binc = parse(Int, tokens[idx + 1])
            idx += 2
        elseif tokens[idx] == "movestogo" && idx + 1 <= length(tokens)
            movestogo = parse(Int, tokens[idx + 1])
            idx += 2
        elseif tokens[idx] == "movetime" && idx + 1 <= length(tokens)
            movetime = parse(Int, tokens[idx + 1])
            idx += 2
        elseif tokens[idx] == "depth" && idx + 1 <= length(tokens)
            search_depth = parse(Int, tokens[idx + 1])
            depth_limited = true
            time_limit = typemax(Int)
            idx += 2
        else
            idx += 1
        end
    end
    
    # Calculate time limit if not depth-limited
    if !depth_limited
        if movetime > 0
            time_limit = movetime
        else
            my_time  = sidetomove(board) == WHITE ? wtime : btime
            my_inc   = sidetomove(board) == WHITE ? winc  : binc
            if my_time > 0
                time_limit = div(my_time, 20) + div(my_inc, 2)
                time_limit = clamp(time_limit, 0, div(my_time, 2))
            end
        end
    end
    
    Threads.@spawn search_thread(deepcopy(board), search_depth, time_limit)
end

"""
    process_stop()

Handles the 'stop' command to stop the current search.
"""
function process_stop()
    if search_running[]
        search_stopped[] = true
    end
end

"""
    process_uci()

Sends engine identification and options to the GUI.
"""
function process_uci()
    println("id name $(ENGINE_NAME)")
    println("id author $(ENGINE_AUTHOR)")
    println("option name Threads type spin default 4 min 1 max 10")
    println("option name Depth type spin default 99 min 1 max 99")
    println("option name Hash type spin default 256 min 64 max 1024")
    println("uciok")
    flush(stdout)
end

"""
    uci_loop()

Main UCI command loop that reads and processes commands from stdin.
"""
function uci_loop()
    while true
        try
            line = String(strip(readline()))
            
            if isempty(line)
                continue
            elseif line == "uci"
                process_uci()
            elseif line == "isready"
                println("readyok")
                flush(stdout)
            elseif line == "ucinewgame"
                global board = startboard()
                clear_tt()
                clear_history()
            elseif startswith(line, "position")
                process_position(line)
            elseif startswith(line, "setoption")
                tokens = String.(split(line))
                process_option(tokens)
            elseif startswith(line, "go")
                tokens = String.(split(line))
                process_go(tokens)
            elseif line == "stop"
                process_stop()
            elseif line == "quit"
                search_stopped[] = true
                break
            end
        catch e
            println(stderr, "UCI loop error: $e")
            continue
        end
    end
end

# Entry point for PackageCompiler / direct execution
function julia_main()::Cint
    uci_loop()
    return 0
end

if abspath(PROGRAM_FILE) == @__FILE__
    uci_loop()
end
