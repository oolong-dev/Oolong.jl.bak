using LoggingExtras
using LokiLogger
using Dates

# https://github.com/JuliaLang/julia/blob/1b93d53fc4bb59350ada898038ed4de2994cce33/base/logging.jl#L142-L151
function Base.parse(::Type{LogLevel}, s::String)
    if     s == string(Logging.BelowMinLevel) Logging.BelowMinLevel
    elseif s == string(Logging.Debug) Logging.Debug
    elseif s == string(Logging.Info) Logging.Info
    elseif s == string(Logging.Warn) Logging.Warn
    elseif s == string(Logging.Error) Logging.Error
    elseif s == string(Logging.AboveMaxLevel) Logging.AboveMaxLevel
    else
        m = match(r"LogLevel\((?<level>-?[1-9]\d*)\)", s)
        if isnothing(m)
            throw(ArgumentError("unknown log level"))
        else
            Logging.LogLevel(parse(Int, m[:level]))
        end
    end

end

function create_log_transformer(date_format)
    function transformer(log)
        merge(
            log,
            (
                datetime = Dates.format(now(), date_format),
                from=self(),
                myid=myid(),
            )
        )
    end
end

function create_default_fmt(with_color=false, is_expand_stack_trace=false)
    function default_fmt(iob, args)
        level, message, _module, group, id, file, line, kw = args
        color, prefix, suffix = Logging.default_metafmt(
            level, _module, group, id, file, line
        )
        ignore_fields = (:datetime, :path, :myid, :from)
        if with_color
            printstyled(iob, "$(kw.datetime) "; color=:light_black)
            printstyled(iob, prefix; bold=true, color=color)
            printstyled(iob, "[$(kw.from)@$(kw.myid)]"; color=:green)
            print(iob, message)
            for (k,v) in pairs(kw)
                if k ∉ ignore_fields
                    print(iob, " ")
                    printstyled(iob, k; color=:yellow)
                    printstyled(iob, "="; color=:light_black)
                    print(iob, v)
                end
            end
            !isempty(suffix) && printstyled(iob, " ($suffix)"; color=:light_black)
            println(iob)
        else
            print(iob, "$(kw.datetime) $prefix[$(kw.from)@$(kw.myid)]$message")
            for (k,v) in pairs(kw)
                if k ∉ ignore_fields
                    print(iob, " $k=$v")
                end
            end
            !isempty(suffix) && print(iob, " ($suffix)")
            println(iob)
        end
    end
end

function create_logger(config::Config)
    sinks = []

    if !isnothing(config.logging.loki_logger)
        push!(sinks, LokiLogger.Logger(config.logging.loki_logger.url))
    end

    if !isnothing(config.logging.driver_logger)
        driver_sinks = []
        console_logger_config = config.logging.driver_logger.console_logger
        if !isnothing(console_logger_config)
            push!(
                driver_sinks,
                FormatLogger(
                    create_default_fmt(
                        config.color,
                        console_logger_config.is_expand_stack_trace
                    )
                )
            )
        end
        rotating_logger_config = config.logging.driver_logger.rotating_logger
        if !isnothing(rotating_logger_config)
            mkpath(rotating_logger_config.path)
            push!(
                driver_sinks,
                DatetimeRotatingFileLogger(
                    create_default_fmt(),
                    rotating_logger_config.path,
                    rotating_logger_config.file_format,
                )
            )
        end
        if isempty(driver_sinks)
            push!(driver_sinks, current_logger())
        end
        push!(sinks, DriverLogger(TeeLogger(driver_sinks...)))
    end

    if isempty(sinks)
        push!(sinks, current_logger())
    end

    TeeLogger(
        (
            MinLevelLogger(
                TransformerLogger(
                    create_log_transformer(config.logging.date_format),
                    s
                ),
                parse(Logging.LogLevel, config.logging.log_level)
            )
            for s in sinks
        )...
    )
end

#####

Base.@kwdef struct DriverLogger <: AbstractLogger
    logger::TeeLogger
end

Logging.shouldlog(::DriverLogger, args...) = true
Logging.min_enabled_level(::DriverLogger) = Logging.BelowMinLevel
Logging.catch_exceptions(::DriverLogger) = true

struct LogMsg
    args
    kw
end

Logging.handle_message(logger::DriverLogger, args...; kw...) = LogMsg(args, kw) |> LOGGER

function (L::DriverLogger)(msg::LogMsg)
    handle_message(L.logger, msg.args...;msg.kw...)
end
