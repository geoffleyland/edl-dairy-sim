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

            @testset "sankey nodes include stream names" begin
                resp  = yield_calc(post_req(separation_config))
                links = resp_json(resp)["sankey"]["links"]
                names = Set(vcat([[l["source"], l["target"]] for l in links]...))
                @test "skim" ∈ names
                @test "cream" ∈ names
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
                    "milk"  => -1000.0,
                    "skim"  => +900.0,
                    "cream" => +100.0,
                )),
            )
            no_params = Dict{String, Dict{String, Any}}()

            @testset "silo levels change correctly" begin
                intakes = [Intake("milk", 0.0, 10.0, 1000.0)]
                blocks  = [Block("sep", "running", 0.0, 10.0)]
                init    = Dict("milk" => 0.0, "skim" => 0.0, "cream" => 0.0)

                r = simulate(intakes, blocks, init, sep_effects, no_params, 10.0)
                last = r.snapshots[end]

                # Intake exactly matches outflow — milk stays near 0.
                @test last.levels["milk"]  ≈ 0.0    atol=1e-6
                @test last.levels["skim"]  ≈ 9000.0 atol=1e-6
                @test last.levels["cream"] ≈ 1000.0 atol=1e-6
            end

            @testset "machine off after block ends" begin
                blocks = [Block("sep", "running", 0.0, 5.0)]
                init   = Dict("milk" => 50_000.0, "skim" => 0.0, "cream" => 0.0)

                r = simulate(Intake[], blocks, init, sep_effects, no_params, 10.0)
                last = r.snapshots[end]

                # Separator ran for 5 hr only: skim = 900*5 = 4500
                @test last.levels["skim"]  ≈ 4500.0 atol=1e-6
                @test last.levels["cream"] ≈  500.0 atol=1e-6
            end

            @testset "silo exceeds capacity (no clamping)" begin
                init = Dict("milk" => 200_000.0, "skim" => 0.0, "cream" => 50_000.0)

                # Capacity is not enforced — silos can exceed their limit.
                r = simulate(Intake[], [Block("sep", "running", 0.0, 200.0)], init, sep_effects, no_params, 200.0)
                last = r.snapshots[end]
                @test last.levels["skim"] > 100_000.0
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

                r = simulate(Intake[], blocks, init, cond_effects, params, 25.0)

                cleans = filter(s -> s.label == "clean-start", r.snapshots)
                ends   = filter(s -> s.label == "clean-end",   r.snapshots)
                @test length(cleans) == 1
                @test cleans[1].time_hr ≈ 20.0 atol=1e-9
                @test ends[1].time_hr   ≈ 24.0 atol=1e-9

                # Machine should be back in "skim" mode after clean.
                @test ends[1].mode == "skim"
            end

            # Helpers: build a machine dict with pre-joined mode inputs/outputs,
            # mirroring what routes.jl produces before calling compute_effects.
            function make_machine(id; modes)
                Dict{String, Any}("id" => id, "modes" => modes)
            end
            function make_mode(id; rate, inputs, outputs)
                Dict{String, Any}("id" => id, "rate_kg_per_hour" => rate,
                                  "inputs" => inputs, "outputs" => outputs)
            end

            @testset "compute_effects separator" begin
                machines = [make_machine("sep", modes = [
                    make_mode("running", rate=20000, inputs=["milk"], outputs=["skim","cream"]),
                ])]
                quantities = Dict("milk" => 1.0, "skim" => 0.9, "cream" => 0.1)

                fx = compute_effects(machines, quantities)
                sep_fx = fx["sep"]["running"]
                @test sep_fx["milk"]  ≈ -20000.0
                @test sep_fx["skim"]  ≈ +18000.0
                @test sep_fx["cream"] ≈  +2000.0
            end

            @testset "compute_effects condenser" begin
                machines = [make_machine("cond", modes = [
                    make_mode("skim",       rate=10000, inputs=["skim"],       outputs=["condensed-skim"]),
                    make_mode("buttermilk", rate=5000,  inputs=["buttermilk"], outputs=["condensed-buttermilk"]),
                ])]
                # r_skim = 0.2 (1 kg skim → 0.2 kg condensed-skim), r_bm = 0.25
                quantities = Dict(
                    "skim" => 1.0, "condensed-skim"        => 0.2,
                    "buttermilk" => 1.0, "condensed-buttermilk" => 0.25,
                )

                fx = compute_effects(machines, quantities)

                skim_fx = fx["cond"]["skim"]
                @test skim_fx["skim"]           ≈ -10000.0
                @test skim_fx["condensed-skim"] ≈   +2000.0   # 10000 * 0.2

                bm_fx = fx["cond"]["buttermilk"]
                @test bm_fx["buttermilk"]             ≈ -5000.0
                @test bm_fx["condensed-buttermilk"]   ≈ +1250.0  # 5000 * 0.25
            end

            @testset "compute_effects drier" begin
                machines = [make_machine("dry", modes = [
                    make_mode("smp", rate=8000, inputs=["condensed-skim"],       outputs=["smp"]),
                    make_mode("bmp", rate=4000, inputs=["condensed-buttermilk"], outputs=["bmp"]),
                ])]
                quantities = Dict(
                    "condensed-skim" => 1.0, "smp" => 0.95,
                    "condensed-buttermilk" => 1.0, "bmp" => 0.95,
                )

                fx = compute_effects(machines, quantities)

                @test fx["dry"]["smp"]["condensed-skim"]       ≈ -8000.0
                @test fx["dry"]["smp"]["smp"]                  ≈ +7600.0   # 8000 * 0.95
                @test fx["dry"]["bmp"]["condensed-buttermilk"] ≈ -4000.0
                @test fx["dry"]["bmp"]["bmp"]                  ≈ +3800.0   # 4000 * 0.95
                # Drier must not affect skim or buttermilk directly
                @test !haskey(fx["dry"]["smp"], "skim")
                @test !haskey(fx["dry"]["bmp"], "buttermilk")
            end

        end

        @testset "simulate_run" begin
            sep_site = Dict(
                "machines" => [Dict(
                    "id" => "sep", "name" => "Separator", "type" => "separator",
                    "modes" => [Dict(
                        "id" => "running", "label" => "Run",
                        "operation" => "separate-milk", "rate_kg_per_hour" => 1000,
                    )],
                )],
                "silos" => [
                    Dict("id" => "milk",  "volume_kg" => 200_000, "initial_kg" => 10_000),
                    Dict("id" => "skim",  "volume_kg" => 100_000, "initial_kg" => 0),
                    Dict("id" => "cream", "volume_kg" =>  50_000, "initial_kg" => 0),
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
                    "id" => "separate-milk", "name" => "Separator",
                    "operation" => "separation", "inputs" => ["milk"],
                    "outputs" => ["skim", "cream"], "separation-component" => "fat",
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
                    @test haskey(r, "effects")
                    @test length(r["snapshots"]) > 1
                end
            end

            @testset "silo levels change over horizon" begin
                mktempdir() do dir
                    write(joinpath(dir, "site.json"), JSON3.write(sep_site))
                    body = Dict(
                        "process"    => sep_process,
                        "intakes"    => [Dict("silo_id" => "milk", "start_hr" => 0.0, "end_hr" => 2.0, "rate_kg_per_hr" => 1000.0)],
                        "blocks"     => [Dict("machine_id" => "sep", "mode" => "running", "start_hr" => 0.0, "end_hr" => 2.0)],
                        "horizon_hr" => 2.0,
                    )
                    resp = simulate_run(post_req(body), dir)
                    @test resp.status == 200
                    r    = resp_json(resp)
                    last = r["snapshots"][end]
                    # Separator consumes milk at 1000 kg/hr; intake adds 1000 kg/hr → net zero
                    @test last["levels"]["milk"] ≈ 10_000.0 atol=1.0
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
