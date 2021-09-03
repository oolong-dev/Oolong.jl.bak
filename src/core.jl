export @P_str, @pot

using Distributed
using UUIDs:uuid4
using Base.Threads
using CUDA
using Logging
using Dates

const KEY = :OOLONG

struct PotID
    path::Tuple{Vararg{Symbol}}
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
    if isempty(getfield(p, :path))
        print(io, '/')
    else
        for x in getfield(p, :path)
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
            self() * s
        end
    else
        PotID(())
    end
end

Base.:(*)(p::PotID, s::String) = PotID((getfield(p, :path)..., (Symbol(x) for x in split(s, '/';keepempty=false))...))

const ROOT = P"/"
const LOGGER = P"/log"
const SCHEDULER = P"/scheduler"
const USER = P"/user"


# struct Success{V}
#     value::V
# end

# Base.getindex(s::Success{<:Success}) = s.value[]
# Base.getindex(s::Success) = s.value

# struct Failure{E}
#     error::E
# end

# Failure() = Failure(nothing)

# Base.getindex(f::Failure{<:Failure}) = f.error[]
# Base.getindex(f::Failure) = f.error

"Similar to `Future`, but it will unwrap inner `Future` or `Promise` recursively."
struct Promise
    f::Future
    function Promise(args...)
        new(Future(args...))
    end
end

function Base.getindex(p::Promise)
    x = p.f[]
    while x isa Promise || x isa Future
        x = x[]
    end
    x
end

Base.put!(p::Promise, x) = put!(p.f, x)

#####
# Logging
#####

Base.@kwdef struct DefaultLogger <: AbstractLogger
    min_level::LogLevel = Logging.Debug
    date_format::Dates.DateFormat=Dates.default_format(DateTime)
end

Logging.shouldlog(::DefaultLogger, args...) = true
Logging.min_enabled_level(L::DefaultLogger) = L.min_level

const DEFAULT_LOGGER = DefaultLogger()

struct LogMsg
    args
    kw
end

function (L::DefaultLogger)(msg::LogMsg)
    args, kw = msg.args, msg.kw

    buf = IOBuffer()
    iob = IOContext(buf, stderr)

    level, message, _module, group, id, file, line = args

    color, prefix, suffix = Logging.default_metafmt(
        level, _module, group, id, file, line
    )

    printstyled(iob, prefix; bold=true, color=color)
    printstyled(iob, "$(kw.datetime)"; color=:light_black)
    printstyled(iob, "[$(kw.from)@$(kw.myid)]"; color=:green)
    print(iob, message)
    for (k,v) in pairs(kw)
        if k ∉ (:datetime, :path, :myid, :from)
            print(iob, " ")
            printstyled(iob, k; color=:yellow)
            printstyled(iob, "="; color=:light_black)
            print(iob, v)
        end
    end
    !isempty(suffix) && printstyled(iob, "($suffix)"; color=:light_black)
    println(iob)
    write(stderr, take!(buf))
end

function Logging.handle_message(logger::DefaultLogger, args...; kw...)
    kw = merge(
        kw.data,
        (
            datetime="$(Dates.format(now(), logger.date_format))",
            from=self(),
            myid=myid(),
        )
    )
    LogMsg(args, kw) |> LOGGER
end

#####
# Pot Definition
#####

struct RequireInfo
    cpu::Float64
    gpu::Float64
end

Base.:(<=)(x::RequireInfo, y::RequireInfo) = x.cpu <= y.cpu && x.gpu <= y.gpu
Base.:(-)(x::RequireInfo, y::RequireInfo) = RequireInfo(x.cpu - y.cpu, x.gpu - y.gpu)

struct Pot
    tea_bag::Any
    pid::PotID
    require::RequireInfo
    logger::Any
end

function Pot(
    tea_bag;
    name=string(uuid4()),
    cpu=eps(),
    gpu=0,
    logger=DEFAULT_LOGGER
)
    pid = name isa PotID ? name : PotID(name)
    require = RequireInfo(cpu, gpu)
    Pot(tea_bag, pid, require, logger)
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

struct PotState
    pid::PotID
    task::Task
end

_self() = get!(task_local_storage(), KEY, PotState(USER, current_task()))
self() = _self().pid

local_scheduler() = SCHEDULER*"local_scheduler_$(myid())"

Base.parent() = parent(self())
Base.parent(p::PotID) = PotID(getfield(p, :path[1:end-1]))

#####
# Exceptions
#####

struct PotNotRegisteredError <: Exception
    pid::PotID
end

Base.showerror(io::IO, err::PotNotRegisteredError) = print(io, "can not find any pot associated with the pid: $(err.pid)")

struct RequirementNotSatisfiedError <: Exception
    required::RequireInfo
    remaining::RequireInfo
end

Base.showerror(io::IO, err::RequirementNotSatisfiedError) = print(io, "required: $(err.required), remaining: $(err.remaining)")

#####
# Pot Scheduling
#####

# TODO: set ttl?

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
            boil(p)
        else
            ch[]
        end
    end
end

whereis(p::PotID) = p[].where

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

Base.getindex(p::PotID, ::typeof(*)) = p(_self())[]

local_boil(p::PotID) = local_boil(p[!])

