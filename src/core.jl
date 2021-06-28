export @actor

using Base.Threads
using Distributed
using Dates
using Logging

const ACTOR_KEY = "OOLONG"

#####
# System Messages
#####

abstract type AbstractSysMsg end

struct SuccessMsg{M} <: AbstractSysMsg
    msg::M
end

struct FailureMsg{R} <: AbstractSysMsg
    reason::R
end

Base.getindex(msg::FailureMsg) = msg.reason

Base.@kwdef struct StartMsg{F} <: AbstractSysMsg
    info::F = nothing
end

struct StopMsg{R} <: AbstractSysMsg
    reason::R
end

struct RestartMsg <: AbstractSysMsg end
struct PreRestartMsg <: AbstractSysMsg end
struct PostRestartMsg <: AbstractSysMsg end
struct ResumeMsg <: AbstractSysMsg end

struct StatMsg <: AbstractSysMsg end

struct FutureWrapper
    f::Future
    FutureWrapper(args...) = new(Future(args...))
end

function Base.getindex(f::FutureWrapper)
    res = getindex(f.f)
    if res isa SuccessMsg
        res.msg
    elseif res isa FailureMsg{<:Exception}
        throw(res.reason)
    else
        res
    end
end

Base.put!(f::FutureWrapper, x) = put!(f.f, x)

#####
# Mailbox
#####

struct Mailbox
    ch::RemoteChannel
end

const DEFAULT_MAILBOX_SIZE = typemax(Int)

Mailbox(; size=DEFAULT_MAILBOX_SIZE, pid=myid()) = Mailbox(RemoteChannel(() -> Channel(size), pid))

Base.take!(m::Mailbox) = take!(getfield(m, :ch))

Base.put!(m::Mailbox, msg) = put!(getfield(m, :ch), msg)

whereis(m::Mailbox) = getfield(m, :ch).where

#=
Actor Hierarchy

NOBODY
  └── ROOT
      ├── LOGGER
      ├── SCHEDULER
      |   ├── WORKER_1
      |   ├── ...
      |   └── WORKER_N
      └── USER
          ├── foo
          └── bar
              └── baz
=#

struct NoBody end
const NOBODY = NoBody()

struct RootActor end
const ROOT_ACTOR = RootActor()
const ROOT = Ref{Mailbox}()

struct SchedulerActor end
const SCHEDULER_ACTOR = SchedulerActor()
const SCHEDULER = Ref{Mailbox}()

struct SchedulerWorker
end

struct StagingActor end

struct UserActor end
const USER_ACTOR = UserActor()
const USER = Ref{Mailbox}()

struct LoggerActor end
const LOGGER_ACTOR = LoggerActor()
const LOGGER = Ref{Mailbox}()

#####
# RemoteLogger
#####

struct RemoteLogger <: AbstractLogger
    mailbox
    min_level
end

struct LogMsg
    args
    kwargs
end

const DATE_FORMAT = "yyyy-mm-dd HH:MM:SS"

function Logging.handle_message(logger::RemoteLogger, args...; kwargs...)
    kwargs = merge(kwargs.data,(
        datetime="$(Dates.format(now(), DATE_FORMAT))",
        path=_self().path
    ))
    logger.mailbox[LogMsg(args, kwargs)]
end

Logging.shouldlog(::RemoteLogger, args...) = true
Logging.min_enabled_level(L::RemoteLogger) = L.min_level

#####
# Actor
#####

Base.@kwdef struct Actor
    path::String
    thunk::Any
    owner::Union{NoBody,Mailbox}
    children::Dict{String,Mailbox}
    taskref::Ref{Task}
    mailbox::Ref{Mailbox}
    mailbox_size::Int
end

Base.nameof(a::Actor) = basename(a.path)

function Actor(
    thunk;
    owner=self(),
    children=Dict{String,Mailbox}(),
    name=string(nameof(thunk)),
    path=(isnothing(_self()) ? "/user" : _self().name) * "/" * name,
    mailbox=nothing,
    mailbox_size=DEFAULT_MAILBOX_SIZE,
)
    return Actor(
        path,
        thunk,
        owner,
        children,
        Ref{Task}(),
        isnothing(mailbox) ? Ref{Mailbox}() : Ref{Mailbox}(mailbox),
        mailbox_size
    )
end

