using Test, HTTP, JSON3, Yield, DataStructures

const SRC_DIR  = joinpath(@__DIR__, "..", "src")
const TEST_DIR = @__DIR__

include(joinpath(SRC_DIR, "routes.jl"))

# ── Test helpers ───────────────────────────────────────────────────────────────

get_req()        = HTTP.Request("GET", "/")
post_req(body)   = HTTP.Request("POST", "/", [], Vector{UInt8}(JSON3.write(body)))
resp_json(resp)  = JSON3.read(String(resp.body))

# ── Test suite ─────────────────────────────────────────────────────────────────

function run_tests()
    @testset "Dairy Demo" begin

        @testset "site_config" begin
            mktempdir() do dir
                @test site_config(get_req(), dir).status == 404

                write(joinpath(dir, "site.json"), JSON3.write(Dict("site_name" => "Test")))
                resp = site_config(get_req(), dir)
                @test resp.status == 200
                @test resp_json(resp)["site_name"] == "Test"
            end
        end

        @testset "yield_calc" begin
            separation_config = Dict(
                "components"   => ["fat", "protein", "lactose"],
                "quantities"   => Dict("milk" => 1.0),
                "compositions" => Dict(
                    "milk"  => Dict("fat" => 0.043, "protein" => 0.034, "lactose" => 0.049),
                    "skim"  => Dict("fat" => 0.001),
                    "cream" => Dict("fat" => 0.400),
                ),
                "operations" => [Dict(
                    "operation"            => "separation",
                    "input"                => "milk",
                    "outputs"              => ["skim", "cream"],
                    "separation-component" => "fat",
                    "name"                 => "Separator",
                )],
            )

            @testset "rejects invalid JSON" begin
                bad = HTTP.Request("POST", "/yield", [], b"not json")
                @test yield_calc(bad).status == 400
            end

            @testset "returns streams and sankey for a valid config" begin
                resp = yield_calc(post_req(separation_config))
                @test resp.status == 200
                body = resp_json(resp)
                @test haskey(body, "streams")
                @test haskey(body, "sankey")
                # Mass balance: skim + cream ≈ milk
                skim  = body["streams"]["skim"]["quantity"]
                cream = body["streams"]["cream"]["quantity"]
                milk  = body["streams"]["milk"]["quantity"]
                @test milk ≈ 1.0
                @test skim + cream ≈ 1.0 atol=1e-4
                # Fat targets honoured
                @test body["streams"]["skim"]["fat"]  ≈ 0.001 atol=1e-5
                @test body["streams"]["cream"]["fat"] ≈ 0.400 atol=1e-5
            end

            @testset "sankey uses operation name field" begin
                resp  = yield_calc(post_req(separation_config))
                links = resp_json(resp)["sankey"]["links"]
                names = Set(vcat([[l["source"], l["target"]] for l in links]...))
                @test "Separator" ∈ names
            end

            @testset "sankey has nodes and non-empty links" begin
                resp   = yield_calc(post_req(separation_config))
                sankey = resp_json(resp)["sankey"]
                @test haskey(sankey, "nodes")
                @test haskey(sankey, "links")
                @test length(sankey["links"]) > 0
            end
        end

        @testset "Yield.compute — separation smoke test" begin
            config = Dict(
                "components"   => ["fat", "protein", "lactose"],
                "quantities"   => Dict("milk" => 1.0),
                "compositions" => Dict(
                    "milk"  => Dict("fat" => 0.03, "protein" => 0.03, "lactose" => 0.03),
                    "skim"  => Dict("fat" => 0.0001),
                    "cream" => Dict("fat" => 0.42),
                ),
                "operations" => [Dict(
                    "operation"            => "separation",
                    "input"                => "milk",
                    "outputs"              => ["skim", "cream"],
                    "separation-component" => "fat",
                )],
            )
            quantities, compositions = Yield.compute(config)
            @test quantities["milk"] ≈ 1.0
            @test quantities["skim"] + quantities["cream"] ≈ 1.0
            @test compositions["skim"]["fat"]  ≈ 0.0001 atol=1e-6
            @test compositions["cream"]["fat"] ≈ 0.42   atol=1e-6
        end

        @testset "simulation" begin

            # Minimal effects table: one machine with one mode.
            sep_effects = Dict{String, Dict{String, Dict{String, Float64}}}(
                "sep" => Dict("running" => Dict(
                    "raw-milk" => -1000.0,
                    "skim"     => +900.0,
                    "cream"    => +100.0,
                )),
            )
            no_params = Dict{String, Dict{String, Any}}()

            @testset "silo levels change correctly" begin
                intakes = [Intake("raw-milk", 0.0, 10.0, 1000.0)]
                blocks  = [Block("sep", "running", 0.0, 10.0)]
                init    = Dict("raw-milk" => 0.0, "skim" => 0.0, "cream" => 0.0)
                cap     = Dict("raw-milk" => 200_000.0, "skim" => 100_000.0, "cream" => 50_000.0)

                r = simulate(intakes, blocks, init, cap, sep_effects, no_params, 10.0)
                last = r.snapshots[end]

                # Intake exactly matches outflow — raw-milk stays near 0.
                @test last.levels["raw-milk"] ≈ 0.0  atol=1e-6
                @test last.levels["skim"]     ≈ 9000.0 atol=1e-6
                @test last.levels["cream"]    ≈ 1000.0 atol=1e-6
            end

            @testset "machine off after block ends" begin
                blocks = [Block("sep", "running", 0.0, 5.0)]
                init   = Dict("raw-milk" => 50_000.0, "skim" => 0.0, "cream" => 0.0)
                cap    = Dict("raw-milk" => 200_000.0, "skim" => 100_000.0, "cream" => 50_000.0)

                r = simulate(Intake[], blocks, init, cap, sep_effects, no_params, 10.0)
                last = r.snapshots[end]

                # Separator ran for 5 hr only: skim = 900*5 = 4500
                @test last.levels["skim"]  ≈ 4500.0 atol=1e-6
                @test last.levels["cream"] ≈  500.0 atol=1e-6
            end

            @testset "silo clamped at capacity" begin
                init = Dict("raw-milk" => 200_000.0, "skim" => 0.0, "cream" => 50_000.0)
                cap  = Dict("raw-milk" => 200_000.0, "skim" => 100_000.0, "cream" => 50_000.0)

                # Run long enough to fill skim beyond its 100_000 kg capacity.
                r = simulate(Intake[], [Block("sep", "running", 0.0, 200.0)], init, cap, sep_effects, no_params, 200.0)
                last = r.snapshots[end]
                @test last.levels["skim"] ≤ 100_000.0
            end

            @testset "auto-clean fires at max_run_hours" begin
                cond_effects = Dict{String, Dict{String, Dict{String, Float64}}}(
                    "cond" => Dict("skim" => Dict("skim" => -100.0, "condensed-skim" => +50.0)),
                )
                params = Dict{String, Dict{String, Any}}(
                    "cond" => Dict{String, Any}("max_run_hours" => 20.0, "clean_hours" => 4.0),
                )
                blocks = [Block("cond", "skim", 0.0, 25.0)]
                init   = Dict("skim" => 200_000.0, "condensed-skim" => 0.0)
                cap    = Dict("skim" => 200_000.0, "condensed-skim" => 30_000.0)

                r = simulate(Intake[], blocks, init, cap, cond_effects, params, 25.0)

                cleans = filter(e -> e.event == "clean-start", r.log)
                ends   = filter(e -> e.event == "clean-end",   r.log)
                @test length(cleans) == 1
                @test cleans[1].time_hr ≈ 20.0 atol=1e-9
                @test ends[1].time_hr   ≈ 24.0 atol=1e-9

                # Machine should be back in "skim" mode after clean.
                resume = filter(e -> e.event == "clean-end", r.log)
                @test resume[1].mode == "skim"
            end

            @testset "compute_effects separator" begin
                machines = [Dict{String, Any}(
                    "id"               => "sep",
                    "type"             => "separator",
                    "rate_kg_per_hour" => 20000,
                )]
                # Yield result: per 1 kg milk → 0.9 skim, 0.1 cream
                quantities = Dict("milk" => 1.0, "skim" => 0.9, "cream" => 0.1)

                fx = compute_effects(machines, quantities)
                sep_fx = fx["sep"]["running"]
                @test sep_fx["raw-milk"] ≈ -20000.0
                @test sep_fx["skim"]     ≈ +18000.0
                @test sep_fx["cream"]    ≈  +2000.0
            end

        end

        @testset "simulate_run" begin
            sep_site = Dict(
                "machines" => [Dict(
                    "id" => "sep", "name" => "Separator",
                    "type" => "separator", "rate_kg_per_hour" => 1000,
                )],
                "silos" => [
                    Dict("id" => "raw-milk", "volume_kg" => 200_000, "initial_kg" => 10_000),
                    Dict("id" => "skim",     "volume_kg" => 100_000, "initial_kg" => 0),
                    Dict("id" => "cream",    "volume_kg" =>  50_000, "initial_kg" => 0),
                ],
            )
            sep_process = Dict(
                "components"   => ["fat"],
                "quantities"   => Dict("milk" => 1.0),
                "compositions" => Dict(
                    "milk"  => Dict("fat" => 0.043),
                    "skim"  => Dict("fat" => 0.001),
                    "cream" => Dict("fat" => 0.400),
                ),
                "operations" => [Dict(
                    "operation" => "separation", "input" => "milk",
                    "outputs" => ["skim", "cream"], "separation-component" => "fat",
                    "name" => "Separator",
                )],
            )

            @testset "returns snapshots and log" begin
                mktempdir() do dir
                    write(joinpath(dir, "site.json"), JSON3.write(sep_site))
                    body = Dict(
                        "process"    => sep_process,
                        "intakes"    => [],
                        "blocks"     => [Dict("machine_id" => "sep", "mode" => "running", "start_hr" => 0.0, "end_hr" => 1.0)],
                        "horizon_hr" => 1.0,
                    )
                    resp = simulate_run(post_req(body), dir)
                    @test resp.status == 200
                    r = resp_json(resp)
                    @test haskey(r, "snapshots")
                    @test haskey(r, "log")
                    @test haskey(r, "effects")
                    @test length(r["snapshots"]) > 1
                end
            end

            @testset "silo levels change over horizon" begin
                mktempdir() do dir
                    write(joinpath(dir, "site.json"), JSON3.write(sep_site))
                    body = Dict(
                        "process"    => sep_process,
                        "intakes"    => [Dict("silo_id" => "raw-milk", "start_hr" => 0.0, "end_hr" => 2.0, "rate_kg_per_hr" => 1000.0)],
                        "blocks"     => [Dict("machine_id" => "sep", "mode" => "running", "start_hr" => 0.0, "end_hr" => 2.0)],
                        "horizon_hr" => 2.0,
                    )
                    resp = simulate_run(post_req(body), dir)
                    @test resp.status == 200
                    r    = resp_json(resp)
                    last = r["snapshots"][end]
                    # Separator consumes raw-milk at 1000 kg/hr; intake adds 1000 kg/hr → net zero
                    @test last["levels"]["raw-milk"] ≈ 10_000.0 atol=1.0
                    @test last["levels"]["skim"]     > 0
                    @test last["levels"]["cream"]    > 0
                end
            end

            @testset "rejects missing process key" begin
                mktempdir() do dir
                    write(joinpath(dir, "site.json"), JSON3.write(sep_site))
                    resp = simulate_run(post_req(Dict("horizon_hr" => 1.0)), dir)
                    @test resp.status == 400
                end
            end
        end

        # DB integration tests are guarded by DATABASE_URL — see architecture.md.
        if haskey(ENV, "DATABASE_URL")
            @testset "DB integration" begin
                # DB tests go here.
            end
        else
            @info "Skipping DB tests (no DATABASE_URL set)"
        end

    end
end

# ── Entry point ────────────────────────────────────────────────────────────────

if "--watch" ∈ ARGS || "-w" ∈ ARGS
    using FileWatching
    ch = Channel{String}(32)
    for dir in (SRC_DIR, TEST_DIR)
        @async while true
            changed, _ = watch_folder(dir)
            endswith(changed, ".jl") && put!(ch, changed)
        end
    end
    while true
        try
            include(joinpath(SRC_DIR, "routes.jl"))
            run_tests()
        catch e
            @error "Aborted" exception=(e, catch_backtrace())
        end
        @info "Watching julia/src/ and julia/test/ for changes — Ctrl-C to stop"
        changed = take!(ch)
        sleep(0.05)
        while isready(ch) take!(ch) end
        @info "$(changed) changed — reloading and re-running tests"
    end
else
    run_tests()
end
