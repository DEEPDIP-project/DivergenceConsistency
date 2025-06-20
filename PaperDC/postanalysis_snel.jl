# # A-posteriori analysis: Large Eddy Simulation (2D)
#
# This script is used to generate results for the the paper [Agdestein2025](@citet).
#
# - Generate filtered DNS data
# - Train closure models
# - Compare filters, closure models, and projection orders
#
# The filtered DNS data is saved and can be loaded in a subesequent session.
# The learned CNN parameters are also saved.

if false                      #src
    include("src/PaperDC.jl") #src
end                           #src

@info "Script started"

# Color palette for consistent theme throughout paper
palette = (; color = ["#3366cc", "#cc0000", "#669900", "#ff9900"])

# Choose where to put output
basedir = haskey(ENV, "DEEPDIP") ? ENV["DEEPDIP"] : @__DIR__
outdir = joinpath(basedir, "output", "kolmogorov")
plotdir = joinpath(outdir, "plots")
logdir = joinpath(outdir, "logs")
ispath(outdir) || mkpath(outdir)
ispath(plotdir) || mkpath(plotdir)
ispath(logdir) || mkpath(logdir)

# Turn off plots for array jobs.
# If all the workers do this at the same time, one might
# error when saving the file at the same time
doplot() = true

########################################################################## #src

# ## Configure logger

using PaperDC
using Dates

# Write output to file, as the default SLURM file is not updated often enough
isslurm = haskey(ENV, "SLURM_JOB_ID")
if isslurm
    jobid = parse(Int, ENV["SLURM_JOB_ID"])
    taskid = parse(Int, ENV["SLURM_ARRAY_TASK_ID"])
    logfile = "job=$(jobid)_task=$(taskid)_$(Dates.now()).out"
else
    taskid = nothing
    logfile = "log_$(Dates.now()).out"
end
logfile = joinpath(logdir, logfile)
setsnelliuslogger(logfile)

@info "# A-posteriori analysis: Forced turbulence (2D)"

# ## Load packages

@info "Loading packages"

using Accessors
using Adapt
# using GLMakie
using CairoMakie
using CUDA
using IncompressibleNavierStokes
using IncompressibleNavierStokes.RKMethods
using JLD2
using LaTeXStrings
using LinearAlgebra
using Lux
using LuxCUDA
using NeuralClosure
using NNlib
using Optimisers
using ParameterSchedulers
using Random
using SparseArrays

########################################################################## #src

# ## Random number seeds
#
# Use a new RNG with deterministic seed for each code "section"
# so that e.g. training batch selection does not depend on whether we
# generated fresh filtered DNS data or loaded existing one (the
# generation of which would change the state of a global RNG).
#
# Note: Using `rng = Random.default_rng()` twice seems to point to the
# same RNG, and mutating one also mutates the other.
# `rng = Xoshiro()` creates an independent copy each time.
#
# We define all the seeds here.

seeds = (;
    dns = 123456, # Initial conditions
    θ_start = 234, # Initial CNN parameters
    prior = 345, # A-priori training batch selection
    post = 456, # A-posteriori training batch selection
)

########################################################################## #src

# ## Hardware selection

# Precision
T = Float64

# Device
if CUDA.functional()
    ## For running on a CUDA compatible GPU
    @info "Running on CUDA"
    backend = CUDABackend()
    CUDA.allowscalar(false)
    device = x -> adapt(CuArray, x)
    clean() = (GC.gc(); CUDA.reclaim())
else
    ## For running on CPU.
    ## Consider reducing the sizes of DNS, LES, and CNN layers if
    ## you want to test run on a laptop.
    @warn "Running on CPU"
    backend = CPU()
    device = identity
    clean() = nothing
end

########################################################################## #src

# ## Data generation
#
# Create filtered DNS data for training, validation, and testing.

# Parameters
params = (;
    D = 2,
    lims = (T(0), T(1)),
    Re = T(6e3),
    tburn = T(0.5),
    tsim = T(5),
    savefreq = 50,
    ndns = 4096,
    nles = [64],
    filters = (FaceAverage(),),
    backend,
    icfunc = (setup, psolver, rng) -> random_field(setup, T(0); kp = 20, psolver, rng),
    method = RKMethods.Wray3(; T),
    bodyforce = (dim, x, y, t) -> (dim == 1) * 5 * sinpi(8 * y),
    issteadybodyforce = true,
    processors = (; log = timelogger(; nupdate = 100)),
    #Δt = 0.00005
)

# DNS seeds
ntrajectory = 8
dns_seeds = splitseed(seeds.dns, ntrajectory)
dns_seeds_train = dns_seeds[1:ntrajectory-2]
dns_seeds_valid = dns_seeds[ntrajectory-1:ntrajectory-1]
dns_seeds_test = dns_seeds[ntrajectory:ntrajectory]

# Create data
docreatedata = false
docreatedata = true
docreatedata && createdata(; params, seeds = dns_seeds, outdir, taskid)
@info "Data Generated"
@assert 1==2

# Computational time
docomp = false
docomp && let
    comptime, datasize = 0.0, 0.0
    for seed in dns_seeds
        comptime += load(
            getdatafile(outdir, params.nles[1], params.filters[1], seed),
            "comptime",
        )
    end
    for seed in dns_seeds, nles in params.nles, Φ in params.filters
        data = namedtupleload(getdatafile(outdir, nles, Φ, seed))
        datasize += Base.summarysize(data)
    end
    @info "Data" comptime
    @info "Data" comptime / 60 datasize * 1e-9
    clean()
end

# LES setups
setups = map(nles -> getsetup(; params, nles), params.nles);

########################################################################## #src

# ## CNN closure model

# All training sessions will start from the same θ₀
# for a fair comparison.

closure, θ_start = cnn(;
    setup = setups[1],
    radii = [2, 2, 2, 2, 2],
    channels = [24, 24, 24, 24, params.D],
    activations = [tanh, tanh, tanh, tanh, identity],
    use_bias = [true, true, true, true, false],
    rng = Xoshiro(seeds.θ_start),
);
closure.chain

@info "Initialized CNN with $(length(θ_start)) parameters"

