export @P_str, @pot

using Distributed
using UUIDs:uuid4

const KEY = :OOLONG

#####
# Pot Definition
#####

struct PotID
    path::Tuple{Vararg{Symbol}}
end

struct Pot
    pid::PotID
    tea_bag::Any
end

function Pot(
    tea_bag;
    name=string(uuid4())
)
    pid = PotID(name)
    Pot(pid, tea_bag)
end

macro pot(tea, kw...)
    tea_bag = esc(:(() -> ($(tea))))
    xs = [esc(x) for x in kw]
    quote
        p = Pot($tea_bag; $(xs...))
        register(p)
        p.pid
    end
end

"""
    P"[/]your/pot/path"

The path can be either relative or absolute path. If a relative path is provided, it will be resolved to an absolute path based on the current context.

!!! note
    We don't validate the path for you during construction. A [`PotNotRegisteredError`](@ref) will be thrown when you try to send messages to an unregistered path.
"""
macro P_str(s)
    PotID(s)
end

function Base.show(io::IO, p::PotID)
    if isempty(p.path)
        print(io, '/')
    else
        for x in p.path
            print(io, '/')
            print(io, x)
        end
    end
end

function PotID(s::String)
    if length(s) > 0
        if s[1] == '/'
            PotID(Tuple(Symbol(x) for x in split(s, '/';keepempty=false)))
        else
            PotID((self().path..., (Symbol(x) for x in split(s, '/';keepempty=false))...))
        end
    else
        PotID(())
    end
end

const ROOT = P"/"
const USER = P"/user"
const SCHEDULER = P"/scheduler"

self() = try
    task_local_storage(KEY)
catch
    USER
end

Base.parent() = parent(self())
Base.parent(p::PotID) = PotID(p.path[1:end-1])

#####
# Pot Scheduling
#####

"local cache to reduce remote call, we may use redis like db later"
const POT_LINK_CACHE = Dict{PotID, RemoteChannel{Channel{Any}}}()
const POT_REGISTRY_CACHE = Dict{PotID, Pot}()

function register(p::Pot)
    POT_REGISTRY_CACHE[p.pid] = p
    if myid() != 1
        remotecall_wait(1) do
            Oolong.POT_REGISTRY_CACHE[p.pid] = p
        end
    end
    p
end

function link(p::PotID, ch::RemoteChannel)
    POT_LINK_CACHE[p] = ch
    if myid() != 1
        remotecall_wait(1) do
            Oolong.POT_LINK_CACHE[p] = ch
        end
    end
end

function Base.getindex(p::PotID)
    get!(POT_LINK_CACHE, p) do
        ch = remotecall_wait(1) do
            get(Oolong.POT_LINK_CACHE, p, nothing)
        end
        if isnothing(ch[])
            boil(p[!])
        else
            ch[]
        end
    end
end

struct PotNotRegisteredError <: Exception
    pid::PotID
end

Base.showerror(io::IO, err::PotNotRegisteredError) = print(io, "can not find any pot associated with the pid: $(err.pid)")

function Base.getindex(p::PotID, ::typeof(!))
    get!(POT_REGISTRY_CACHE, p) do
        pot = remotecall_wait(1) do
            get(Oolong.POT_REGISTRY_CACHE, p, nothing)
        end
        if isnothing(pot[])
            throw(PotNotRegisteredError(p))
        else
            pot[]
        end
    end
end

function local_boil(p::Pot)
    pid, tea_bag = p.pid, p.tea_bag
    ch = RemoteChannel() do
        Channel(typemax(Int)) do ch
            task_local_storage(KEY, pid)
            tea = tea_bag()
            while true
                flavor = take!(ch)
                process(tea, flavor)
            end
        end
    end
    link(pid, ch)
    ch
end

boil(p::PotID) = boil(p[!])
boil(p::Pot) = SCHEDULER(p)[]

struct Scheduler
end

(s::Scheduler)(p::Pot) = local_boil(p)

whereis(p::PotID) = p[].where

#####
# Message passing
#####

struct CallMsg
    args
    kw
    future
end

function (p::PotID)(args...;kw...)
    f = Future(whereis(p))  # !!! the result should reside in the same place
    put!(p, CallMsg(args, kw.data, f))
    f
end

# ??? non specialized tea?
function process(tea, msg::CallMsg)
    res = tea(msg.args...;msg.kw...)
    put!(msg.future, res)
end

function Base.put!(p::PotID, flavor)
    try
        put!(p[], flavor)
    catch e
        # TODO add test
        if e isa PotNotRegisteredError
            rethrow(e)
        else
            @error e
            boil(p)
            put!(p, flavor)
        end
    end
end

#####
# System Initialization
#####

struct Root
    function Root()
        Pot(SCHEDULER, ()->Scheduler()) |> register |> local_boil
        new()
    end
end

function start()
    Pot(ROOT, ()->Root()) |> register |> local_boil
end
