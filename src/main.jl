using ArgParse, Revise #, Logging

push!(LOAD_PATH, "src")
using Yield

ap = ArgParseSettings(description = "Prototype Yield model", version="0.0.1", add_version=true)

@add_arg_table! ap begin
    "config-file"
        help = " JSON configuration file"
        required = true
    # "plant-file"
    #     help = "plant capacity JSON file"
    #     required = true
    # "bookings-file"
    #     help = "historic booking data"
    #     required = true
    # "--output", "-o"
    #     help = "output file for test results"
    #     required = true
    "--watch", "-w"
        action = :store_true
        help = "watch project for changes and re-run"
end

args = parse_args(ap)
#Logging.global_logger(Logging.ConsoleLogger(Logging.Warn))

if args["watch"]
    entr(["src", "src/processes", "configs"]) do
        try
            Yield.run(args["config-file"])
        catch e
            showerror(stdout, e, catch_backtrace())
        end
    end
else
    Yield.run(args["config-file"])
end
