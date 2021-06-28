@testset "serve" begin
    # q: request
    # p: reply
    # |: batch_wait_timeout_s reached

    @testset "batch_wait_timeout_s = 0" begin
        # case 1: qpqpqp
        struct DummyModel end

        function OL.handle(m::DummyModel, msg::OL.RequestMsg)
            xs = msg.msg
            @debug "value received in model" xs typeof(xs)
            sleep(0.1)
            res = vec(sum(xs; dims=1)) .+ 1
            OL.async_rep(msg.from, res)
        end
        model = @actor DummyModel() name="model" 

        server = @actor OL.BatchStrategy(model;max_batch_size=2) name="server" 

        worker = OL.Mailbox()
        t = @elapsed for i in 1:10
            put!(server,OL.RequestMsg([i], worker))
            sleep(0.11)
        end

        for i in 1:10
            msg = take!(worker)
            @test msg.msg == i+1
        end

        # case 2: qqqqqpqqqqp
        t = @elapsed begin
            for i in 1:5
                put!(server,OL.RequestMsg([i], worker))
            end
            for i in 1:5
                @test take!(worker).msg == i+1
            end
        end

        t = @elapsed begin
            for i in 1:64
                put!(server,OL.RequestMsg([i], worker))
            end
            for i in 1:64
                @test take!(worker).msg == i+1
            end
        end
    end

end