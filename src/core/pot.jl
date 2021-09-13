struct Pot
    tea_bag::Any
    pid::PotID
    require::ResourceInfo
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
    require = ResourceInfo(cpu, gpu)
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

mutable struct PotState
    pid::PotID
    ch::Channel
    create_time::DateTime
    last_update::DateTime
    n_processed::UInt
end

_self() = get!(task_local_storage(), KEY, PotState(USER, current_task()))
self() = _self().pid

local_scheduler() = SCHEDULER/"local_scheduler_$(myid())"

Base.parent() = parent(self())
Base.parent(p::PotID) = PotID(getfield(p, :path[1:end-1]))

children() = children(self())

