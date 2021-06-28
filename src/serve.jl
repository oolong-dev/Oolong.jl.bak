
# directly taken from https://github.com/FluxML/Flux.jl/blob/27c4c77dc5abd8e791f4ca4e68a65fc7a91ebcfd/src/utils.jl#L544-L566
batchindex(xs, i) = (reverse(Base.tail(reverse(axes(xs))))..., i)

function batch(xs)
  data = first(xs) isa AbstractArray ?
    similar(first(xs), size(first(xs))..., length(xs)) :
    Vector{eltype(xs)}(undef, length(xs))
  for (i, x) in enumerate(xs)
    data[batchindex(data, i)...] = x
  end
  return data
end

struct ProcessBatchMsg end

mutable struct BatchStrategy
    buffer::Vector{Any}
    reqs::Vector{Mailbox}
    model::Mailbox
    batch_wait_timeout_s::Float64
    max_batch_size::Int
    timer::Union{Nothing, Timer}
    n_ongoing_batches::Int
end

"""
    BatchStrategy(model;kwargs...)

# Keyword Arguments

- `model::Mailbox`, an actor which wraps the model. This actor must accepts
  [`RequestMsg`](@ref) as input and reply with a [`ReplyMsg`](@ref)
  correspondingly.
- `batch_wait_timeout_s=0.0`, time to wait before handling the next batch.
- `max_batch_size=8, the maximum batch size to handle each time.

Everytime we processed a batch, we create a timer and wait for at most
`batch_wait_timeout_s` to handle the next batch. If we get `max_batch_size`
requests before reaching `batch_wait_timeout_s`, the timer is reset. If
`batch_wait_timeout_s==0`, we process the available requests immediately.

!!! warning
    The `model` must reply in a non-blocking way (by using [`async_rep`](@ref) or).
    Otherwise, there may be deadlock (see test cases if you are interested).
"""
function BatchStrategy(
    model;
    batch_wait_timeout_s=0.0,
    max_batch_size=8,
)
    mb = self()
    if batch_wait_timeout_s == 0.
        timer = nothing
    else
        timer = Timer(batch_wait_timeout_s) do timer
            mb[ProcessBatchMsg()]
        end
    end
    BatchStrategy(
        Vector(),
        Vector{Mailbox}(),
        model,
        batch_wait_timeout_s,
        max_batch_size,
        nothing,
        0
    )
end

function reset_timer!(s::BatchStrategy)
    isnothing(s.timer) || close(s.timer)
    mb = self()
    s.timer = Timer(s.batch_wait_timeout_s) do t
        mb[ProcessBatchMsg()]
    end
end

function handle(s::BatchStrategy, req::RequestMsg)
    push!(s.buffer, req.msg)
    push!(s.reqs, req.from)

    if length(s.buffer) == 1
        if s.batch_wait_timeout_s == 0
            if s.n_ongoing_batches == 0
                s(ProcessBatchMsg())
            end
        else
            reset_timer!(s) # set a timer to insert a ProcessBatchMsg to self()
        end
    elseif length(s.buffer) == s.max_batch_size
        s(ProcessBatchMsg())
    end
end

function (s::BatchStrategy)(::ProcessBatchMsg)
    if !isempty(s.buffer)
        @info "???" s.buffer
        data = length(s.buffer) == 1 ? reshape(s.buffer[1], size(s.buffer[1])..., 1) : batch(s.buffer)
        empty!(s.buffer)
        s.n_ongoing_batches += 1
        req(s.model, data)
    end
end

function (s::BatchStrategy)(msg::ReplyMsg)
    for res in msg.msg
        rep(popfirst!(s.reqs), res)
    end
    s.n_ongoing_batches -= 1
    s(ProcessBatchMsg())
end

# X**