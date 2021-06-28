struct ParameterServer
    params
end

function (ps::ParameterServer)(gs)
    for (p, g) in zip(ps.params, gs)
        p .-= g
    end
end

(ps::ParameterServer)() = deepcopy(p.params)

# Example usage
# ```julia
# ps = @actor ParameterServer([zeros(Float32, 3, 4), zeros(Float32, 3)])
# for c in clients
#     params = ps()[]
#     gs = calc_gradients(params)
#     ps[gs]
# end
# ```