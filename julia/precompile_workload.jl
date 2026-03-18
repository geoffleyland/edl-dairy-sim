# Precompile workload for PackageCompiler sysimage.
#
# This file is run during the Docker build to warm up the code paths that
# matter for request latency. The more realistic the workload, the better
# the sysimage. Add to this as the application grows.

using Oxygen, HTTP, ArgParse, JSON3, Dates

# Warm up ArgParse — exercises the CLI parsing path.
let s = ArgParseSettings()
    @add_arg_table! s begin
        "--port"
            arg_type = Int
            default  = 8080
        "--loglevel"
            default  = "info"
    end
    ArgParse.parse_args(String[], s)
end

# Warm up JSON3 — exercises the serialisation path used by every response.
JSON3.write(Dict("status" => "ok", "time" => string(now())))
JSON3.read("""{"status":"ok","time":"2024-01-01T00:00:00"}""", Dict{String, Any})

# Warm up Oxygen by registering a route and making a real request.
# This compiles the route matching and response pipeline.
@get "/warmup" function (req::HTTP.Request)
    json(Dict("status" => "ok"))
end

let server = serve(async=true, port=9874)
    sleep(1)
    try
        HTTP.get("http://localhost:9874/warmup")
    catch e
        @warn "Precompile warmup request failed" exception=e
    end
    Oxygen.terminate()
end