function act(A)
    logger = isassigned(LOGGER) ? RemoteLogger(LOGGER[], Logging.Debug) : global_logger()
    with_logger(logger) do
        handler = A.thunk()
        while true
            try
                msg = take!(A.mailbox[])
                handle(handler, msg)
                msg isa StopMsg && break
            catch exec
                @error exec
                for (exc, bt) in Base.catch_stack()
                   showerror(stdout, exc, bt)
                   println(stdout)
                end
                action = A.owner(FailureMsg(exec))[]
                if action isa ResumeMsg
                    handle(handler, action)
                    continue
                elseif action isa StopMsg
                    handle(handler, action)
                    rethrow()
                elseif action isa RestartMsg
                    handle(handler, PreRestartMsg())
                    handler = A.thunk()
                    handle(handler, PostRestartMsg())
                else
                    @error "unknown msg received from $(dirname(nameof(A))): $exec"
                    rethrow()
                end
            end
        end
    end
end

"""
Get the [`Mailbox`](@ref) in the current task.

!!! note
    `self()` in the REPL is bind to `USER`.
"""
function self()
    A = _self()
    return isnothing(A) ? USER[] : A.mailbox[]
end

function _self()
    try
        task_local_storage(ACTOR_KEY)
    catch ex
        if ex isa KeyError
            nothing
        else
            rethrow()
        end
    end
end

function _schedule(A::Actor)
    if !isassigned(A.mailbox)
        A.mailbox[] = Mailbox(;size=A.mailbox_size)
    end
    A.taskref[] = Threads.@spawn begin
        task_local_storage(ACTOR_KEY, A)
        act(A)
    end
    return A.mailbox[]
end

struct ScheduleMsg <: AbstractSysMsg
    actor::Actor
end

function Base.schedule(A::Actor)
    s = _self()
    if isnothing(s)
        if A.owner === NOBODY
            _schedule(A)
        else
            # the actor is submitted from REPL
            # we schedule the actor through USER so that it will be bind to USER
            USER[](ScheduleMsg(A))[]
        end
    else
        if A.owner === ROOT[]
            mailbox = _schedule(A)
        else
            mailbox = SCHEDULER[](ScheduleMsg(A))[]
        end
        s.children[nameof(A)] = mailbox
        mailbox
    end
end


macro actor(exs...)
    a = exs[1]
    name = if a isa Symbol
        string(a)
    elseif a isa Expr && a.head == :call
        string(a.args[1])
    else
        nothing
    end

    default_kw = isnothing(name) ? (;) : (;name=name)
    thunk = esc(:(() -> ($(a))))
    kwargs = [esc(x) for x in exs[2:end]]
    kw = :(merge($default_kw, (;$(kwargs...))))
    
    quote
        schedule(Actor($thunk; $kw...))
    end
end

#####
# System Behaviors
#####
function handle(x, args...;kwargs...)
    x(args...;kwargs...)
end

function handle(x, ::FailureMsg)
    RestartMsg()
end

function handle(x, ::PreRestartMsg)
    @debug "stopping children before restart"
    handle(x, StopMsg("stop before restart"))
end

function handle(x, ::PostRestartMsg)
    @debug "starting after restart signal"
    handle(x, StartMsg(:restart))
end

function handle(x, msg::StartMsg)
    @debug "start msg received"
end

function handle(x, msg::StopMsg)
    for c in values(_self().children)
        c(msg)[]  # ??? blocking
    end
end

struct ActorStat
    path::String
end

function handle(x, ::StatMsg)
    s = _self()
    ActorStat(
        s.path
    )
end

Base.stat(m::Mailbox) = m(StatMsg())[]
Base.pathof(m::Mailbox) = stat(m).path
Base.nameof(m::Mailbox) = basename(pathof(m))

function handle(::RootActor, s::StartMsg)
    @info "$(@__MODULE__) starting..."
    LOGGER[] = @actor LOGGER_ACTOR path="/logger"
    LOGGER[](s)[]  # blocking to ensure LOGGER has started
    SCHEDULER[] = @actor SCHEDULER_ACTOR path="/scheduler" 
    SCHEDULER[](s)[]  # blocking to ensure SCHEDULER has started
    USER[] = @actor USER_ACTOR path = "/user"
    USER[](s)[]  # blocking to ensure USER has started
end

function handle(::LoggerActor, ::StartMsg)
    @info "LOGGER started"
end