# Give the CNN a test run
# Note: Data and parameters are stored on the CPU, and
# must be moved to the GPU before use (with `device`)
let
    @info "CNN warm up run"
    using NeuralClosure.Zygote
    u = randn(T, 32, 32, 2, 10) |> device
    θ = θ_start |> device
    closure(u, θ)
    gradient(θ -> sum(closure(u, θ)), θ)
    clean()
end

########################################################################## #src

# ## Training

# ### A-priori training
#
# Train one set of CNN parameters for each of the filter types and grid sizes.
# Use the same batch selection random seed for each training setup.
# Save parameters to disk after each run.
# Plot training progress (for a validation data batch).

# Parameter save files

let
    dotrain = true
    #dotrain = false
    nepoch = 50000
    niter = nothing
    dotrain && trainprior(;
        params,
        priorseed = seeds.prior,
        dns_seeds_train,
        dns_seeds_valid,
        taskid,
        outdir,
        plotdir,
        closure,
        θ_start,
        # opt = AdamW(; eta = T(1.0e-3), lambda = T(5.0e-5)),
        opt = Adam(T(1.0e-3)),
        λ = T(5.0e-5),
        # noiselevel = T(1e-3),
        #scheduler = CosAnneal(; l0 = T(1e-6), l1 = T(1e-3), period = nepoch),
        nvalid = 32,
        batchsize = 32,
        displayref = true,
        displayupdates = true, # Set to `true` if using CairoMakie
        nupdate_callback = 20,
        loadcheckpoint = false,
        nepoch,
        niter,
    )
end


# Load learned parameters and training times
priortraining = loadprior(outdir, params.nles, params.filters)
θ_cnn_prior = map(p -> copyto!(copy(θ_start), p.θ), priortraining)
@info "" θ_cnn_prior .|> extrema # Check that parameters are within reasonable bounds

# Training times
map(p -> p.comptime, priortraining)
map(p -> p.comptime, priortraining) |> vec .|> x -> round(x; digits = 1)
map(p -> p.comptime, priortraining) |> sum |> x -> x / 60 # Minutes

# ## Plot training history

with_theme(; palette) do
    doplot() || return
    fig = Figure(; size = (950, 250))
    for (ig, nles) in enumerate(params.nles)
        ax = Axis(
            fig[1, ig];
            title = "n = $(nles)",
            xlabel = "Iteration",
            ylabel = "A-priori error",
            ylabelvisible = ig == 1,
            yticksvisible = ig == 1,
            yticklabelsvisible = ig == 1,
        )
        ylims!(-0.05, 1.05)
        lines!(
            ax,
            [Point2f(0, 1), Point2f(priortraining[ig, 1].hist[end][1], 1)];
            label = "No closure",
            linestyle = :dash,
        )
        for (ifil, Φ) in enumerate(params.filters)
            label = Φ isa FaceAverage ? "FA" : "VA"
            lines!(ax, priortraining[ig, ifil].hist; label)
        end
        # lines!(
        #     ax,
        #     [Point2f(0, 0), Point2f(priortraining[ig, 1].hist[end][1], 0)];
        #     label = "DNS",
        #     linestyle = :dash,
        # )
    end
    axes = filter(x -> x isa Axis, fig.content)
    linkaxes!(axes...)
    Legend(fig[1, end+1], axes[1])
    figdir = joinpath(plotdir, "priortraining")
    ispath(figdir) || mkpath(figdir)
    save("$figdir/validationerror.pdf", fig)
    display(fig)
end

########################################################################## #src

# ### A-posteriori training
#
# Train one set of CNN parameters for each
# projection order, filter type and grid size.
# Use the same batch selection random seed for each training setup.
# Save parameters to disk after each combination.
# Plot training progress (for a validation data batch).
#
# The time stepper `RKProject` allows for choosing when to project.

projectorders = [ProjectOrder.Last]

# Train
let
    dotrain = true
    #dotrain = false
    nepoch = 3000
    dotrain && trainpost(;
        params,
        projectorders,
        outdir,
        plotdir,
        taskid,
        postseed = seeds.post,
        dns_seeds_train,
        dns_seeds_valid,
        nsubstep = 5,
        nunroll = 5,
        ntrajectory = 5,
        closure,
        θ_start = θ_cnn_prior,
        opt = Adam(T(1e-4)),
        λ = T(5e-8),
        #scheduler = CosAnneal(; l0 = T(1e-6), l1 = T(1e-4), period = nepoch),
        nunroll_valid = 5,
        nupdate_callback = 10,
        displayref = false,
        displayupdates = true,
        loadcheckpoint = false,
        nepoch,
        niter = 1,
    )
end

# Load learned parameters and training times

posttraining = loadpost(outdir, params.nles, params.filters, projectorders)
θ_cnn_post = map(p -> copyto!(copy(θ_start), p.θ), posttraining)
@info "" θ_cnn_post .|> extrema # Check that parameters are within reasonable bounds

# Training times
map(p -> p.comptime, posttraining) ./ 60
map(p -> p.comptime, posttraining) |> sum |> x -> x / 60
map(p -> p.comptime, posttraining) |> x -> reshape(x, :, 1) .|> x -> round(x; digits = 1)

# ## Plot a-posteriori training history

with_theme(; palette) do
    doplot() || return
    fig = Figure(; size = (950, 400))
    for (iorder, projectorder) in enumerate(projectorders)
        axes = []
        for (ig, nles) in enumerate(params.nles)
            ax = Axis(
                fig[iorder, ig];
                title = "n = $(nles)",
                xlabel = "Iteration",
                ylabel = projectorder == ProjectOrder.First ? "DIF" : "DCF",
                ylabelvisible = ig == 1,
                ylabelfont = :bold,
                # yticksvisible = ig == 1,
                # yticklabelsvisible = ig == 1,
                # yscale = log10,
                titlevisible = iorder == 1,
                xlabelvisible = iorder == 2,
                xticksvisible = iorder == 2,
                xticklabelsvisible = iorder == 2,
            )
            for (ifil, Φ) in enumerate(params.filters)
                postfile = PaperDC.getpostfile(outdir, nles, Φ, projectorder)
                checkfile = join(splitext(postfile), "_checkpoint")
                check = namedtupleload(checkfile)
                (; hist) = check.callbackstate
                label = Φ isa FaceAverage ? "FA" : "VA"
                lines!(ax, hist; color = Cycled(ifil + 1), label)
            end
            ig == 4 && iorder == 1 && axislegend(ax)
            push!(axes, ax)
        end
        # linkaxes!(axes...)
    end
    # axes = filter(x -> x isa Axis, fig.content)
    # linkaxes!(axes...)
    # Legend(fig[:, end+1], filter(x -> x isa Axis, fig.content)[1])
    Label(fig[0, :], "A-posteriori error"; valign = :bottom, font = :bold)
    rowgap!(fig.layout, 10)
    figdir = joinpath(plotdir, "posttraining")
    ispath(figdir) || mkpath(figdir)
    save("$figdir/validationerror.pdf", fig)
    display(fig)
