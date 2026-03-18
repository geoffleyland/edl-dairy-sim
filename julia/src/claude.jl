# ── Claude AI integration ────────────────────────────────────────────────────
#
# solve_commentary is called after every successful solve.  It returns a
# brief plain-English summary of the result, or nothing if the feature is
# disabled (ANTHROPIC_API_KEY not set) or the call fails.
#
# `reference` carries the human-readable names (farms, plants, stock types)
# that the solver doesn't need but commentary does.  𝓓 carries the problem
# quantities; result carries what was placed.


# Formats the data section that goes into the middle of the prompt: supply vs
# placed, any unplaced shortfall by farm and stock type, any supplies split
# across multiple destinations, and per-shift utilisation.
function format_prompt_report(
    reference ::Dict{String, Any},
    𝓓         ::ProblemData,
    result    ::SolveResult,
) :: String

    plant_name  = Dict(p["id"] => p["name"] for p in reference["plants"])
    farm_name   = Dict(f["id"] => f["name"] for f in reference["farms"])
    stock_name  = Dict(s["id"] => s["name"] for s in reference["stock_types"])
    shift_label = Dict(s["id"] => "$(s["day"]) $(s["period"])" for s in reference["shifts"])
    lookup(map, id) = get(map, id, id)

    # Supply available this week, keyed by (farm, stock type).
    supply_by_farm_stock = Dict{Tuple{String,String}, Int}(
        (s.farm_id, s.stock_type_id) => s.quantity for s in 𝓓.supplies
    )
    total_supply = sum(values(supply_by_farm_stock); init = 0)

    # Accumulate placed quantities, utilisation, and deliveries per (farm, stock type).
    placed_by_farm_stock     = Dict{Tuple{String,String}, Int}()
    deliveries_by_farm_stock = Dict{Tuple{String,String}, Vector{Delivery}}()
    utilization              = Dict{Tuple{String,String}, Int}()
    for d in result.deliveries
        fs_key = (d.farm_id, d.stock_type_id)
        ps_key = (d.plant_id, d.shift_id)
        placed_by_farm_stock[fs_key] = get(placed_by_farm_stock, fs_key, 0) + d.quantity
        utilization[ps_key]          = get(utilization, ps_key, 0) + d.quantity
        push!(get!(deliveries_by_farm_stock, fs_key, Delivery[]), d)
    end

    # Unplaced: any (farm, stock type) where supply exceeds placed.
    unplaced_lines = String[]
    for ((farm_id, stock_id), available) in supply_by_farm_stock
        shortfall = available - get(placed_by_farm_stock, (farm_id, stock_id), 0)
        shortfall > 0 && push!(unplaced_lines,
            "  $(lookup(farm_name, farm_id)) — $(lookup(stock_name, stock_id)): $shortfall of $available unplaced")
    end

    # Splits: any (farm, stock type) delivered to more than one shift or plant.
    split_lines = String[]
    for ((farm_id, stock_id), deliveries) in deliveries_by_farm_stock
        length(deliveries) < 2 && continue
        destinations = join([
            "$(lookup(plant_name, d.plant_id)) $(lookup(shift_label, d.shift_id)) ($(d.quantity))"
            for d in deliveries
        ], ", ")
        push!(split_lines,
            "  $(lookup(farm_name, farm_id)) — $(lookup(stock_name, stock_id)): $destinations")
    end

    # Shift utilisation across all plants.
    util_lines = String[]
    for p in reference["plants"], s in p["shifts"]
        placed = get(utilization, (p["id"], s["shift_id"]), 0)
        push!(util_lines,
            "  $(lookup(plant_name, p["id"])) — $(lookup(shift_label, s["shift_id"])): $placed/$(s["capacity"])")
    end

    unplaced_section = isempty(unplaced_lines) ?
        "Unplaced: none — all supply was placed." :
        "Unplaced supply (by farm and stock type):\n$(join(unplaced_lines, "\n"))"

    split_section = isempty(split_lines) ? "" :
        "\nSplit supplies (one supply delivered across multiple shifts or plants):\n$(join(split_lines, "\n"))"

    """
    Total supply: $total_supply head — Placed: $(result.objective) head
    $unplaced_section$split_section

    Shift utilisation:
    $(join(util_lines, "\n"))"""
end


# Wraps the formatted report in the full prompt — instructions, week, data, request.
function prepare_prompt(week::String, report::String) :: String
    """
    You are a livestock allocation planning assistant. Summarise the result of this week's solve for a production planner.

    Week: $week
    $report

    Write 2–3 plain-English sentences. Focus on: overall placement rate, any unplaced supply (noting which farms and stock types), any supplies split across plants or shifts, and any shifts at or near capacity. Be concise.
    """
end


# Makes the API call and returns the assistant's reply text.
# Throws on any HTTP or parse error — caller is responsible for handling.
function call_claude_api(api_key::String, prompt::String) :: String
    resp = HTTP.post(
        "https://api.anthropic.com/v1/messages",
        [
            "Content-Type"      => "application/json",
            "x-api-key"         => api_key,
            "anthropic-version" => "2023-06-01",
        ],
        JSON3.write(Dict(
            "model"      => "claude-haiku-4-5-20251001",
            "max_tokens" => 300,
            "messages"   => [Dict("role" => "user", "content" => prompt)],
        )),
    )
    data = JSON3.read(String(resp.body))
    String(data.content[1].text)
end


function solve_commentary(
    week      ::String,
    reference ::Dict{String, Any},
    𝓓         ::ProblemData,
    result    ::SolveResult,
) :: Union{String, Nothing}
    api_key = get(ENV, "ANTHROPIC_API_KEY", "")
    if isempty(api_key)
        @info "Solve commentary disabled (ANTHROPIC_API_KEY not set)"
        return nothing
    end
    try
        report  = format_prompt_report(reference, 𝓓, result)
        prompt  = prepare_prompt(week, report)
        call_claude_api(api_key, prompt)
    catch e
        @warn "Solve commentary failed" exception=(e, catch_backtrace())
        nothing
    end
end
