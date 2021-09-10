export @P_str, @pot

using Distributed
using UUIDs:uuid4
using Base.Threads
using CUDA
using Logging
using Dates

const KEY = :OOLONG

#####
# basic
#####

"""
Similar to `Future`, but it will unwrap inner `Future` or `Promise` recursively when trying to get the *promised* value.
"""
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

struct PotNotRegisteredError <: Exception
    pid::PotID
end

Base.showerror(io::IO, err::PotNotRegisteredError) = print(io, "can not find any pot associated with the pid: $(err.pid)")

#####

struct RequireInfo
    cpu::Float64
    gpu::Float64
end

Base.:(<=)(x::RequireInfo, y::RequireInfo) = x.cpu <= y.cpu && x.gpu <= y.gpu
Base.:(-)(x::RequireInfo, y::RequireInfo) = RequireInfo(x.cpu - y.cpu, x.gpu - y.gpu)

struct RequirementNotSatisfiedError <: Exception
    required::RequireInfo
    remaining::RequireInfo
end

Base.showerror(io::IO, err::RequirementNotSatisfiedError) = print(io, "required: $(err.required), remaining: $(err.remaining)")

#####

"System level messages are processed immediately"
abstract type AbstractSysMsg end

is_prioritized(msg) = false
is_prioritized(msg::AbstractSysMsg) = true

# !!! force system level messages to be executed immediately
# directly copied from
# https://github.com/JuliaLang/julia/blob/6aaedecc447e3d8226d5027fb13d0c3cbfbfea2a/base/channels.jl#L13-L31
# with minor modification
function Base.put_buffered(c::Channel, v)
    lock(c)
    try
        while length(c.data) == c.sz_max
            Base.check_channel_state(c)
            wait(c.cond_put)
        end
        if is_prioritized(v)
            pushfirst!(c.data, v)  # !!! force sys msg to be handled immediately
        else
            push!(c.data, v)  # !!! force sys msg to be handled immediately
        end
        # notify all, since some of the waiters may be on a "fetch" call.
        notify(c.cond_take, nothing, true, false)
    finally
        unlock(c)
    end
    return v
end

#####
# PotID
#####

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
        print(io, "/")
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
            self() / s
        end
    else
        PotID(())
    end
end

Base.:(/)(p::PotID, s::String) = PotID((getfield(p, :path)..., (Symbol(x) for x in split(s, '/';keepempty=false))...))

const ROOT = P"/"
const LOGGER = P"/log"
const SCHEDULER = P"/scheduler"
const USER = P"/user"

#####
# Message Processing
#####

process(tea, args...;kw...) = tea(args...;kw...)

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

#####

struct CallMsg{A}
    args::A
    kw
    promise
end

is_prioritized(::CallMsg{<:Tuple{<:AbstractSysMsg}}) = true

function (p::PotID)(args...;kw...)
    promise = Promise(whereis(p))  # !!! the result should reside in the same place
    put!(p, CallMsg(args, kw.data, promise))
    promise
end

# ??? non specialized tea?
function process(tea, msg::CallMsg)
    try
        res = process(tea, msg.args...;msg.kw...)
        put!(msg.promise, res)
    catch err
        # avoid dead lock
        put!(msg.promise, err)
    end
end

#####

function Base.:(|>)(x, p::PotID)
    put!(p, x)
    nothing
end

#####

struct GetPropMsg
    prop::Symbol
end

Base.getproperty(p::PotID, prop::Symbol) = p(GetPropMsg(prop))

process(tea, msg::GetPropMsg) = getproperty(tea, msg.prop)

##### SysMsg

"""
Signal a Pot to close the channel and release claimed resources.
By default, all children are closed recursively.
"""
struct CloseMsg <: AbstractSysMsg
end

Base.close(p::PotID) = p(CloseMsg())

function process(tea, ::CloseMsg)
    for c in children()
        c(CloseMsg())[]
    end
end

"""
Close the active channel and remove the registered `Pot`.
"""
struct RemoveMsg <: AbstractSysMsg
end

Base.rm(p::PotID) = p(RemoveMsg())

function process(tea, ::RemoveMsg)
    for c in children()
        c(RemoveMsg())[]
    end
    unregister(self())
end

struct ResumeMsg <: AbstractSysMsg
end

process(tea, ::ResumeMsg) = nothing

struct RestartMsg <: AbstractSysMsg
end

struct PreRestartMsg <: AbstractSysMsg
end

struct PostRestartMsg <: AbstractSysMsg
end

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

    printstyled(iob, "$(kw.datetime) "; color=:light_black)
    printstyled(iob, prefix; bold=true, color=color)
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

local_scheduler() = SCHEDULER/"local_scheduler_$(myid())"

Base.parent() = parent(self())
Base.parent(p::PotID) = PotID(getfield(p, :path[1:end-1]))