function local_boil(p::Pot)
    pid, tea_bag, logger = p.pid, p.tea_bag, p.logger
    ch = RemoteChannel() do
        Channel(typemax(Int),spawn=true) do ch
            task_local_storage(KEY, PotState(pid, current_task()))
            with_logger(logger) do
                tea = tea_bag()
                while true
                    try
                        flavor = take!(ch)
                        process(tea, flavor)
                    catch err
                        @error err
                    finally
                    end
                end
            end
        end
    end
    link(pid, ch)
    ch
end

"blocking until a valid channel is established"
boil(p::PotID) = local_scheduler()(p)[]

struct CPUInfo
    total_threads::Int
    allocated_threads::Int
    total_memory::Int
    free_memory::Int
    function CPUInfo()
        new(
            Sys.CPU_THREADS,
            Threads.nthreads(),
            convert(Int, Sys.total_memory()),
            convert(Int, Sys.free_memory()),
        )
    end
end

struct GPUInfo
    name::String
    total_memory::Int
    free_memory::Int
    function GPUInfo()
        new(
            name(device()),
            CUDA.total_memory(),
            CUDA.available_memory()
        )
    end
end

struct ResourceInfo
    cpu::CPUInfo
    gpu::Vector{GPUInfo}
end

function ResourceInfo()
    cpu = CPUInfo()
    gpu = []
    if CUDA.functional()
        for d in devices()
            device!(d) do
                push!(gpu, GPUInfo())
            end
        end
    end
    ResourceInfo(cpu, gpu)
end

Base.convert(::Type{RequireInfo}, r::ResourceInfo) = RequireInfo(r.cpu.allocated_threads, length(r.gpu))

struct HeartBeat
    resource::ResourceInfo
    available::RequireInfo
    from::PotID
end

struct LocalScheduler
    pending::Dict{PotID, Future}
    peers::Ref{Dict{PotID, RequireInfo}}
    available::Ref{RequireInfo}
    timer::Timer
end

# TODO: watch exit info

function LocalScheduler()
    pid = self()
    req = convert(RequireInfo, ResourceInfo())
    available = Ref(req)
    timer = Timer(1;interval=1) do t
        HeartBeat(ResourceInfo(), available[], pid) |> SCHEDULER  # !!! non blocking
    end

    pending = Dict{PotID, Future}()
    peers = Ref(Dict{PotID, RequireInfo}(pid => req))

    LocalScheduler(pending, peers, available, timer)
end

function (s::LocalScheduler)(p::PotID)
    pot = p[!]
    if pot.require <= s.available[]
        res = local_boil(p)
        s.available[] -= pot.require
        res
    else
        res = Future()
        s.pending[p] = res
        res
    end
end

function (s::LocalScheduler)(peers::Dict{PotID, RequireInfo})
    s.peers[] = peers
    for (p, f) in s.pending
        pot = p[!]
        for (w, r) in peers
            if pot.require <= r
                # transfer to w
                put!(f, w(p))
                delete!(s.pending, p)
                break
            end
        end
    end
end

Base.@kwdef struct Scheduler
    workers::Dict{PotID, HeartBeat} = Dict()
    pending::Dict{PotID, Future} = Dict()
end

# ??? throttle
function (s::Scheduler)(h::HeartBeat)
    # ??? TTL
    s.workers[h.from] = h

    for (p, f) in s.pending
        pot = p[!]
        if pot.require <= h.available
            put!(f, h.from(p))
        end
    end

    Dict(
        p => h.available
        for (p, h) in s.workers
    ) |> h.from  # !!! non blocking
end

# pots are all scheduled on workers only
function (s::Scheduler)(p::PotID)
    pot = p[!]
    for (w, h) in s.workers
        if pot.require <= h.available
            return w(p)
        end
    end
    res = Future()
    s.pending[p] = res
    res
end

#####
# Message passing
#####

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

process(tea, flavor) = tea(flavor)

# CallMsg

struct CallMsg{A}
    args::A
    kw
    promise
end

function (p::PotID)(args...;kw...)
    promise = Promise(whereis(p))  # !!! the result should reside in the same place
    put!(p, CallMsg(args, kw.data, promise))
    promise
end

# ??? non specialized tea?
function process(tea, msg::CallMsg)
    try
        res = handle(tea, msg.args...;msg.kw...)
        put!(msg.promise, res)
    catch err
        # avoid dead lock
        put!(msg.promise, err)
    end
end

handle(tea, args...;kw...) = tea(args...;kw...)

# CastMsg

Base.:(|>)(x, p::PotID) = put!(p, x)

# GetPropMsg

struct GetPropMsg
    prop::Symbol
end

Base.getproperty(p::PotID, prop::Symbol) = p(GetPropMsg(prop))

handle(tea, msg::GetPropMsg) = getproperty(tea, msg.prop)

#####
# System Initialization
#####

## Root

struct Root
    function Root()
        local_boil(@pot DefaultLogger() name=LOGGER logger=current_logger())
        local_boil(@pot Scheduler() name=SCHEDULER)
        new()
    end
end

function start()
    @info "$(@__MODULE__) starting..."
    if myid() == 1
        local_boil(@pot Root() name=ROOT logger=current_logger())
    end

    if myid() in workers()
        local_boil(@pot LocalScheduler() name=local_scheduler())
    end
end
