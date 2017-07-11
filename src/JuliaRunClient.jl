module JuliaRunClient

using Requests
using HttpCommon
using JSON

export Context, JuliaParBatch, JuliaParBatchWorkers, Notebook, JuliaBatch, PkgBuilder, Webserver, MessageQ
export getSystemStatus, listJobs, getAllJobInfo, getJobStatus, getJobScale, setJobScale, getJobEndpoint, deleteJob, tailJob, submitJob

abstract JRunClientJob

for T in (:JuliaParBatch, :JuliaParBatchWorkers, :Notebook, :JuliaBatch, :PkgBuilder, :Webserver, :MessageQ)
    @eval begin
        immutable $T <: JRunClientJob
            name::String
        end
    end
end

immutable ApiException <: Exception
    status::Int
    reason::String
    resp::Response

    function ApiException(resp::Response; reason::String="")
        isempty(reason) && (reason = get(STATUS_CODES, statuscode(resp), reason))
        new(statuscode(resp), reason, resp)
    end
end


"""
A JuliaRun client context.

Consists of:
- URL of the JuliaRun remote server
- an authentication token
- namespace to operate in

Default values of all parameters are set to match those inside a JuliaRun cluster.
- connects to a service endpoint at "juliarunremote-svc.juliarun"
- reads the namespace from the default secret
- presents the namespace service token (also read from the default secret) for authentication
"""
immutable Context
    root::String
    token::String
    namespace::String

    function Context(root::String="http://juliarunremote-svc.juliarun:80", token::String="/var/run/secrets/kubernetes.io/serviceaccount/token", namespace::String="/var/run/secrets/kubernetes.io/serviceaccount/namespace")
        _isfile(token) && (token = base64encode(readstring(token)))
        _isfile(namespace) && (namespace = readstring(namespace))
        new(root, token, namespace)
    end
end

"""
Verifies if JuliaRun is running and is connected to a compute cluster.

Returns:
- boolean: true/false indicating success/failure
"""
getSystemStatus(ctx::Context) = _simple_query(ctx, "/getSystemStatus/")

"""
List all submitted jobs.

Returns:
- dictionary: of the form `{"jobname": { "type": "JuliaBatch" }...}`
"""
listJobs(ctx::Context) = _simple_query(ctx, "/listJobs/")

"""
List all submitted jobs.

Returns:
- dictionary: of the form `{"jobname": { "type": "JuliaBatch", "status": [], "scale": [], "endpoint": [] }...}`
"""
getAllJobInfo(ctx::Context) = _simple_query(ctx, "/getAllJobInfo/")

"""
Fetch current status of a Job.

Parameters:
- job: A JRunClientJob of appropriate type

Returns tuple/array with:
- boolean: whether the job completed
- integer: for a parallel job, number of workers that completed successfully
- integer: for a parallel job, number of workers started
- boolean: whether the job has been created (vs. scheduled)
- boolean: whether this is a notebook (legacy, likely to be removed in future)
"""
getJobStatus(ctx::Context, job::JRunClientJob) = _type_name_query(ctx, "/getJobStatus/", job)

"""
Get the current scale of a job.

Parameters:
- job: A JRunClientJob of appropriate type

Returns tuple/array with:
- integer: number of workers running
- integer: number of workers requested
"""
getJobScale(ctx::Context, job::JRunClientJob) = _type_name_query(ctx, "/getJobScale/", job)

"""
Request to scale the job up or down to the level of parallelism requested.

Parameters:
- job: A JRunClientJob of appropriate type
- parallelism: number of workers to scale to

Returns:
- boolean: true/false indicating success/failure
"""
setJobScale(ctx::Context, job::JRunClientJob, parallelism::Int) = _type_name_query(ctx, "/setJobScale/", job, Dict("parallelism" => string(parallelism)))

"""
Get the endpoint exposed by the job/service.

Parameters:
- job: A JRunClientJob of appropriate type

Returns tuple/array of endpoints as URLs or IP and ports
"""
getJobEndpoint(ctx::Context, job::JRunClientJob) = _type_name_query(ctx, "/getJobEndpoint/", job)

"""
Removes the job entry from the queue.

Parameters:
- job: A JRunClientJob of appropriate type
- force: whether to remove an incomplete job (optional, default: false)

Returns:
- boolean: true/false indicating success/failure
"""
deleteJob(ctx::Context, job::JRunClientJob; force=false) = _type_name_query(ctx, "/deleteJob/", job, Dict("force"=>string(force)))

"""
Tail logs from the job.

Parameters:
- job: A JRunClientJob of appropriate type
- stream: the stream to read from ("stdout"/"stdin"), all streams are read if not specified.
- count: number of log entries to return (50 by default)

Returns a string of log entries separated by new line.
"""
function tailJob(ctx::Context, job::JRunClientJob; stream=nothing, count=50)
    query = Dict("count"=>string(count))
    (stream === nothing) || (query["stream"] = string(stream))
    _type_name_query(ctx, "/tailJob/", job, query)
end

"""
Submit a job definition to execute on the cluster.

Parameters:
- job: A JRunClientJob of appropriate type
- job specific parameters, with names as documented for the JobType constructor

Returns nothing.
"""
function submitJob(ctx::Context, job::JRunClientJob; kwargs...)
    query = Dict{String,String}()
    for (k,v) in kwargs
        query[string(k)] = string(v)
    end
    _type_name_query(ctx, "/submitJob/", job, query)
end

# ---------------------------------------------------
# Utility methods
# ---------------------------------------------------
_jobtype{T<:JRunClientJob}(j::T) = _jobtype(T)
_jobtype{T}(::Type{T}) = rsplit(string(T), '.'; limit=2)[end]

# assuming PATH_MAX is 256
_isfile(val) = (length(val) < 256) && isfile(val)

function make_query(ctx::Context)
    Dict{String,String}(
        "jruntok" => ctx.token,
        "jrunns" => ctx.namespace
    )
end

function parse_resp(resp)
    (200 <= statuscode(resp) <= 206) || throw(ApiException(resp))
    info("response ", String(resp.data))
    JSON.parse(String(resp.data))
end

function _simple_query(ctx, path)
    query = make_query(ctx)
    info("requesting ", ctx.root * path)
    info("query ", query)
    #resp = get(ctx.root * path, query=query)
    resp = get(ctx.root * path)
    parse_resp(resp)
end

function _type_name_query(ctx::Context, path::String, job::JRunClientJob, query::Dict{String,String}=Dict{String,String}())
    query = merge(make_query(ctx), query)
    query["name"] = job.name
    jt = _jobtype(job)
    resp = get(ctx.root * path * jt * "/", query=query)
    parse_resp(resp)
end

end # module
