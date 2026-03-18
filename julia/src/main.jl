include(joinpath(@__DIR__, "middleware.jl"))
include(joinpath(@__DIR__, "routes.jl"))
include(joinpath(@__DIR__, "server.jl"))

function main()
    port, data_dir = parse_cli_and_init_logging()
    start_server(port, data_dir)
end

main()