children() = children(self())

#####
# Pot Scheduling
#####

# TODO: set ttl?

"""
Local cache on each worker to reduce remote call.
The links may be staled.
"""
const POT_LINK_CACHE = Dict{PotID, RemoteChannel{Channel{Any}}}()

"""
Only valid on the driver to keep track of all registered pots.
TODO: use a kv db
"""
const POT_REGISTRY = Dict{PotID, Pot}()
const POT_CHILDREN = Dict{PotID, Set{PotID}}()

function is_registered(p::Pot)
    is_exist = remotecall_wait(1) do
        haskey(Oolong.POT_REGISTRY, p.pid)
    end
    is_exist[]
end

function register(p::Pot)
    remotecall_wait(1) do
        Oolong.POT_REGISTRY[p.pid] = p
        children = get!(Oolong.POT_CHILDREN, parent(p.pid), Set{PotID}())
        push!(children, p.pid)
    end
end

function unregister(p::PotID)
    remotecall_wait(1) do
        delete!(Oolong.POT_REGISTRY, p)
        delete!(Oolong.POT_CHILDREN, p)
    end
end

function children(p::PotID)
    remotecall_wait(1) do
        # ??? data race
        get!(Oolong.POT_CHILDREN, p, Set{PotID}())
    end
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
    pot = remotecall_wait(1) do
        get(Oolong.POT_REGISTRY, p, nothing)
    end
    if isnothing(pot[])
        throw(PotNotRegisteredError(p))
    else
        pot[]
    end
end

"""
For debug only. Only a snapshot is returned.
!!! DO NOT MODIFY THE RESULT DIRECTLY
"""
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
                        if flavor isa CloseMsg || flavor isa RemoveMsg
                            break
                        end
                    catch err
                        @debug err
                        flavor = parent()(err)[]
                        if msg isa ResumeMsg
                            process(tea, flavor)
                        elseif msg isa CloseMsg
                            process(tea, flavor)
                            break
                        elseif msg isa RestartMsg
                            process(tea, PreRestartMsg())
                            tea = tea_bag()
                            process(tea, PostRestartMsg())
                        else
                            @error "unknown msg received from parent: $exec"
                            rethrow()
                        end
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

function banner(io::IO=stdout;color=true)
    c = Base.text_colors
    tx = c[:normal] # text
    d1 = c[:bold] * c[:blue]    # first dot
    d2 = c[:bold] * c[:red]     # second dot
    d3 = c[:bold] * c[:green]   # third dot
    d4 = c[:bold] * c[:magenta] # fourth dot

    if color
        print(io,
        """
          ____        _                     |  > 是非成败转头空
         / $(d1)__$(tx) \\      | |                    |  > Success or failure,
        | $(d1)|  |$(tx) | ___ | | ___  _ __   __ _   |  > right or wrong,
        | $(d1)|  |$(tx) |/ $(d2)_$(tx) \\| |/ $(d3)_$(tx) \\| '_ \\ / $(d4)_$(tx)` |  |  > all turn out vain.
        | $(d1)|__|$(tx) | $(d2)(_)$(tx) | | $(d3)(_)$(tx) | | | | $(d4)(_)$(tx) |  |
         \\____/ \\___/|_|\\___/|_| |_|\\__, |  |  The Immortals by the River
                                     __/ |  |  -- Yang Shen 
                                    |___/   |  (Translated by Xu Yuanchong) 
        """)
    else
        print(io,
        """
          ____        _                     |  > 是非成败转头空
         / __ \\      | |                    |  > Success or failure,
        | |  | | ___ | | ___  _ __   __ _   |  > right or wrong,
        | |  | |/ _ \\| |/ _ \\| '_ \\ / _` |  |  > all turn out vain.
        | |__| | (_) | | (_) | | | | (_) |  |
         \\____/ \\___/|_|\\___/|_| |_|\\__, |  |  The Immortals by the River
                                     __/ |  |  -- Yang Shen 
                                    |___/   |  (Translated by Xu Yuanchong) 
        """)
    end
end

function start(config_file::String="Oolong.yaml";kw...)
    config = nothing
    if isfile(config_file)
        @info "Found $config_file. Loading configs..."
        config = Configurations.from_dict(Config, YAML.load_file(config_file; dicttype=Dict{String, Any});kw...)
    else
        @info "$config_file not found. Using default configs."
        config = Config(;kw...)
    end
    start(config)
end

function start(config::Config)
    config.banner && banner(color=config.color)

    @info "$(@__MODULE__) starting..."
    if myid() == 1
        local_boil(@pot Root() name=ROOT logger=current_logger())
    end

    if myid() in workers()
        local_boil(@pot LocalScheduler() name=local_scheduler())
    end
end

function stop()
end