function handle(L::LoggerActor, msg::LogMsg)
    buf = IOBuffer()
    iob = IOContext(buf, stderr)

    level, message, _module, group, id, file, line = msg.args

    color, prefix, suffix = Logging.default_metafmt(
        level, _module, group, id, file, line
    )
    printstyled(iob, prefix; bold=true, color=color)
    printstyled(iob, "[$(msg.kwargs.datetime)]"; color=:light_black)
    printstyled(iob, "(@$(msg.kwargs.path))"; color=:green)
    print(iob, message)
    for (k,v) in pairs(msg.kwargs)
        if k ∉ (:datetime, :path)
            print(iob, " ")
            printstyled(iob, k; color=:yellow)
            print(iob, "=")
            print(iob, v)
        end
    end
    !isempty(suffix) && printstyled(iob, "($suffix)"; color=:light_black)
    println(iob)
    write(stderr, take!(buf))
end

function handle(::SchedulerActor, ::StartMsg)
    @info "SCHEDULER started"
end

function handle(::SchedulerActor, msg::ScheduleMsg)
    # TODO: schedule it smartly based on workers' status
    @debug "scheduling $(nameof(msg.actor))"
    _schedule(msg.actor)
end

function handle(::UserActor, ::StartMsg)
    @info "USER started"
end

function handle(::UserActor, s::ScheduleMsg)
    mailbox = SCHEDULER[](s)[]
    _self().children[nameof(s.actor)] = mailbox
end

#####
# Syntax Sugar
#####

#####

struct CallMsg{T}
    args::T
    kwargs
    value_box
end

function handle(x, c::CallMsg)
    try
        put!(c.value_box, SuccessMsg(handle(x, c.args...; c.kwargs...)))
    catch exec
        put!(c.value_box, FailureMsg(exec))
        rethrow()
    end
    nothing
end

function (m::Mailbox)(args...;kwargs...)
    value_box = FutureWrapper(whereis(m))
    msg = CallMsg(args, kwargs, value_box)
    put!(m, msg)
    value_box
end

#####

struct CastMsg{T}
    args::T
end

handle(x, c::CastMsg) = handle(x, c.args...)

function Base.getindex(m::Mailbox, args...)
    put!(m, CastMsg(args))
    nothing
end

#####

struct GetPropMsg
    name::Symbol
    value_box::FutureWrapper
end

handle(x, p::GetPropMsg) = put!(p.value_box, getproperty(x, p.name))

function Base.getproperty(m::Mailbox, name::Symbol)
    res = FutureWrapper(whereis(m))
    put!(m, GetPropMsg(name, res))
    res
end

#####

Base.@kwdef struct RequestMsg{M}
    msg::M
    from::Mailbox = self()
end

Base.@kwdef struct ReplyMsg{M}
    msg::M
    from::Mailbox = self()
end

req(x::Mailbox, msg) = put!(x, RequestMsg(msg=msg))
rep(x::Mailbox, msg) = put!(x, ReplyMsg(msg=msg))
async_req(x::Mailbox, msg) = Threads.@spawn put!(x, RequestMsg(msg=msg))
async_rep(x::Mailbox, msg) = Threads.@spawn put!(x, ReplyMsg(msg=msg))

handle(x, req::RequestMsg) = rep(req.from, handle(x, req.msg))

# !!! force system level messages to be executed immediately
# directly copied from
# https://github.com/JuliaLang/julia/blob/6aaedecc447e3d8226d5027fb13d0c3cbfbfea2a/base/channels.jl#L13-L31
# with minor modification
function Base.put_buffered(
    c::Channel,
    v::Union{
        AbstractSysMsg,
        CallMsg{<:Tuple{<:AbstractSysMsg}},
        CastMsg{<:Tuple{<:AbstractSysMsg}}
        }
)
    lock(c)
    try
        while length(c.data) == c.sz_max
            Base.check_channel_state(c)
            wait(c.cond_put)
        end
        pushfirst!(c.data, v)  # !!! force sys msg to be handled immediately
        # notify all, since some of the waiters may be on a "fetch" call.
        notify(c.cond_take, nothing, true, false)
    finally
        unlock(c)
    end
    return v
end

# !!! This should be called ONLY once
function init()
    ROOT[] = @actor ROOT_ACTOR owner=NOBODY path="/"
    ROOT[](StartMsg(nothing))[]  # blocking is required
end
