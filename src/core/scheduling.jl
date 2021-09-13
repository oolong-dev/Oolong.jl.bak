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
boil(p::PotID) = local_scheduler()(p)[!]

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

Base.convert(::Type{ResourceInfo}, r::ResourceInfo) = ResourceInfo(r.cpu.allocated_threads, length(r.gpu))

struct HeartBeat
    resource::ResourceInfo
    available::ResourceInfo
    from::PotID
end

struct LocalScheduler
    pending::Dict{PotID, Future}
    peers::Ref{Dict{PotID, ResourceInfo}}
    available::Ref{ResourceInfo}
    timer::Timer
end

# TODO: watch exit info

function LocalScheduler()
    pid = self()
    req = convert(ResourceInfo, ResourceInfo())
    available = Ref(req)
    timer = Timer(1;interval=1) do t
        HeartBeat(ResourceInfo(), available[], pid) |> SCHEDULER  # !!! non blocking
    end

    pending = Dict{PotID, Future}()
    peers = Ref(Dict{PotID, ResourceInfo}(pid => req))

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

function (s::LocalScheduler)(peers::Dict{PotID, ResourceInfo})
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


