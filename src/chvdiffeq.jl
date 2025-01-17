###################################################################################################
struct CHV{Tode} <: AbstractCHVIterator
	ode::Tode	# ODE solver to use for the flow in between jumps
end

# NOTE: 2023-08-08 13:53:39 CMT 
# defines a method which updates/mutates xdot based on the calculated rates
# used as ODEFunction in the definition of the ODEProblem used by `chv_diffeq!`
function (chv::CHV)(xdot, x, caract::PDMPCaracteristics, t) 
	tau = x[end]
	rate = get_tmp(caract.ratecache, x)
	
	# NOTE: 2023-08-08 13:52:06 CMT
	# this below, updates (mutates) the rates vector but it is called with sum_rate = true
	# (last argument) therefore returns the sum of the updated rates vector (all R! functions
	# must return a tuple which is (sum rates, bound); bound is always 0., but sum_rate is
	# sum(rate) when last argument is true else, is 0.)
	#
	# NOTE: 2023-08-08 22:11:28 CMT
	# the sum_rate, but also updates (mutates) the rate vector as a side effect!
	sr = caract.R(rate, x, caract.xd, caract.parms, tau, true)[1] 
	# NOTE: 2023-08-08 22:11:43 CMT
	# now, the call to F mutates xdot
	caract.F(xdot, x, caract.xd, caract.parms, tau) 
	# NOTE: 2023-08-08 22:12:29 CMT
	# then augment xdot with 1
	xdot[end] = 1
	
	# NOTE: 2023-08-08 13:54:31 CMT
	# finally, adjust xdot by dividing each element by sr (sum_rate) -- WHY?
	# why does this divide ALL elements in xdot by sum(rate) ? 
	# -> see Veltz 2015 A new twist... paper, equations 3.1, 3.2, 3.3:
	# sr is Rₜₒₜ(y(s))
	# NOTE: this happens only at DiscreteCallback execution
	@inbounds for i in eachindex(xdot)
		xdot[i] = xdot[i] / sr
	end
	return nothing
end

###################################################################################################
### implementation of the CHV algo using DiffEq
# the following does not allocate

# The following function is a callback to discrete jump. Its role is to perform the jump on the solution given by the ODE solver
# callable struct
function chvjump(integrator, prob::PDMPProblem, save_pre_jump, save_rate, verbose)
	# we declare the characteristics for convenience
	caract = prob.caract
	rate = get_tmp(caract.ratecache, integrator.u)
	simjptimes = prob.simjptimes

	# final simulation time
	tf = prob.tspan[2]

	# find the next jump time
	t = integrator.u[end]

	simjptimes.lastjumptime = t

	verbose && printstyled(color=:green, "--> Jump detected at t = $t !!\n")
	# verbose && printstyled(color=:green, "--> jump not yet performed, xd = ", caract.xd,"\n")

	if save_pre_jump && (t <= tf)
		verbose && printstyled(color=:green, "----> saving pre-jump\n")
		pushXc!(prob, (integrator.u[1:end-1]))
		pushXd!(prob, copy(caract.xd))
		pushTime!(prob, t)
		#save rates for debugging
		save_rate && push!(prob.rate_hist, sum(rate))
	end

	# execute the jump
	caract.R(rate, integrator.u, caract.xd, caract.parms, t, false)
	if t < tf
		#save rates for debugging
		save_rate && push!(prob.rate_hist, sum(rate) )

		# Update event
		ev = pfsample(rate)

		# we perform the jump
		affect!(caract.pdmpjump, ev, integrator.u, caract.xd, caract.parms, t)

		u_modified!(integrator, true)

		@inbounds for ii in eachindex(caract.xc)
			caract.xc[ii] = integrator.u[ii]
		end
	end
	# verbose && printstyled(color=:green,"--> jump computed, xd = ",caract.xd,"\n")
	# we register the next time interval to solve the extended ode
	simjptimes.njumps += 1
	simjptimes.tstop_extended += -log(rand())
	add_tstop!(integrator, simjptimes.tstop_extended)
	verbose && printstyled(color=:green,"--> End jump\n\n")
end

