#=
        Chess.jl: A Julia chess programming library
        Copyright (C) 2019 Tord Romstad

        This program is free software: you can redistribute it and/or modify
        it under the terms of the GNU Affero General Public License as
        published by the Free Software Foundation, either version 3 of the
        License, or (at your option) any later version.

        This program is distributed in the hope that it will be useful,
        but WITHOUT ANY WARRANTY; without even the implied warranty of
        MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
        GNU Affero General Public License for more details.

        You should have received a copy of the GNU Affero General Public License
        along with this program.  If not, see <https://www.gnu.org/licenses/>.
=#

using Dates, Printf, StatsBase

export BookEntry

export createbook, findbookentries, pickmove, printbookentries, purgebook,
    writetofile


mutable struct BookEntry
    key::UInt64
    move::Int32
    elo::Int16
    oppelo::Int16
    wins::Int32
    draws::Int32
    losses::Int32
    year::Int16
    score::Float32
end

function BookEntry()
    BookEntry(0, 0, 0, 0, 0, 0, 0, 0, 0)
end

function Base.show(io::IO, e::BookEntry)
    println(io, "BookEntry:")
    println(io, " key: $(e.key)")
    println(io, " move: $(Move(e.move))")
    println(io, " (w, d, l): ($(e.wins), $(e.draws), $(e.losses))")
    println(io, " year: $(e.year)")
    print(io, " score: $(e.score)")
end


const ENTRY_SIZE = 34
const COMPACT_ENTRY_SIZE = 16


function entrytobytes(entry::BookEntry, compact::Bool)::Vector{UInt8}
    io = IOBuffer(UInt8[], read = true, write = true,
                  maxsize = compact ? COMPACT_ENTRY_SIZE : ENTRY_SIZE)
    write(io, entry.key)
    write(io, entry.move)
    write(io, entry.score)
    if !compact
        write(io, entry.elo)
        write(io, entry.oppelo)
        write(io, entry.wins)
        write(io, entry.draws)
        write(io, entry.losses)
        write(io, entry.year)
    end
    take!(io)
end


function entryfrombytes(bytes::Vector{UInt8}, compact::Bool)::BookEntry
    io = IOBuffer(bytes)
    result = BookEntry()
    result.key = read(io, UInt64)
    result.move = read(io, Int32)
    result.score = read(io, Float32)
    if !compact
        result.elo = read(io, Int16)
        result.oppelo = read(io, Int16)
        result.wins = read(io, Int32)
        result.draws = read(io, Int32)
        result.losses = read(io, Int32)
        result.year = read(io, Int16)
    end
    result
end


function computescore(result, color, elo, date,
                      scorewhitewin, scorewhitedraw, scorewhiteloss,
                      scoreblackwin, scoreblackdraw, scoreblackloss,
                      scoreunknown, highelofactor, yearlydecay)::Float32
    base = if result == "1-0" && color == WHITE
        scorewhitewin
    elseif result == "1/2-1/2" && color == WHITE
        scorewhitedraw
    elseif result == "0-1" && color == WHITE
        scorewhiteloss
    elseif result == "0-1" && color == BLACK
        scoreblackwin
    elseif result == "1/2-1/2" && color == BLACK
        scoreblackdraw
    elseif result == "1-0" && color == BLACK
        scoreblackloss
    else
        scoreunknown
    end
    base *
        max(1.0, 0.01 * highelofactor * (2300 - elo)) *
        exp(log(yearlydecay) *
            (Dates.value(today() - date) / 365.25))
end


function mergeable(e1::BookEntry, e2::BookEntry)::Bool
    e1.key == e2.key && e1.move == e2.move
end


function merge(e1::BookEntry, e2::BookEntry)::BookEntry
    BookEntry(e1.key, e1.move, max(e1.elo, e2.elo), max(e1.oppelo, e2.oppelo),
              e1.wins + e2.wins, e1.draws + e2.draws, e1.losses + e2.losses,
              max(e1.year, e2.year), e1.score + e2.score)
