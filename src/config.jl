using Configurations
using YAML

@option struct Config
    banner::Bool = Base.JLOptions().banner != 0
    color::Bool = Base.have_color
end