function chv_diffeq!(problem::PDMPProblem,
			ti::Tc, tf::Tc, X_extended::vece,
			verbose = false;
			ode = Tsit5(),
			save_positions = (false, true),
			n_jumps::Td = Inf64,
			save_rate = false,
			finalizer = finalizer,
			# options for DifferentialEquations
			reltol=1e-7,
			abstol=1e-9,
			kwargs...) where {Tc, Td, vece}
	verbose && println("#"^30)
	verbose && printstyled(color=:red,"Entry in chv_diffeq\n")

	ti, tf = problem.tspan
	algopdmp = CHV(ode)

	# initialise the problem. If I call twice this solve function, it should give the same result...
	init!(problem)

	# we declare the characteristics for convenience
	caract = problem.caract
	
	# NOTE: 2023-08-08 13:58:50 CMT
	# simjptimes is a PDMPJumpTime{Tc, Td}
	simjptimes = problem.simjptimes

#ISSUE HERE, IF USING A PROBLEM p MAKE SURE THE TIMES in p.sim ARE WELL SET
	# set up the current time as the initial time
	t = ti
	# previous jump time, needed because problem.simjptimes.lastjumptime contains next jump time even if above tf
	tprev = t

	# vector to hold the state space for the extended system
	# X_extended = similar(problem.xc, length(problem.xc) + 1)
	# @show typeof(X_extended) vece

	for ii in eachindex(caract.xc)
		X_extended[ii] = caract.xc[ii]
	end
	X_extended[end] = ti

	# definition of the callback structure passed to DiffEq
	# NOTE: 2023-08-08 21:30:13 CMT
	# Is this integrator described in DifferentialEquations manual at
	# 'Integrator interface' 
	# (https://docs.sciml.ai/DiffEqDocs/stable/basics/integrator/#integrator)?
	cb = DiscreteCallback(problem, integrator -> chvjump(integrator, problem, save_positions[1], save_rate, verbose), save_positions = (false, false))

	# define the ODE flow, this leads to big memory saving
	# NOTE: 2023-08-08 13:49:57 CMT
	# algopdmp is CHV(ode)'s call method: (chv::CHV)(xdot, x, caract::PDMPCaracteristics, t) 
	#
	# general interface is ODEProblem(f, u0, tspan, p) with :
	# • f = ODEFunction; here this is `algopdmp(xdot, x, caract, tt)`
	# • u0 = initial condition; here, this is X_extended
	# • tspan; here it is (0.0, 1e9) for all cases (!!!)
	prob_CHV = ODEProblem((xdot, x, data, tt) -> algopdmp(xdot, x, caract, tt), X_extended, (0.0, 1e9), kwargs...)
	
	# NOTE: 2023-08-08 22:06:36 CMT
	# initialize the integrator: init(prob, alg; kwargs), where
	# • prob is an ODEProblem, `prob_CHV`
	# • alg is the solver, `ode` 
	# • kwargs are as below...
	integrator = init(prob_CHV, ode,
						tstops = simjptimes.tstop_extended,
						callback = cb,
						save_everystep = false,
						reltol = reltol,
						abstol = abstol,
						advance_to_tstop = true)

	# current jump number
	njumps = 0
	simjptimes.njumps = 1

	# reference to the rate vector
	rate = get_tmp(caract.ratecache, integrator.u)

	while (t < tf) && (simjptimes.njumps < n_jumps)
		verbose && println("--> n = $(problem.simjptimes.njumps), t = $t, δt = ", simjptimes.tstop_extended)
		step!(integrator)

		@assert( t < simjptimes.lastjumptime, "Could not compute next jump time $(simjptimes.njumps).\nReturn code = $(integrator.sol.retcode)\n $t < $(simjptimes.lastjumptime),\n solver = $ode. dt = $(t - simjptimes.lastjumptime)")
		t, tprev = simjptimes.lastjumptime, t

		# the previous step was a jump! should we save it?
		if njumps < simjptimes.njumps && save_positions[2] && (t <= tf)
			# verbose && println("----> save post-jump, xd = ",problem.Xd)
			pushXc!(problem, copy(caract.xc))
			pushXd!(problem, copy(caract.xd))
			pushTime!(problem, t)
			njumps +=1
			verbose && println("----> end save post-jump, ")
		end
		finalizer(rate, caract.xc, caract.xd, caract.parms, t)
	end
	# we check that the last bit [t_last_jump, tf] is not missing
	if t>tf
		verbose && println("----> LAST BIT!!, xc = ", caract.xc[end], ", xd = ", caract.xd, ", t = ", problem.time[end])
		prob_last_bit = ODEProblem((xdot,x,data,tt) -> caract.F(xdot, x, caract.xd, caract.parms, tt), copy(caract.xc), (tprev, tf))
		sol = SciMLBase.solve(prob_last_bit, ode)
		verbose && println("-------> xc[end] = ",sol.u[end])
		pushXc!(problem, sol.u[end])
		pushXd!(problem, copy(caract.xd))
		pushTime!(problem, sol.t[end])
	end
	return PDMPResult(problem, save_positions)