end

########################################################################## #src

# ### Train Smagorinsky model
#
# Use a-posteriori error grid search to determine the optimal Smagorinsky constant.
# Find one constant for each projection order, filter type, and grid size.

let
    dotrain = true
    #dotrain = false
    dotrain && trainsmagorinsky(;
        params,
        projectorders,
        outdir,
        dns_seeds_train,
        taskid,
        nunroll = 50,
        nsubstep = 5,
        ninfo = 50,
        θrange = range(T(0), T(0.3), 301),
    )
end

# Load trained parameters
smag = loadsmagorinsky(outdir, params.nles, params.filters, projectorders)

# Extract coefficients
θ_smag = getfield.(smag, :θ)

θ_smag |> x -> reshape(x, :, 1)

# Computational time
getfield.(smag, :comptime)
getfield.(smag, :comptime) |> sum

########################################################################## #src

# ## Prediction errors

# ### Compute a-priori errors
#
# Note that it is still interesting to compute the a-priori errors for the
# a-posteriori trained CNN.
let
    eprior = (;
        nomodel = ones(T, length(params.nles)),
        model_prior = zeros(T, size(θ_cnn_prior)),
        model_post = zeros(T, size(θ_cnn_post)),
        model_t_prior_inference = zeros(T, size(θ_cnn_prior)),
    )
    for (ifil, Φ) in enumerate(params.filters), (ig, nles) in enumerate(params.nles)
        @info "Computing a-priori errors" Φ nles

        setup = getsetup(; params, nles)
        data = map(s -> namedtupleload(getdatafile(outdir, nles, Φ, s)), dns_seeds_test)
        testset = create_io_arrays(data, setup)
        i = 1:length(data)
        u, c = testset.u[:, :, :, i], testset.c[:, :, :, i]
        testset = (u, c) |> device
        err = create_relerr_prior(closure, testset...)
        eprior.model_prior[ig, ifil] = err(device(θ_cnn_prior[ig, ifil]))
        for iorder in eachindex(projectorders)
            eprior.model_post[ig, ifil, iorder] = err(device(θ_cnn_post[ig, ifil, iorder]))
        end
        eprior.model_t_prior_inference[ig, ifil] = compute_t_inference_prior(closure, device(θ_cnn_prior[ig, ifil]), testset...)
    end
    jldsave(joinpath(outdir, "eprior_nles=$(params.nles[1]).jld2"); eprior...)
end
clean()

eprior = namedtupleload(joinpath(outdir, "eprior_nles=$(params.nles[1]).jld2"))

########################################################################## #src

# ### Compute a-posteriori errors

let
    sample = namedtupleload(
        getdatafile(outdir, params.nles[1], params.filters[1], dns_seeds_test[1]),
    )
    sample.t[end]
end

let
    tsave = [5, 10, 25, 50, 100, 200, 500, 750, 1000, 1500, 2000]
    s = (length(params.nles), length(params.filters), length(projectorders))
    st = (length(params.nles), length(params.filters), length(projectorders), length(tsave))
    epost = (;
        nomodel = zeros(T, st),
        smag = zeros(T, st),
        model_prior = zeros(T, st),
        model_post = zeros(T, st),
        nomodel_t_post_inference = zeros(T, s),
        smag_t_post_inference = zeros(T, s),
        model_t_post_inference = zeros(T, s),
        nts = zeros(T,length(tsave)),
    )
    for (iorder, projectorder) in enumerate(projectorders),
        (ifil, Φ) in enumerate(params.filters),
        (ig, nles) in enumerate(params.nles)

        @info "Computing a-posteriori errors" projectorder Φ nles
        I = CartesianIndex(ig, ifil, iorder)
        setup = getsetup(; params, nles)
        psolver = psolver_spectral(setup)
        sample = namedtupleload(getdatafile(outdir, nles, Φ, dns_seeds_test[1]))
        it = 1:length(sample.t)
        data = (;
            u = selectdim(sample.u, ndims(sample.u), it) |> collect |> device,
            t = sample.t[it],
        )
        epost.nts[:] = [data.t[i] for i in tsave]
        @info "data.t", epost.nts
        nsubstep = 5
        method = RKProject(params.method, projectorder)
        ## No model
        err = create_relerr_post_wt(;
            data,
            setup,
            psolver,
            method,
            closure_model = nothing,
            nsubstep,
        )
        epost.nomodel[I, :], epost.nomodel_t_post_inference[I] = err(nothing, tsave)
        @info "Nomodel error $(epost.nomodel[I, :])"
        ## Smagorinsky
        err = create_relerr_post_wt(;
            data,
            setup,
            psolver,
            method,
            closure_model = smagorinsky_closure(setup),
            nsubstep,
        )
        epost.smag[I,:], epost.smag_t_post_inference[I] = err(θ_smag[I], tsave)
        @info "Smagorinsky error $(epost.smag[I,:])"
        ## CNN
        err = create_relerr_post_wt(;
            data,
            setup,
            psolver,
            method,
            closure_model = wrappedclosure(closure, setup),
            nsubstep,
        )
        epost.model_prior[I,:], _ = err(device(θ_cnn_prior[ig, ifil]),tsave)
        @info "CNN (prior) error $(epost.model_prior[I,:])"
        epost.model_post[I,:], epost.model_t_post_inference[I] = err(device(θ_cnn_post[I]),tsave)
        @info "CNN (post) error $(epost.model_post[I,:])"
        clean()
    end
    jldsave(joinpath(outdir, "epost_nles=$(params.nles[1]).jld2"); epost...)
