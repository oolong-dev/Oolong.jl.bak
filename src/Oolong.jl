module Oolong

const OL = Oolong
export OL

include("core.jl")
include("parameter_server.jl")
include("serve.jl")

function __init__()
    init()
end

end