end

function solve(problem::PDMPProblem,
				algo::CHV{Tode},
				X_extended;
				verbose = false,
				n_jumps = Inf64,
				save_positions = (false,
				true),
				reltol = 1e-7,
				abstol = 1e-9,
				save_rate = false,
				finalizer = finalize_dummy) where {Tode <: SciMLBase.DEAlgorithm}

	return chv_diffeq!(problem, problem.tspan[1], problem.tspan[2], X_extended, verbose; ode = algo.ode, save_positions = save_positions, n_jumps = n_jumps, reltol = reltol, abstol = abstol, save_rate = save_rate, finalizer = finalizer)
end

"""
	solve(problem::PDMPProblem, algo; verbose = false, n_jumps = Inf64, save_positions = (false, true), reltol = 1e-7, abstol = 1e-9, save_rate = false, finalizer = finalize_dummy, kwargs...)

Simulate the PDMP `problem` using the CHV algorithm.

# Arguments
- `problem::PDMPProblem`
- `alg` can be `CHV(ode)` (for the [CHV algorithm](https://arxiv.org/abs/1504.06873)), `Rejection(ode)` for the Rejection algorithm and `RejectionExact()` for the rejection algorithm in case the flow in between jumps is known analytically. In this latter case, `prob.F` is used for the specification of the Flow. The ODE solver `ode` can be any solver of [DifferentialEquations.jl](https://github.com/JuliaDiffEq/DifferentialEquations.jl) like `Tsit5()` for example or anyone of the list `[:cvode, :lsoda, :adams, :BDF, :euler]`. Indeed, the package implement an iterator interface which does not work yet with `ode = LSODA()`. In order to have access to the ODE solver `LSODA()`, one should use `ode = :lsoda`.
- `verbose` display information during simulation
- `n_jumps` maximum number of jumps to be computed
- `save_positions` which jump position to record, pre-jump (save_positions[1] = true) and/or post-jump (save_positions[2] = true).
- `reltol`: relative tolerance used in the ODE solver
- `abstol`: absolute tolerance used in the ODE solver
- `ind_save_c`: which indices of `xc` should be saved
- `ind_save_d`: which indices of `xd` should be saved
- `save_rate = true`: requires the solver to save the total rate. Can be useful when estimating the rate bounds in order to use the Rejection algorithm as a second try.
-  `X_extended = zeros(Tc, 1 + 1)`: (advanced use) options used to provide the shape of the extended array in the [CHV algorithm](https://arxiv.org/abs/1504.06873). Can be useful in order to use `StaticArrays.jl` for example.
-  `finalizer = finalize_dummy`: allows the user to pass a function `finalizer(rate, xc, xd, p, t)` which is called after each jump. Can be used to overload / add saving / plotting mechanisms.
- `kwargs` keyword arguments passed to the ODE solver (from DifferentialEquations.jl)

!!! note "Solvers for the `JumpProcesses` wrapper"
    We provide a basic wrapper that should work for `VariableJumps` (the other types of jumps have not been thoroughly tested). You can use `CHV` for this type of problems. The `Rejection` solver is not functional yet.

"""
function solve(problem::PDMPProblem{Tc, Td, vectype_xc, vectype_xd, Tcar, TR},
				algo::CHV{Tode};
				verbose = false,
				n_jumps = Inf64,
				save_positions = (false, true),
				reltol = 1e-7,
				abstol = 1e-9,
				save_rate = false,
				finalizer = finalize_dummy, kwargs...) where {Tc, Td, vectype_xc, vectype_xd, TR, Tcar, Tode <: SciMLBase.DEAlgorithm}

	# resize the extended vector to the proper dimension
	X_extended = zeros(Tc, length(problem.caract.xc) + 1)

	return chv_diffeq!(problem,
						problem.tspan[1],
						problem.tspan[2],
						X_extended,
						verbose;
						ode = algo.ode,
						save_positions = save_positions,
						n_jumps = n_jumps,
						reltol = reltol,
						abstol = abstol,
						save_rate = save_rate,
						finalizer = finalizer,
						kwargs...)
end
