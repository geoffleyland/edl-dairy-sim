using HTTP, Logging, UUIDs

# ── Correlation ID + request logging ──────────────────────────────────────────
#
# Wraps every request with:
#   - An X-Request-ID header (taken from the incoming request, or generated).
#   - A structured @info log line: method, path, status, elapsed_ms, corr_id.
#   - The correlation ID in task-local storage so route handlers can include
#     it in their own log lines via `correlation_id()`.

function request_logging_middleware(handler)
    function (req::HTTP.Request)
        corr_id = HTTP.hasheader(req, "X-Request-ID") ?
            HTTP.header(req, "X-Request-ID") :
            string(uuid4())

        task_local_storage(:correlation_id, corr_id)

        t0   = time_ns()
        resp = handler(req)
        elapsed_ms = round((time_ns() - t0) / 1e6, digits = 1)

        @info "$(req.method) $(req.target)" corr_id elapsed_ms status = resp.status

        push!(resp.headers, "X-Request-ID" => corr_id)
        return resp
    end
end

# Call from any route handler to get the correlation ID for the current request.
# Falls back to "-" when called outside a request (e.g. during startup).
correlation_id() = get(task_local_storage(), :correlation_id, "-")
