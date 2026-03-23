# Development entry point — file-watcher hot-reload.
#
# Start with:
#   ./admin julia
#
# Changes to julia/src/ hot-reload the Oxygen server (routes, middleware).
# Changes to examples/Yield.jl/src/ require a full Julia process restart because
# compiled packages cannot be hot-reloaded.  This script exits with code 0 when
# a Yield.jl source file changes; the admin restart loop restarts it automatically.
#
# Call restart!() from the REPL to force a hot-reload at any time.

using FileWatching

const SRC_DIR      = @__DIR__
const YIELD_SRC    = joinpath(SRC_DIR, "..", "..", "examples", "Yield.jl", "src")

include(joinpath(SRC_DIR, "server.jl"))   # provides parse_cli_and_init_logging, start_server

port, data_dir = parse_cli_and_init_logging()

function restart!()
    try Oxygen.terminate() catch end
    sleep(0.3)   # let the old server release the port before rebinding
    include(joinpath(SRC_DIR, "middleware.jl"))
    include(joinpath(SRC_DIR, "routes.jl"))
    try
        Base.invokelatest(start_server, port, data_dir, async=true)
    catch e
        @error "Failed to restart server" exception=(e, catch_backtrace())
    end
end

# Hot-reload watcher: re-include routes/middleware on changes to julia/src/.
@async while true
    changed, _ = watch_folder(SRC_DIR)
    (!endswith(changed, ".jl") || changed ∈ ("dev.jl", "server.jl")) && continue
    @info "$(changed) changed — restarting"
    restart!()
end

# Full-restart watcher: exit when Yield.jl source changes so the admin loop
# restarts the whole process and Julia recompiles the package from scratch.
@async while true
    changed, _ = watch_folder(YIELD_SRC)
    endswith(changed, ".jl") || continue
    @info "$(changed) changed in Yield.jl — exiting for full process restart"
    exit(1)
end

restart!()