end
    

epost = namedtupleload(joinpath(outdir, "epost_nles=$(params.nles[1]).jld2"))

epost.nomodel
epost.smag
epost.model_prior
epost.model_post

########################################################################## #src

# ### Plot a-priori errors

# Better for PDF export
CairoMakie.activate!()

with_theme(; palette) do
    fig = Figure(; size = (800, 300))
    axes = []
    for (ifil, Φ) in enumerate(params.filters)
        ax = Axis(
            fig[1, ifil];
            xscale = log10,
            xticks = params.nles,
            xlabel = "Resolution",
            # title = "Relative a-priori error $(ifil == 1 ? " (FA)" : " (VA)")",
            # title = "$(Φ isa FaceAverage ? "FA" : "VA")",
            title = "$(Φ isa FaceAverage ? "Face-averaging" : "Volume-averaging")",
            ylabel = "A-priori error",
            ylabelvisible = ifil == 1,
            yticksvisible = ifil == 1,
            yticklabelsvisible = ifil == 1,
        )
        for (e, marker, label, color) in [
            (eprior.nomodel, :circle, "No closure", Cycled(1)),
            (eprior.model_prior[:, ifil], :utriangle, "CNN (prior)", Cycled(2)),
            (eprior.model_post[:, ifil], :rect, "CNN (post)", Cycled(3)),
        ]
            scatterlines!(params.nles, e; marker, color, label)
        end
        # axislegend(; position = :lb)
        ylims!(ax, (T(-0.05), T(1.05)))
        push!(axes, ax)
    end
    Legend(fig[1, end+1], axes[1])
    save("$plotdir/eprior.pdf", fig)
    display(fig)
end

########################################################################## #src

# ### Plot a-posteriori errors

with_theme(; palette) do
    return
    doplot() || return
    fig = Figure(; size = (800, 300))
    linestyles = [:solid, :dash]
    linestyles = [:solid]
    for (iorder, projectorder) in enumerate(projectorders)
        lesmodel = iorder == 1 ? "DIF" : "DCF"
        (; nles) = params
        ax = Axis(
            fig[1, iorder];
            xscale = log10,
            yscale = log10,
            xticks = nles,
            xlabel = "Resolution",
            title = "$lesmodel",
            ylabel = "A-posteriori error",
            ylabelvisible = iorder == 1,
            yticksvisible = iorder == 1,
            yticklabelsvisible = iorder == 1,
        )
        for (e, marker, label, color) in [
            (epost.nomodel, :circle, "No closure", Cycled(1)),
            (epost.smag, :utriangle, "Smagorinsky", Cycled(2)),
            (epost.model_prior, :rect, "CNN (Lprior)", Cycled(3)),
            (epost.model_post, :diamond, "CNN (Lpost)", Cycled(4)),
        ]
            for (ifil, linestyle) in enumerate(linestyles)
                ifil == 2 && (label = nothing)
                scatterlines!(nles, e[:, ifil, iorder]; color, linestyle, marker, label)
            end
        end
        # ylims!(ax, (T(0.025), T(1.00)))
    end
    linkaxes!(filter(x -> x isa Axis, fig.content)...)
    g = GridLayout(fig[1, end+1])
    Legend(g[1, 1], filter(x -> x isa Axis, fig.content)[1]; valign = :bottom)
    Legend(
        g[2, 1],
        map(s -> LineElement(; color = :black, linestyle = s), linestyles),
        #["FA", "VA"];
        ["FA"];
        orientation = :horizontal,
        valign = :top,
    )
    rowsize!(g, 1, Relative(1 / 2))
    # rowgap!(g, 0)
    # Legend(fig[1, end + 1], filter(x -> x isa Axis, fig.content)[1])
    # Legend(
    #     fig[end+1, :],
    #     filter(x -> x isa Axis, fig.content)[1];
    #     orientation = :horizontal,
    # )
    save("$plotdir/epost.pdf", fig)
    display(fig)
end

########################################################################## #src

# ## Energy evolution

# ### Compute total kinetic energy as a function of time

let
    s = length(params.nles), length(params.filters), length(projectorders)
    keys = [:ref, :nomodel, :smag, :model_prior, :model_post]
    divergencehistory = (; map(k -> k => fill(Point2f[], s), keys)...)
    energyhistory = (; map(k -> k => fill(Point2f[], s), keys)...)
    for (iorder, projectorder) in enumerate(projectorders),
        (ifil, Φ) in enumerate(params.filters),
        (ig, nles) in enumerate(params.nles)

        I = CartesianIndex(ig, ifil, iorder)
        @info "Computing divergence and kinetic energy" projectorder Φ nles
        setup = getsetup(; params, nles)
        psolver = default_psolver(setup)
        sample = namedtupleload(getdatafile(outdir, nles, Φ, dns_seeds_test[1]))
        ustart = selectdim(sample.u, ndims(sample.u), 1) |> collect |> device
        T = eltype(ustart)

        # Shorter time for DIF
        t_DIF = T(1)

        # Reference trajectories
        divergencehistory.ref[I] = let
            div = scalarfield(setup)
            udev = vectorfield(setup)
            it = 1:5:length(sample.t)
            map(it) do it
                t = sample.t[it]
                u = selectdim(sample.u, ndims(sample.u), it) |> collect
                copyto!(udev, u)
                IncompressibleNavierStokes.divergence!(div, udev, setup)
                d = view(div, setup.grid.Ip)
                d = sum(abs2, d) / length(d)
                d = sqrt(d)
                Point2f(t, d)
            end
        end
        energyhistory.ref[I] = let
            it = 1:5:length(sample.t)
            udev = vectorfield(setup)
            map(it) do it
                t = sample.t[it]
                u = selectdim(sample.u, ndims(sample.u), it) |> collect
                copyto!(udev, u)
                Point2f(t, total_kinetic_energy(udev, setup))
            end
        end

        nupdate = 5
        writer = processor() do state
            div = scalarfield(setup)
            dhist = Point2f[]
            ehist = zeros(Point2f, 0)
            on(state) do (; u, t, n)
                if n % nupdate == 0
                    IncompressibleNavierStokes.divergence!(div, u, setup)
                    d = view(div, setup.grid.Ip)
                    d = sum(abs2, d) / length(d)
                    d = sqrt(d)
                    push!(dhist, Point2f(t, d))
                    e = total_kinetic_energy(u, setup)
                    push!(ehist, Point2f(t, e))
                end
            end
            state[] = state[] # Compute initial divergence
            (; dhist, ehist)
        end

        for (sym, closure_model, θ) in [
            (:nomodel, nothing, nothing),
            (:smag, smagorinsky_closure(setup), θ_smag[I]),
            (:model_prior, wrappedclosure(closure, setup), device(θ_cnn_prior[ig, ifil])),
            (:model_post, wrappedclosure(closure, setup), device(θ_cnn_post[I])),
        ]
            _, results = solve_unsteady(;
                setup = (; setup..., closure_model),
                ustart,
                tlims = (
                    sample.t[1],
                    projectorder == ProjectOrder.First ? t_DIF : sample.t[end],
                ),
                Δt_min = T(1e-5),
                method = RKProject(params.method, projectorder),
                processors = (; writer, logger = timelogger(; nupdate = 500)),
                psolver,
                θ,
            )
            divergencehistory[sym][I] = results.writer.dhist
            energyhistory[sym][I] = results.writer.ehist
        end
    end
    jldsave(joinpath(outdir, "history_nles=$(params.nles[1]).jld2"); energyhistory, divergencehistory)
    clean()
