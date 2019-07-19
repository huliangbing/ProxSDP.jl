function moi_sdplib(optimizer, path; verbose = false, test = false)

    if verbose
        println("running: $(path)")
    end
    MOI.empty!(optimizer)
    if test
        @test MOI.is_empty(optimizer)
    end

    n, m, F, c = sdplib_data(path)

    nvars = sympackedlen(n)

    X = MOI.add_variables(optimizer, nvars)
    vov = MOI.VectorOfVariables(X)
    cX = MOI.add_constraint(optimizer, vov, MOI.PositiveSemidefiniteConeTriangle(n))

    Xsq = Matrix{MOI.VariableIndex}(undef, n,n)
    ivech!(Xsq, X)
    Xsq = Matrix(Symmetric(Xsq,:U))

    # Objective function
    objf_t = [MOI.ScalarAffineTerm(F[0][idx...], Xsq[idx...])
        for idx in zip(findnz(F[0])[1:end-1]...)]
    MOI.set(optimizer, MOI.ObjectiveFunction{MOI.ScalarAffineFunction{Float64}}(), MOI.ScalarAffineFunction(objf_t, 0.0))
    MOI.set(optimizer, MOI.ObjectiveSense(), MOI.MIN_SENSE)

    # Linear equality constraints
    for k in 1:m
        ctr_k = [MOI.ScalarAffineTerm(F[k][idx...], Xsq[idx...]) 
            for idx in zip(findnz(F[k])[1:end-1]...)]
        MOI.add_constraint(optimizer, MOI.ScalarAffineFunction(ctr_k, 0.0), MOI.EqualTo(c[k]))
    end

    MOI.optimize!(optimizer)

    objval = MOI.get(optimizer, MOI.ObjectiveValue())

    stime = -1.0
    try
        stime = MOI.get(optimizer, MOI.SolveTime())
    catch
        println("could not query time")
    end

    Xsq_s = MOI.get.(optimizer, MOI.VariablePrimal(), Xsq)
    minus_rank = length([eig for eig in eigen(Xsq_s).values if eig < -1e-4])
    if test
        @test minus_rank == 0
    end
    # @test tr(F[0] * Xsq_s) - obj < 1e-1
    # for i in 1:m
    #     @test abs(tr(F[i] * Xsq_s)-c[i]) < 1e-1
    # end

    verbose && sdplib_eval(F,c,n,m,Xsq_s)

    rank = -1
    return (objval, stime, rank)
end