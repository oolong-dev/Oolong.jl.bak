const KEY = :OOLONG

"""
Similar to `Future`, but we added some customized methods.
"""
struct Promise
    f::Future
    function Promise(args...)
        new(Future(args...))
    end
end

Base.getindex(p::Promise) = getindex(p.f)
Base.wait(p::Promise) = wait(p.f)

"Recursively fetch inner value"
function Base.getindex(p::Promise, ::typeof(!))
    x = p.f[]
    while x isa Promise || x isa Future
        x = x[]
    end
    x
end

function Base.getindex(ps::Vector{Promise})
    res = Vector(undef, length(ps))
    @sync for (i, p) in enumerate(ps)
        Threads.@spawn begin
            res[i] = p[]
        end
    end
    res
end

struct TimeOutError{T} <: Exception
    t::T
end

Base.showerror(io::IO, err::TimeOutError) = print(io, "failed to complete in $(err.t) seconds")

"""
    p::Promise[t::Number]

Try to fetch value during a period of `t`.
A [`TimeOutError`](@ref) is thrown if the underlying data is still not ready after `t`.
"""
function Base.getindex(p::Promise, t::Number, pollint=0.1)
    res = timedwait(t;pollint=pollint) do
        isready(p)
    end
    if res === :ok
        p[]
    else
        throw(TimeOutError(t))
    end
end

Base.put!(p::Promise, x) = put!(p.f, x)
Base.isready(p::Promise) = isready(p.f)

#####

struct PotNotRegisteredError <: Exception
    pid::PotID
end

Base.showerror(io::IO, err::PotNotRegisteredError) = print(io, "can not find any pot associated with the pid: $(err.pid)")

#####

const RESOURCE_REGISTRY = Dict{Symbol, UInt}(
    :cpu => () -> Threads.nthreads(),
    :gpu => () -> length(CUDA.devices())
)

struct ResourceInfo{I<:NamedTuple}
    info::I
end

ResourceInfo() = ResourceInfo(NamedTuple(k=>v() for (k,v) in RESOURCE_REGISTRY))

ResourceInfo(;kw...) = ResourceInfo(kw.data)
Base.keys(r::ResourceInfo) = keys(r.info)
Base.getindex(r::ResourceInfo, x) = getindex(r.info, x)
Base.haskey(r::ResourceInfo, x) = haskey(r.info, x)

function Base.:(<=)(x::ResourceInfo, y::ResourceInfo)
    le = true
    for k in keys(x)
        if haskey(y, k) && x[k] <= y[k]
            continue
        else
            le = false
            break
        end
    end
    le
end

function Base.:(-)(x::ResourceInfo, y::ResourceInfo)
    merge(x, (k => x[k]-v for (k,v) in pairs(y)))
end

struct RequirementNotSatisfiedError <: Exception
    required::ResourceInfo
    remaining::ResourceInfo
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

"Similar to `RemoteException`, except that we need the `PotID` info."
struct Failure <: Exception
    pid::PotID
    captured::CapturedException
end

Failure(captured) = Failure(self(), captured)

is_prioritized(::Failure) = true

function Base.showerror(io::IO, f::Failure)
    println(io, "In pot $(f.pid) :")
    showerror(io, re.captured)
end