end

(; divergencehistory, energyhistory) = namedtupleload(joinpath(outdir, "history_nles=$(params.nles[1]).jld2"));

########################################################################## #src

# Check that energy is within reasonable bounds
energyhistory.ref .|> extrema
energyhistory.nomodel .|> extrema
energyhistory.smag .|> extrema
energyhistory.model_prior .|> extrema
energyhistory.model_post .|> extrema

# Check that divergence is within reasonable bounds
divergencehistory.ref .|> extrema
divergencehistory.nomodel .|> extrema
divergencehistory.smag .|> extrema
divergencehistory.model_prior .|> extrema
divergencehistory.model_post .|> extrema

########################################################################## #src

# ### Plot energy evolution

false && with_theme(; palette) do
    doplot() || return
    for (igrid, nles) in enumerate(params.nles)
        @info "Plotting energy evolution" nles
        fig = Figure(; size = (800, 450))
        g = GridLayout(fig[1, 1])
        for (iorder, projectorder) in enumerate(projectorders),
            (ifil, Φ) in enumerate(params.filters)

            I = CartesianIndex(igrid, ifil, iorder)
            subfig = g[ifil, iorder]
            ax = Axis(
                subfig;
                # xscale = log10,
                # yscale = log10,
                xlabel = "t",
                # ylabel = Φ isa FaceAverage ? "Face-average" : "Volume-average",
                ylabel = "E(t)",
                # ylabelfont = :bold,
                title = projectorder == ProjectOrder.First ? "DIF" : "DCF",
                titlevisible = ifil == 1,
                xlabelvisible = ifil == 2,
                xticksvisible = ifil == 2,
                xticklabelsvisible = ifil == 2,
                ylabelvisible = iorder == 1,
                yticksvisible = iorder == 1,
                yticklabelsvisible = iorder == 1,
            )
            # xlims!(ax, (1e-2, 5.0))
            # xlims!(ax, (0.0, 1.0))
            # ylims!(ax, (1.3, 2.3))
            plots = [
                (energyhistory.nomodel, :solid, 1, "No closure"),
                (energyhistory.smag, :solid, 2, "Smagorinsky"),
                (energyhistory.model_prior, :solid, 3, "CNN (prior)"),
                (energyhistory.model_post, :solid, 4, "CNN (post)"),
                (energyhistory.ref, :dash, 1, "Reference"),
            ]
            for (p, linestyle, i, label) in plots
                lines!(ax, p[I]; color = Cycled(i), linestyle, label)
                iorder == 1 && xlims!(-0.05, 1.05)
                # iorder == 1 && ylims!(1.1, 3.1)
                ylims!(1.3, 3.0)
            end

            # Plot zoom-in box
            if iorder == 2
                tlims = iorder == 1 ? (0.05, 0.2) : (0.8, 1.2)
                i1 = findfirst(p -> p[1] > tlims[1], energyhistory.ref[I])
                i2 = findfirst(p -> p[1] > tlims[2], energyhistory.ref[I])
                tlims = energyhistory.ref[I][i1][1], energyhistory.ref[I][i2][1]
                klims = energyhistory.ref[I][i1][2], energyhistory.ref[I][i2][2]
                dk = klims[2] - klims[1]
                # klims = klims[1] - 0.2 * dk, klims[2] + 0.2 * dk
                w = iorder == 1 ? 0.2 : 0.1
                klims = klims[1] + w * dk, klims[2] - w * dk
                box = [
                    Point2f(tlims[1], klims[1]),
                    Point2f(tlims[2], klims[1]),
                    Point2f(tlims[2], klims[2]),
                    Point2f(tlims[1], klims[2]),
                    Point2f(tlims[1], klims[1]),
                ]
                lines!(ax, box; color = :black)
                ax2 = Axis(
                    subfig;
                    # bbox = BBox(0.8, 0.9, 0.2, 0.3),
                    width = Relative(0.35),
                    height = Relative(0.35),
                    halign = 0.05,
                    valign = 0.95,
                    limits = (tlims..., klims...),
                    xscale = log10,
                    yscale = log10,
                    xticksvisible = false,
                    xticklabelsvisible = false,
                    xgridvisible = false,
                    yticksvisible = false,
                    yticklabelsvisible = false,
                    ygridvisible = false,
                    backgroundcolor = :white,
                )
                # https://discourse.julialang.org/t/makie-inset-axes-and-their-drawing-order/60987/5
                translate!(ax2.scene, 0, 0, 10)
                translate!(ax2.elements[:background], 0, 0, 9)
                for (p, linestyle, i, label) in plots
                    lines!(ax2, p[igrid, ifil, iorder]; color = Cycled(i), linestyle, label)
                end
            end

            Label(
                g[ifil, 0],
                # Φ isa FaceAverage ? "Face-average" : "Volume-average";
                Φ isa FaceAverage ? "FA" : "VA";
                # halign = :right,
                font = :bold,
                # rotation = pi/2,
                tellheight = false,
            )
        end
        colgap!(g, 10)
        rowgap!(g, 10)
        # colsize!(g, 1, Relative(1 / 5))
        Legend(fig[:, end+1], filter(x -> x isa Axis, fig.content)[1])
        name = "$plotdir/energy_evolution/"
        ispath(name) || mkpath(name)
        save("$(name)/nles=$(nles).pdf", fig)
        display(fig)
    end
