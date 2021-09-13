process(tea, args...;kw...) = tea(args...;kw...)

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
        ce = CapturedException(err, catch_backtrace())
        put!(msg.promise, Failure(ce))
        rethrow(err)
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

struct Exit
end

const EXIT = Exit()

"""
    CloseWhenIdleMsg(t::Int)

Signal a Pot and its children to close the channel and release claimed resources if the Pot has been idle for `t` seconds.
"""
struct CloseWhenIdleMsg <: AbstractSysMsg
    t::Int
end

function process(tea, msg::CloseWhenIdleMsg)
    t_idle = (now() - _self().last_update) / Millisecond(1_000)
    if t_idle >= msg.t && isempty(_self().ch)
        for c in children()
            msg |> c
        end
        EXIT
    end
end

#####

"""
Close the active channel and remove the registered `Pot`.
"""
struct RemoveMsg <: AbstractSysMsg
end

Base.rm(p::PotID) = p(RemoveMsg())

function process(tea, msg::RemoveMsg)
    # !!! note the order
    for c in children()
        c(msg)[]
    end
    unregister(self())
    close(_self().ch)
    EXIT
end

#####

struct ResumeMsg <: AbstractSysMsg
end

process(tea, ::ResumeMsg) = nothing

#####

struct RestartMsg <: AbstractSysMsg
end

const RESTART = RestartMsg()

process(tea, ::RestartMsg) = RESTART

struct PreRestartMsg <: AbstractSysMsg
end

process(tea, ::PreRestartMsg) = nothing

struct PostRestartMsg <: AbstractSysMsg
end

process(tea, ::PostRestartMsg) = nothing

process(tea, ::Failure) = RESTART