end


function compress!(entries::Vector{BookEntry})
    i = 1; j = 1; n = length(entries)
    iterations = 0
    while j + 1 < n
        for k ∈ j + 1 : n
            if !mergeable(entries[i], entries[k]) || k == n
                j = k
                i += 1
                entries[i] = entries[k]
                break
            end
            entries[i] = merge(entries[i], entries[k])
        end
    end
    entries[1 : i - 1]
end



function compareentries(e1::BookEntry, e2::BookEntry)::Bool
    e1.key < e2.key || (e1.key == e2.key && e1.move < e2.move)
end


function sortentries!(entries::Vector{BookEntry})
    sort!(entries, lt = compareentries)
end


function addgame!(entries::Vector{BookEntry}, g::SimpleGame,
                  scorewhitewin, scorewhitedraw, scorewhiteloss,
                  scoreblackwin, scoreblackdraw, scoreblackloss,
                  scoreunknown, highelofactor, yearlydecay, maxply, minelo)
    result = headervalue(g, "Result")
    if result ≠ "*"
        w = result == "1-0" ? 1 : 0
        d = result == "1/2-1/2" ? 1 : 0
        l = result == "0-1" ? 1 : 0
        welo = whiteelo(g) ≠ nothing ? whiteelo(g) : 0
        belo = blackelo(g) ≠ nothing ? blackelo(g) : 0
        date = dateplayed(g) ≠ nothing ? dateplayed(g) : Date(1900, 1, 1)
        year = Dates.year(date)
        wscore = computescore(result, WHITE, welo, date,
                              scorewhitewin, scorewhitedraw, scorewhiteloss,
                              scoreblackwin, scoreblackdraw, scoreblackloss,
                              scoreunknown, highelofactor, yearlydecay)
        bscore = computescore(result, BLACK, belo, date,
                              scorewhitewin, scorewhitedraw, scorewhiteloss,
                              scoreblackwin, scoreblackdraw, scoreblackloss,
                              scoreunknown, highelofactor, yearlydecay)

        tobeginning!(g)
        while !isatend(g) && g.ply <= maxply
            b = board(g)
            wtm = sidetomove(b) == WHITE
            m = nextmove(g)
            if wtm && welo >= minelo || !wtm && belo >= minelo
                push!(entries, BookEntry(b.key, m.val,
                                         wtm ? welo : belo, wtm ? belo : welo,
                                         wtm ? w : l, d, wtm ? l : w, year,
                                         wtm ? wscore : bscore))
            end
            forward!(g)
        end
    end
end


function addgamefile!(entries::Vector{BookEntry}, filename::String,
                      scorewhitewin, scorewhitedraw, scorewhiteloss,
                      scoreblackwin, scoreblackdraw, scoreblackloss,
                      scoreunknown, highelofactor, yearlydecay, maxply,
                      minelo, count)
    for g ∈ PGN.gamesinfile(filename)
        addgame!(entries, g, scorewhitewin, scorewhitedraw, scorewhiteloss,
                 scoreblackwin, scoreblackdraw, scoreblackloss, scoreunknown,
                 highelofactor, yearlydecay, maxply, minelo)
        count += 1
        if count % 1000 == 0
            println("$count games added, $(length(entries)) entries.")
        end
    end
    count
end


function createbook(filenames::Vararg{String};
                    scorewhitewin = 8.0,
                    scorewhitedraw = 4.0,
                    scorewhiteloss = 1.0,
                    scoreblackwin = 8.0,
                    scoreblackdraw = 5.0,
                    scoreblackloss = 1.0,
                    scoreunknown = 0.0,
                    highelofactor = 6.0,
                    yearlydecay = 0.85,
                    maxply = 60,
                    minelo = 0)
    result = Vector{BookEntry}()
    count = 0
    for filename ∈ filenames
        count = addgamefile!(result, filename, scorewhitewin, scorewhitedraw,
                             scorewhiteloss, scoreblackwin, scoreblackdraw,
                             scoreblackloss, scoreunknown, highelofactor,
                             yearlydecay, maxply, minelo, count)
    end
    result = compress!(sortentries!(result))
    result