end

########################################################################## #src

# ### Plot Divergence

with_theme(; palette) do
    doplot() || return
    islog = true
    for (igrid, nles) in enumerate(params.nles)
        @info "Plotting divergence" nles
        fig = Figure(; size = (800, 450))
        for (iorder, projectorder) in enumerate(projectorders),
            (ifil, Φ) in enumerate(params.filters)

            I = CartesianIndex(igrid, ifil, iorder)
            subfig = fig[ifil, iorder]
            ax = Axis(
                subfig;
                yscale = islog ? log10 : identity,
                xlabel = "t",
                ylabel = Φ isa FaceAverage ? "Face-average" : "Volume-average",
                ylabelfont = :bold,
                title = projectorder == ProjectOrder.First ? "DIF" : "DCF",
                titlevisible = ifil == 1,
                xlabelvisible = ifil == 2,
                xticksvisible = ifil == 2,
                xticklabelsvisible = ifil == 2,
                ylabelvisible = iorder == 1,
                yticksvisible = iorder == 1,
                yticklabelsvisible = iorder == 1,
            )
            lines!(ax, divergencehistory.nomodel[I]; label = "No closure")
            lines!(ax, divergencehistory.smag[I]; label = "Smagorinsky")
            lines!(ax, divergencehistory.model_prior[I]; label = "CNN (prior)")
            lines!(ax, divergencehistory.model_post[I]; label = "CNN (post)")
            lines!(
                ax,
                divergencehistory.ref[I];
                color = Cycled(1),
                linestyle = :dash,
                label = "Reference",
            )
            islog && ylims!(ax, (T(1e-6), T(1e3)))
            iorder == 1 && xlims!(ax, (-0.05, 1.05))
        end
        rowgap!(fig.layout, 10)
        colgap!(fig.layout, 10)
        Legend(fig[:, end+1], filter(x -> x isa Axis, fig.content)[1])
        name = "$plotdir/divergence/"
        ispath(name) || mkpath(name)
        save("$(name)/nles=$(nles).pdf", fig)
        display(fig)
    end
end

########################################################################## #src

# ## Solutions at different times

#let
#    s = length(params.nles), length(params.filters), length(projectorders)
#    temp = zeros(T, ntuple(Returns(0), params.D + 1))
#    keys = [:ref, :nomodel, :smag, :model_prior, :model_post]
#    times = T[0.1, 0.5, 1.0, 5.0]
#    itime_max_DIF = 3
#    times_exact = copy(times)
#    utimes = map(t -> (; map(k -> k => fill(temp, s), keys)...), times)
#    for (iorder, projectorder) in enumerate(projectorders),
#        (ifil, Φ) in enumerate(params.filters),
#        (igrid, nles) in enumerate(params.nles)
#
#        @info "Computing test solutions" projectorder Φ nles
#        I = CartesianIndex(igrid, ifil, iorder)
#        setup = getsetup(; params, nles)
#        psolver = default_psolver(setup)
#        sample = namedtupleload(getdatafile(outdir, nles, Φ, dns_seeds_test[1]))
#        ustart = selectdim(sample.u, ndims(sample.u), 1) |> collect
#        t = sample.t
#        solve(ustart, tlims, closure_model, θ) =
#            solve_unsteady(;
#                setup = (; setup..., closure_model),
#                ustart = device(ustart),
#                tlims,
#                method = RKProject(params.method, projectorder),
#                psolver,
#                θ,
#            )[1].u |> Array
#        t1 = t[1]
#        for i in eachindex(times)
#            # Only first times for First
#            i > itime_max_DIF && projectorder == ProjectOrder.First && continue
#
#            # Time interval
#            t0 = t1
#            t1 = times[i]
#
#            # Adjust t1 to be exactly on a reference time
#            it = findfirst(>(t1), t)
#            if isnothing(it)
#                # Not found: Final time
#                it = length(t)
#            end
#            t1 = t[it]
#            tlims = (t0, t1)
#            times_exact[i] = t1
#
#            getprev(i, sym) = i == 1 ? ustart : utimes[i-1][sym][I]
#
#            # Compute fields
#            utimes[i].ref[I] = selectdim(sample.u, ndims(sample.u), it) |> collect
#            utimes[i].nomodel[I] = solve(getprev(i, :nomodel), tlims, nothing, nothing)
#            utimes[i].smag[I] =
#                solve(getprev(i, :smag), tlims, smagorinsky_closure(setup), θ_smag[I])
#            utimes[i].model_prior[I] = solve(
#                getprev(i, :model_prior),
#                tlims,
#                wrappedclosure(closure, setup),
#                device(θ_cnn_prior[igrid, ifil]),
#            )
#            utimes[i].model_post[I] = solve(
#                getprev(i, :model_post),
#                tlims,
#                wrappedclosure(closure, setup),
#                device(θ_cnn_post[I]),
#            )
#        end
#        clean()
#    end
#    jldsave("$outdir/solutions.jld2"; u = utimes, t = times_exact, itime_max_DIF)
#end;
#clean();
let
    s = length(params.nles), length(params.filters), length(projectorders)
    temp = zeros(T, ntuple(Returns(0), params.D + 1))
    keys = [:ref, :nomodel, :smag, :model_prior, :model_post]
    times = T[0.1, 0.5, 1.0, 5.0]
    itime_max_DIF = 3
    times_exact = copy(times)
    utimes = map(t -> (; map(k -> k => fill(temp, s), keys)...), times)
    for (iorder, projectorder) in enumerate(projectorders),
        (ifil, Φ) in enumerate(params.filters),
        (igrid, nles) in enumerate(params.nles)

        @info "Computing test solutions" projectorder Φ nles
        I = CartesianIndex(igrid, ifil, iorder)
        setup = getsetup(; params, nles)
        psolver = default_psolver(setup)
        sample = namedtupleload(getdatafile(outdir, nles, Φ, dns_seeds_test[1]))
        ustart = selectdim(sample.u, ndims(sample.u), 1) |> collect
        t = sample.t

        function solve(ustart, tlims, closure_model, θ)
            result = solve_unsteady(;
                setup = (; setup..., closure_model),
                ustart = device(ustart),
                tlims,
                method = RKProject(params.method, projectorder),
                psolver,
                θ,
            )[1].u |> Array
            #@info result
            #Array(result)
        end
        t1 = t[1]
        for i in eachindex(times)
            # Only first times for First
            i > itime_max_DIF && projectorder == ProjectOrder.First && continue

            # Time interval
            t0 = t1
            t1 = times[i]

            # Adjust t1 to be exactly on a reference time
            it = findfirst(>(t1), t)
            if isnothing(it)
                # Not found: Final time
                it = length(t)
            end
            t1 = t[it]
            tlims = (t0, t1)
            times_exact[i] = t1

            getprev(i, sym) = i == 1 ? ustart : utimes[i-1][sym][I]

            # Compute fields
            utimes[i].ref[I] = selectdim(sample.u, ndims(sample.u), it) |> collect
            utimes[i].nomodel[I] = solve(getprev(i, :nomodel), tlims, nothing, nothing)
            utimes[i].smag[I] =
                solve(getprev(i, :smag), tlims, smagorinsky_closure(setup), θ_smag[I])
            utimes[i].model_prior[I] = solve(
                getprev(i, :model_prior),
                tlims,
                wrappedclosure(closure, setup),
                device(θ_cnn_prior[igrid, ifil]),
            )
            utimes[i].model_post[I] = solve(
                getprev(i, :model_post),
                tlims,
                wrappedclosure(closure, setup),
                device(θ_cnn_post[I]),
            )
        end
        clean()
    end
    jldsave("$outdir/solutions_nles=$(params.nles[1]).jld2"; u = utimes, t = times_exact, itime_max_DIF)
