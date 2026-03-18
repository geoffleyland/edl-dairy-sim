using ArgParse, Logging, Oxygen, HTTP

const LOG_LEVELS = Dict(
    "debug" => Logging.Debug,
    "info"  => Logging.Info,
    "warn"  => Logging.Warn,
    "error" => Logging.Error,
)

# Parses CLI args, validates them, initialises logging, and returns (port, data_dir).
# Exits with a clear message on bad input so nothing starts in a broken state.
function parse_cli_and_init_logging()
    s = ArgParseSettings(description="Dairy demo API server", version="0.1.0", add_version=true)
    @add_arg_table! s begin
        "--port", "-p"
            help     = "Port to listen on"
            default  = 8080
            arg_type = Int
        "--data-dir", "-d"
            help     = "Directory for JSON data files"
            default  = "data"
        "--loglevel", "-l"
            help     = "Log level: debug, info, warn, error"
            default  = "info"
    end
    args = ArgParse.parse_args(s)

    # Validate loglevel before init so we can use structured logging from here on.
    loglevel_key = lowercase(args["loglevel"])
    if !haskey(LOG_LEVELS, loglevel_key)
        println(stderr, "ERROR: unknown log level \"$(args["loglevel"])\". Valid levels: $(join(sort(collect(keys(LOG_LEVELS))), ", "))")
        exit(1)
    end
    global_logger(ConsoleLogger(stderr, LOG_LEVELS[loglevel_key]))

    # Resolve to an absolute path so log messages and the running server agree on location.
    data_dir = abspath(args["data-dir"])
    if !isdir(data_dir)
        @error "Data directory not found" data_dir
        exit(1)
    end

    return args["port"], data_dir
end

function start_server(port::Int, data_dir::String; async::Bool = false)
    register_routes(data_dir)
    @info "Dairy demo starting on port $port (data: $data_dir)"
    serve(host="0.0.0.0", port=port, async=async, middleware=[request_logging_middleware])
end
