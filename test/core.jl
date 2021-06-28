@testset "function as actor" begin
    A = @actor () -> @info "Hello World!"
    @test isnothing(A[])
    @test isnothing(A()[])

    A = @actor msg -> @info "Hello " * msg
    @test isnothing(A["World!"])
    @test isnothing(A("World!")[])
    
    A = @actor msg -> "Hello " * msg
    @test isnothing(A["World!"])
    @test A("World!")[] == "Hello World!"
end

@testset "struct as actor" begin
    Base.@kwdef mutable struct Counter
        n::Int = 0
    end

    (c::Counter)() = c.n += 1

    A = @actor Counter() name="counter"

    @test nameof(A) == "counter"

    Threads.@threads for _ in 1:1_000
        A[]
    end

    @test A.n[] == 1_000

    Threads.@threads for _ in 1:1_000
        A()
    end

    @test A.n[] == 2_000
end

@testset "SysMsg is processed immediately" begin
    Base.@kwdef struct TestSysMsgArrival
        msgs::Vector{Int} = []
    end

    OL.handle(a::TestSysMsgArrival, ::OL.StartMsg) = push!(a.msgs, 0)
    function (a::TestSysMsgArrival)(i::Int)
        sleep(0.1)
        push!(a.msgs, i)
    end

    A = @actor TestSysMsgArrival()

    begin
        A[1]
        A[2]
        A[3]
        A[OL.StartMsg(nothing)]
    end
    @test A.msgs[] == [1,0,2,3]
end

@testset "Error handling" begin
    A = @actor iseven
    @test A(2)[] == true
    @test_throws MethodError A(:x)[]
    # the actor now should have restarted
    @test A(2)[] == true
end