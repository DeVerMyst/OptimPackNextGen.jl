#
# vmlmb.jl -
#
# Implement Éric Thiébaut's VMLMB algorithm in Julia.
#
# The algorithm is described in:
#
#     Éric Thiébaut, "Optimization issues in blind deconvolution algorithms"
#     in Astronomical Data Analysis II, SPIE Proc. 4847, 174-183 (2002).
#
#------------------------------------------------------------------------------
#
# This file is part of TiPi.jl which is licensed under the MIT "Expat" License:
#
# Copyright (C) 2015, Éric Thiébaut.
#
#------------------------------------------------------------------------------

# FIXME: add a savememory option
# FIXME: add a savebest option
# FIXME: use S[slot(0)] and Y[slot(0)] to store x - x0 and gp0 and thus
#        save memory.
# FIXME: detect whether subset of free variables is complete, empty, or
#        unchanged to speed up code
function vmlmb!{T<:AbstractFloat,N}(fg!::Function, x::Array{T,N}, m::Integer,
                                    dom::AbstractBoundedSet{T};
                                    maxiter::Integer=-1,
                                    maxeval::Integer=-1,
                                    lnsrch::LineSearch=BacktrackLineSearch(),
                                    gtol=(0.0, 1e-6),
                                    slen=(1.0, 0.0),
                                    verb::Integer=0)
    # Type for scalars (use at least double precision).
    Scalar = promote_type(T, Cdouble)

    # Size of the problem.
    const n = length(x)

    # Check number of corrections to memorize.
    m = Int(m)
    m < 1 && error("bad number of variable metric corrections")

    # Check options.
    #if (is_void(maxiter)) maxiter = -1
    #if (is_void(slen)) slen = [1.0, 0.0]
    #if (is_void(gtol)) {
    #  gtol = [0.0, 1e-4]
    #} else if (identof(gtol) <= Y_DOUBLE && numberof(gtol) <= 2
    #           && min(gtol) >= 0.0) {
    #  if (numberof(gtol) == 2) {
    #    gtol = double(gtol)
    #  } else {
    #    gtol = [gtol(1), 0.0]
    #  }
    #} else {
    #  error, "bad parameter GTOL"
    #}

    # Allocate arrays for L-BFGS operator.
    S = Array(Array{T,N}, m)
    Y = Array(Array{T,N}, m)
    for i in 1:m
        S[i] = Array(T, size(x))
        Y[i] = Array(T, size(x))
    end
    beta = Array(T, m)
    rho  = Array(T, m)
    gamma::Scalar = 0 # initial approximation of inverse Hessian
    mp::Int = 0       # actual number of saved pairs
    updates::Int = 0  # total number of updates since start

    # The following closure returns the index where is stored the
    # (updates-j)-th correction pair.  Argument j must be in the inclusive
    # range 0:mp with mp the actual number of saved corrections.  At any
    # moment, 0 ≤ mp ≤ updates; thus updates - j ≥ 0.
    slot(j::Int) = (updates - j)%m + 1

    # Declare local variables and allocate workspaces.
    f::Scalar = 0             # function value at x
    g    = Array(T, size(x)) # gradient at x
    x0   = Array(T, size(x)) # origin of line search
    f0::Scalar = 0           # function value at x0
    g0   = Array(T, size(x)) # gradient at x0
    df0::Scalar = 0          # directional derivative at x0
    gp   = Array(T, size(x)) # projected gradient
    d    = Array(T, size(x)) # search direction
    temp = Array(T, size(x)) # temporary array
    gtest::Scalar = 0        # gradient-based threshold for convergence
    gpnorm::Scalar = 0       # Euclidean norm of the projected gradient
    alpha::Scalar = 0        # step length
    sty::Scalar = 0          # inner product <s,y>
    yty::Scalar = 0          # inner product <y,y>
    const deriv = usederivative(lnsrch)
    w = Array(T, size(x))    # 1 for free variables; 0 else
    state::Int = NEW_ITERATE
    evaluations::Int = 0
    restarts::Int = 0
    iterations::Int = 0

    # Create a closure to print information (this simplifies a lot the
    # structure of the code).
    if verb > 0
        t0 = time_ns()*1e-9
        function printer()
            t = time_ns()*1e-9
            if evaluations == 1
                println("# VMLMB algorithm (N=$n, M=$m)")
                println("#  ITER   EVAL  RESTART TIME (s)           PENALTY           GRADIENT        STEP")
                println("--------------------------------------------------------------------------------------")
            end
            @printf(" %6d %6d  %4d   %9.3f  %24.16e  %12.6e  %12.6e\n",
                    iterations, evaluations, restarts,
                    t - t0, f, gpnorm, alpha)
        end
    end

    # Main loop of the algorithm.
    while true
        # Make sure X is feasible, compute function and gradient at X.
        project_variables!(x, dom, x)
        f = fg!(x, g)
        evaluations += 1

        # Compute projected gradient and check for global convergence.
        project_gradient!(gp, dom, x, g)
        gpnorm = norm2(gp)
        if evaluations == 1
            gtest = gtol[1] + gtol[2]*gpnorm
        end
        if gpnorm <= gtest
            # Algorithm has converged.
            if state == LINE_SEARCH
                iterations += 1
            end
            state = CONVERGENCE
            break
        end
        if state == LINE_SEARCH
            # Line search is in progress.
            if deriv
                # FIXME: re-use temp = x - x0 to update LBFGS (see below)
                combine!(temp, 1, x, -1, x0) # effective step
                df = inner(g, temp)/alpha
            else
                df = 0
            end
            (state, alpha) = iterate!(lnsrch, alpha, f, df)
            if state == NEW_ITERATE
                # Line search has converged, increment iteration number.
                iterations += 1
                if maxiter >= 0 && iterations >= maxiter
                    state = TOO_MANY_ITERATIONS
                    break
                end
            end
        end
        if state == NEW_ITERATE
            # A new iterate is available.
            if verb > 0 && (iterations%verb) == 0
                printer()
            end

            # Determine the set of free variables.
            @simd for i in 1:n
                @inbounds w[i] = (gp[i] != 0 ? 1 : 0)
            end

            # A new search direction is required.
            if iterations >= 1
                # Update L-BFGS approximation of the Hessian.
                k = slot(0)
                combine!(S[k], 1, x, -1, x0) # FIXME: already done in TEMP
                combine!(Y[k], 1, g, -1, g0)
                updates += 1
                mp = min(mp + 1, m)
            end
            if mp >= 1
                # Apply the L-BFGS Strang's two-loop recursion to compute a
                # search direction.
                combine!(d, -1, g)
                gamma = 0
                for j in 1:+1:mp
                    k = slot(j)
                    sty = inner(w, Y[k], S[k])
                    if sty > 0
                        rho[k] = 1/sty
                        beta[k] = rho[k]*inner(w, d, S[k])
                        update!(d, -beta[k], Y[k])
                        if gamma == 0
                            yty = inner(w, Y[k], Y[k])
                            if yty > 0
                                gamma = sty/yty
                            end
                        end
                    else
                        rho[k] = 0
                    end
                end
                if gamma > 0
                    # Apply initial inverse Hessian approximation and proceed
                    # with the second loop of Strang's recursion.
                    combine!(d, gamma, d)
                    for j in mp:-1:1
                        k = slot(j)
                        if rho[k] > 0
                            update!(d, beta[k] - rho[k]*inner(w, d, Y[k]), S[k])
                        end
                    end

                    # Enforce search direction to belong to the subset of the
                    # free variables.
                    @simd for i in 1:n
                        @inbounds d[i] *= w[i]
                    end

                    # Check whether the algorithm has produced a descent
                    # direction.
                    project_direction!(temp, dom, x, d)
                    df0 = inner(temp, g)
                    if df0 >= 0
                        # Not a descent direction.
                        restarts += 1
                        mp = 0
                    else
                        alpha = 1
                    end
                end
            end
            if mp < 1
                # Use (projected) steepest projected descent.
                combine!(d, -1, gp)
                df0 = -gpnorm^2
                alpha = initial_step(x, d, slen)
            end

            # Start line search.
            alpha = shortcut_step(alpha, dom, x, d)
            if alpha <= 0
                state = WOULD_BLOCK
                break
            end
            f0 = f
            copy!(x0, x)
            copy!(g0, g)
            (state, alpha) = start!(lnsrch, f0, df0, alpha)
        end

        # Next point to try.
        if maxeval > 0 && evaluations >= maxeval
            state = TOO_MANY_EVALUATIONS
            break
        end
        combine!(x, 1, x0, alpha, d)
    end

    # Algorithm terminated.
    if f > f0
        # Restore best solution so far.
        copy!(x, x0)
        f = f0
    end
    verb > 0 && printer()
    if state > CONVERGENCE
        warn(Optimization.reason[state])
    end
    return f
end
