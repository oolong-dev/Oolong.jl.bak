using Oolong
using Test
using Base.Threads

@testset "Oolong.jl" begin
    include("core.jl")
    include("serve.jl")
end
