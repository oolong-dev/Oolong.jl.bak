using Configurations
using YAML
using Logging
using Dates

@option struct ConsoleLoggerConfig
    is_expand_stack_trace::Bool = true
end

@option struct RotatingLoggerConfig
    path::String = "logs"
    file_format::String = raw"YYYY-mm-dd.\l\o\g"
end

@option struct DriverLoggerConfig
    console_logger::Union{ConsoleLoggerConfig, Nothing}=ConsoleLoggerConfig()
    rotating_logger::Union{RotatingLoggerConfig, Nothing}=RotatingLoggerConfig()
end

@option struct LokiLoggerConfig
    url::String = "http://127.0.0.1:3100"
end

@option struct LoggingConfig
    # filter
    log_level::String = "Info"
    # transformer
    date_format::String="yyyy-mm-ddTHH:MM:SS.s"
    # sink
    driver_logger::Union{DriverLoggerConfig, Nothing} = DriverLoggerConfig()
    loki_logger::Union{LokiLoggerConfig, Nothing} = nothing
end

@option struct Config
    banner::Bool = Base.JLOptions().banner != 0
    color::Bool = Base.have_color
    logging::LoggingConfig = LoggingConfig()
end