end;
clean();

# Load solution
solutions = namedtupleload("$outdir/solutions_nles=$(params.nles[1]).jld2");

########################################################################## #src

# ### Plot spectra
#
# Plot kinetic energy spectra.

with_theme(; palette) do
    doplot() || return
    for (ifil, Φ) in enumerate(params.filters), (igrid, nles) in enumerate(params.nles)
        @info "Plotting spectra" Φ nles
        fig = Figure(; size = (800, 450))
        fil = Φ isa FaceAverage ? "face-average" : "volume-average"
        setup = getsetup(; params, nles)
        (; Ip) = setup.grid
        (; inds, κ, K) = IncompressibleNavierStokes.spectral_stuff(setup)
        kmax = maximum(κ)
        allaxes = []
        for (iorder, projectorder) in enumerate(projectorders)
            rowaxes = []
            for (itime, t) in enumerate(solutions.t)
                # Only first time for First
                projectorder == ProjectOrder.First &&
                    itime > solutions.itime_max_DIF &&
                    continue

                fields = map(
                    k -> solutions.u[itime][k][igrid, ifil, iorder] |> device,
                    [:ref, :nomodel, :smag, :model_prior, :model_post],
                )
                specs = map(fields) do u
                    state = (; u)
                    spec = observespectrum(state; setup)
                    spec.ehat[]
                end
                ## Build inertial slope above energy
                logkrange = [0.45 * log(kmax), 0.85 * log(kmax)]
                krange = exp.(logkrange)
                slope, slopelabel = -T(3), L"$\kappa^{-3}$"
                slopeconst = maximum(specs[1] ./ κ .^ slope)
                offset = 3
                inertia = offset .* slopeconst .* krange .^ slope
                ## Nice ticks
                logmax = round(Int, log2(kmax + 1))
                # xticks = T(2) .^ (0:logmax)
                if logmax > 5
                    xticks = T[1, 4, 16, 64, 256]
                else
                    xticks = T[1, 2, 4, 8, 16, 32]
                end
                ## Make plot
                irow = projectorder == ProjectOrder.First ? 2 : 1
                subfig = fig[irow, itime]
                ax = Axis(
                    subfig;
                    xticks,
                    xlabel = "κ",
                    xlabelvisible = irow == 2,
                    xticksvisible = irow == 2,
                    xticklabelsvisible = irow == 2,
                    ylabel = projectorder == ProjectOrder.First ? "DIF" : "DCF",
                    ylabelfont = :bold,
                    ylabelvisible = itime == 1,
                    yticksvisible = itime == 1,
                    yticklabelsvisible = itime == 1,
                    xscale = log2,
                    yscale = log10,
                    limits = (1, kmax, T(1e-8), T(1)),
                    title = irow == 1 ? "t = $(round(t; digits = 1))" : "",
                )

                # Plot zoom-in box
                k1, k2 = klims = extrema(κ)
                center = 0.8
                dk = 0.025
                logklims = (center - dk) * log(k2), (center + dk) * log(k2)
                k1, k2 = klims = exp.(logklims)
                i1 = findfirst(>(k1), κ)
                i2 = findfirst(>(k2), κ)
                elims = specs[1][i1], specs[1][i2]
                loge1, loge2 = log.(elims)
                de = (loge1 - loge2) * 0.05
                logelims = loge1 + de, loge2 - de
                elims = exp.(logelims)
                box = [
                    Point2f(klims[1], elims[1]),
                    Point2f(klims[2], elims[1]),
                    Point2f(klims[2], elims[2]),
                    Point2f(klims[1], elims[2]),
                    Point2f(klims[1], elims[1]),
                ]
                ax_zoom = Axis(
                    subfig;
                    width = Relative(0.45),
                    height = Relative(0.4),
                    halign = 0.05,
                    valign = 0.05,
                    limits = (klims..., reverse(elims)...),
                    xscale = log10,
                    yscale = log10,
                    xticksvisible = false,
                    xticklabelsvisible = false,
                    xgridvisible = false,
                    yticksvisible = false,
                    yticklabelsvisible = false,
                    ygridvisible = false,
                    backgroundcolor = :white,
                )
                # https://discourse.julialang.org/t/makie-inset-axes-and-their-drawing-order/60987/5
                translate!(ax_zoom.scene, 0, 0, 10)
                translate!(ax_zoom.elements[:background], 0, 0, 9)

                # Plot lines in both axes
                for ax in (ax, ax_zoom)
                    lines!(ax, κ, specs[2]; color = Cycled(1), label = "No model")
                    lines!(ax, κ, specs[3]; color = Cycled(2), label = "Smagorinsky")
                    lines!(ax, κ, specs[4]; color = Cycled(3), label = "CNN (prior)")
                    lines!(ax, κ, specs[5]; color = Cycled(4), label = "CNN (post)")
                    lines!(
                        ax,
                        κ,
                        specs[1];
                        color = Cycled(1),
                        linestyle = :dash,
                        label = "Reference",
                    )
                    lines!(
                        ax,
                        krange,
                        inertia;
                        color = Cycled(1),
                        label = slopelabel,
                        linestyle = :dot,
                    )
                end

                # Show box in main plot
                lines!(ax, box; color = :black)

                # axislegend(ax; position = :lb)
                autolimits!(ax)

                push!(allaxes, ax)
                push!(rowaxes, ax)
            end
            linkaxes!(rowaxes...)
        end
        # linkaxes!(allaxes...)
        # linkaxes!(filter(x -> x isa Axis, fig.content)...)
        Legend(
            fig[2, solutions.itime_max_DIF+1:end],
            fig.content[1];
            tellwidth = false,
            tellheight = false,
            # width = Auto(false),
            # height = Auto(false),
            # halign = :left,
            # framevisible = false,
        )
        Label(
            fig[0, 1:end],
            "Energy spectra ($fil, n = $nles)";
            valign = :bottom,
            font = :bold,
        )
        rowgap!(fig.layout, 10)
        colgap!(fig.layout, 10)
        # ylims!(ax, (T(1e-3), T(0.35)))
        specdir = "$plotdir/spectra/"
        ispath(specdir) || mkpath(specdir)
        name = splatfileparts(; filter = Φ, nles)
        save("$specdir/$name.pdf", fig)
        display(fig)
    end