end


function writetofile(entries::Vector{BookEntry}, filename::String,
                     compact = false)
    open(filename, "w") do f
        write(f, UInt8(compact ? 1 : 0))
        for e ∈ entries
            write(f, entrytobytes(e, compact))
        end
    end
end


function purgebook(infile::String, outfile::String;
                   minscore = 0, mingamecount = 5,
                   compact = false)
    open(infile, "r") do inf
        open(outfile, "w") do outf
            write(outf, UInt8(compact ? 1 : 0))
            incompact = read(inf, UInt8) == 1
            entrysize = incompact ? COMPACT_ENTRY_SIZE : ENTRY_SIZE
            entrycount = div(filesize(infile) - 1, entrysize)
            for i in 1 : entrycount
                e = readentry(inf, i - 1, incompact)
                if e.wins + e.draws + e.losses ≥ mingamecount && e.score > minscore
                    write(outf, entrytobytes(e, compact))
                end
                if i % 100000 == 0
                    @printf("%d/%d (%.1f%%) entries processed.\n",
                            i, entrycount, 100 * i / entrycount)
                end
            end
        end
    end
end


function readkey(f::IO, index::Int, entrysize::Int)::UInt64
    seek(f, 1 + entrysize * index)
    read(f, UInt64)
end


function findkey(f::IO, key::UInt64, left::Int, right::Int,
                 entrysize::Int)::Union{Int, Nothing}
    while left <= right
        middle = div(left + right, 2)
        midkey = readkey(f, middle, entrysize)
        if key == midkey && (middle == 0 ||
                             key ≠ readkey(f, middle - 1, entrysize))
            return middle
        elseif midkey < key
            left = middle + 1
        else
            right = middle - 1
        end
    end
end


function readentry(f::IO, index::Int, compact = false)::Union{BookEntry, Nothing}
    entrysize = compact ? COMPACT_ENTRY_SIZE : ENTRY_SIZE
    seek(f, 1 + entrysize * index)
    e = entryfrombytes(read(f, entrysize), compact)
end


function findbookentries(key::UInt64, filename::String)::Vector{BookEntry}
    result = Vector{BookEntry}()
    open(filename, "r") do f
        compact = read(f, UInt8) == 1
        entrysize = compact ? COMPACT_ENTRY_SIZE : ENTRY_SIZE
        entrycount = div(filesize(filename) - 1, entrysize)
        i = findkey(f, key, 0, entrycount - 1, entrysize)
        if i ≠ nothing
            for j in i:entrycount
                e = readentry(f, j, compact)
                if e.key == key
                    push!(result, e)
                else
                    break
                end
            end
        end
    end
    sort(result, by = e -> -e.score)
end


function findbookentries(b::Board, filename::String)::Vector{BookEntry}
    findbookentries(b.key, filename)
end


function printbookentries(b::Board, filename::String)
    entries = findbookentries(b, filename)
    scoresum = sum(map(e -> e.score, entries))
    for e ∈ entries
        @printf("%s %.2f %.1f%% (+%d, =%d, -%d) %d %d %d\n",
                movetosan(b, Move(e.move)),
                e.score / scoresum,
                100 * ((e.wins + 0.5 * e.draws) / (e.wins + e.draws + e.losses)),
                e.wins, e.draws, e.losses,
                e.elo, e.oppelo, e.year)
    end
end


function pickmove(b::Board, filename::String;
                  minscore = 0, mingamecount = 1)::Union{Move, Nothing}
    entries = filter(e -> e.wins + e.draws + e.losses >= mingamecount
                     && e.score >= minscore,
                     findbookentries(b, filename))
    if length(entries) == 0
        nothing
    else
        w = Weights(map(e -> e.score, entries))
        Move(sample(entries, w).move)
    end
end