end

########################################################################## #src

# ### Plot fields

with_theme(; palette) do
    doplot() || return
    ## Reference box for eddy comparison
    x1 = 0.3
    x2 = 0.5
    y1 = 0.5
    y2 = 0.7
    box = [
        Point2f(x1, y1),
        Point2f(x2, y1),
        Point2f(x2, y2),
        Point2f(x1, y2),
        Point2f(x1, y1),
    ]
    for (ifil, Φ) in enumerate(params.filters)
        Φ isa FaceAverage || continue
        # fig = Figure(; size = (710, 400))
        fig = Figure(; size = (770, 360))
        irow = 0
        itime = 3
        for (igrid, nles) in enumerate(params.nles)
            itime == 1 && (nles in [32, 64] || continue)
            itime == 3 && (nles in [64, 128] || continue)
            # nles in [128, 256] || continue
            irow += 1
            setup = getsetup(; params, nles)
            (; Ip, xp) = setup.grid
            xplot = xp[1][2:end-1], xp[2][2:end-1]
            xplot = xplot .|> Array
            # lesmodel = iorder == 1 ? "DIF" : "DCF"
            # fig = fieldplot(
            #     (; u, temp = nothing, t = T(0));
            #     setup,
            #     title,
            #     docolorbar = false,
            #     size = (500, 500),
            # )

            utime = solutions.u[itime]
            icol = 0

            for (u, title) in [
                (utime.nomodel[igrid, ifil, 2], "No closure"),
                (utime.nomodel[igrid, ifil, 2], "Smagorinsky (DCF)"),
                (utime.model_post[igrid, ifil, 1], "CNN (post, DIF)"),
                (utime.model_post[igrid, ifil, 2], "CNN (post, DCF)"),
                (utime.ref[igrid, ifil, 2], "Reference"),
            ]
                icol += 1
                u = device(u)
                w = vorticity(u, setup)
                w = interpolate_ω_p(w, setup)
                w = w[Ip] |> Array
                colorrange = get_lims(w)
                ax = Axis(
                    fig[irow, icol];
                    title,
                    xticksvisible = false,
                    xticklabelsvisible = false,
                    yticksvisible = false,
                    yticklabelsvisible = false,
                    ylabel = "n = $nles",
                    ylabelvisible = icol == 1,
                    titlevisible = irow == 1,
                    aspect = DataAspect(),
                )
                heatmap!(ax, xplot..., w; colorrange)
                lines!(ax, box; linewidth = 3, color = Cycled(2)) # Red in palette
            end
        end
        fil = Φ isa FaceAverage ? "face-average" : "volume-average"
        tlab = round(solutions.t[itime]; digits = 1)
        Label(fig[0, 1:end], "Vorticity ($fil, t = $tlab)"; valign = :bottom, font = :bold)
        colgap!(fig.layout, 10)
        rowgap!(fig.layout, 10)
        display(fig)
        path = "$plotdir/les_fields"
        ispath(path) || mkpath(path)
        name = splatfileparts(; itime, filter = Φ)
        name = joinpath(path, name)
        fname = "$(name).png"
        save(fname, fig)
    end
end

# Plot vorticity
let
    doplot() || return
    nles = 32
    sample = namedtupleload(getdatafile(outdir, nles, FaceAverage(), dns_seeds_test[1]))
    setup = getsetup(; params, nles)
    u = selectdim(sample.u, ndims(sample.u), 1) |> collect |> device
    w = vorticity(u, setup) |> Array |> Observable
    title = sample.t[1] |> string |> Observable
    fig = heatmap(w; axis = (; title))
    for i = 1:1:length(sample.t)
        u = selectdim(sample.u, ndims(sample.u), i) |> collect |> device
        w[] = vorticity(u, setup) |> Array
        title[] = "t = $(round(sample.t[i]; digits = 2))"
        display(fig)
        sleep(0.05)
    end
end
