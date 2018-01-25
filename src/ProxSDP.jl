module ProxSDP

using MathOptInterface, TimerOutputs
# using PyCall
# @pyimport scipy.linalg as sp

include("mathoptinterface.jl")

immutable Dims
    n::Int  # Size of primal variables
    p::Int  # Number of linear equalities
    m::Int  # Number of linear inequalities
end

type AffineSets
    A::AbstractMatrix
    G::AbstractMatrix
    b::AbstractVector
    h::AbstractVector
    c::AbstractVector
    sdpcone::Vector{Tuple{Vector{Int},Vector{Int}}}
end

struct CPResult
    status::Int
    primal::Vector{Float64}
    dual::Vector{Float64}
    slack::Vector{Float64}
    primal_residual::Float64
    dual_residual::Float64
    objval::Float64
end

struct CPOptions
    fullmat::Bool
    verbose::Bool
end

function chambolle_pock(
    affine_sets, dims, verbose=true, max_iter=Int(1e+5), primal_tol=1e-5, dual_tol=1e-5
)   
    opt = CPOptions(false, verbose)
    c_orig = zeros(1)
    # use algorithm in full square matrix mode or triangular mode
    if opt.fullmat
        M = zeros(Int, dims.n, dims.n)
        iv = affine_sets.sdpcone[1][1]
        im = affine_sets.sdpcone[1][2]
        for i in eachindex(iv)
            M[im[i]] = iv[i]
        end
        X = Symmetric(M,:L)
        ids = vec(X)

        offdiag_ids = setdiff(Set(ids),Set(diag(X)))
        for i in offdiag_ids
            affine_sets.c[i] /= 2.0
        end
        
        # modify A, G and c
        affine_sets.A = affine_sets.A[:,ids]
        affine_sets.G = affine_sets.G[:,ids]
        affine_sets.c = affine_sets.c[ids]
        c_orig = copy(affine_sets.c)
        
    else  
        M = zeros(Int, dims.n, dims.n)
        iv = affine_sets.sdpcone[1][1]
        im = affine_sets.sdpcone[1][2]
        for i in eachindex(iv)
            M[im[i]] = iv[i]
        end
        X = Symmetric(M,:L)
        ids = vec(X)

        offdiag_ids = setdiff(Set(ids), Set(diag(X)))
        c_orig = copy(affine_sets.c)
        for i in offdiag_ids
            affine_sets.c[i] /= 2.0
        end  
    end

    converged = false
    tic()
    @timeit "print" if verbose
        println(" Starting Chambolle-Pock algorithm")
        println("----------------------------------------------------------")
        println("|  iter  | comb. res | prim. res |  dual res |    rho    |")
        println("----------------------------------------------------------")
    end

    @timeit "Init" begin
    # Given
    m, n, p = dims.m, dims.n, dims.p

    # logging
    best_comb_residual = Inf
    converged, status = false, false
    comb_residual, dual_residual, primal_residual = Float64[], Float64[], Float64[]
    sizehint!(comb_residual, max_iter)
    sizehint!(dual_residual, max_iter)
    sizehint!(primal_residual, max_iter)

    # Primal variables
    x, x_old =  if opt.fullmat
        zeros(n^2), zeros(n^2)
    else
        zeros(n*(n+1)/2), zeros(n*(n+1)/2)
    end
    # Dual variables
    u, u_old = zeros(m+p), zeros(m+p)

    end

    # Build full problem matrices
    M = vcat(affine_sets.A, affine_sets.G)
    rhs = vcat(affine_sets.b, affine_sets.h)
    Mt = M'

    # # Diagonal scaling
    # K = M
    # Kt = M'
    # div = vec(sum(abs.(M), 1))
    # div[find(x-> x == 0.0, div)] = 1.0
    # T = sparse(diagm(1.0 ./ div))
    # div = vec(sum(abs.(M), 2))
    # div[find(x-> x == 0.0, div)] = 1.0
    # S = sparse(diagm(1.0 ./ div))

    # # Cache matrix multiplications
    # TKt = T * Kt
    # SK = S * K
    # Srhs = S * rhs
    # affine_sets.b = rhs[1:dims.p]
    # affine_sets.h = rhs[dims.p+1:end]

    # Step-size
    alpha_max = 1.0 / norm(full(M), 2)
    alpha = (1.0 - 1e-8) * alpha_max

    # Fixed-point loop
    @timeit "CP loop" for k in 1:max_iter

        # Update primal variable
        @timeit "primal" begin
            x = sdp_cone_projection(x - alpha * (Mt * u + affine_sets.c), dims, affine_sets, opt)::Vector{Float64}
            # x = sdp_cone_projection(x - alpha * (TKt * u + affine_sets.c), dims, affine_sets, opt)::Vector{Float64}
        end

        # Update dual variable
        @timeit "dual" begin
            u += alpha * M * (2.0 * x - x_old)::Vector{Float64}
            u -= alpha * box_projection(u / alpha, dims, affine_sets)::Vector{Float64}
            # u += alpha * SK * (2.0 * x - x_old)::Vector{Float64}
            # u -= alpha * box_projection(u / alpha, dims, affine_sets)::Vector{Float64}
        end

        # Compute residuals
        @timeit "logging" begin
            push!(primal_residual, norm(x - x_old) / norm(x_old))
            push!(dual_residual, norm(u - u_old) / norm(u_old))
            push!(comb_residual, primal_residual[end] + dual_residual[end])

            if mod(k, 100) == 0 && opt.verbose
                print_progress(k, primal_residual[end], dual_residual[end])
            end
        end

        # Keep track
        @timeit "tracking" begin
            copy!(x_old, x)
            copy!(u_old, u)
        end

        # Check convergence
        if primal_residual[end] < primal_tol && dual_residual[end] < dual_tol
            converged = true
            break
        end
    end

    time = toq()
    println("Time = $time")

    @show u
    @show dot(c_orig, x)
    return CPResult(Int(converged), x, u, 0.0*x, primal_residual[end], dual_residual[end], dot(c_orig, x))
end

function box_projection(v::Vector{Float64}, dims::Dims, aff::AffineSets)::Vector{Float64}
    # Projection onto =b
    if !isempty(aff.b) 
        v[1:dims.p] = aff.b
    end
    # Projection onto <= h
    if !isempty(aff.h)
        v[dims.p+1:end] = min.(v[dims.p+1:end], aff.h)
    end
    return v
end

function sdp_cone_projection(v::Vector{Float64}, dims::Dims, aff::AffineSets, opt::CPOptions)::Vector{Float64}

    if opt.fullmat
        X = @timeit "reshape" Symmetric(reshape(v, (dims.n, dims.n)))
        fact = @timeit "eig" eigfact!(X)
        D = diagm(max.(fact[:values], 0.0))
        M2 = fact[:vectors] * D * fact[:vectors]'

        v = vec(M2)
    else
        @timeit "reshape" begin
            M = zeros(dims.n, dims.n)
            iv = aff.sdpcone[1][1]
            im = aff.sdpcone[1][2]
            for i in eachindex(iv)
                M[im[i]] = v[iv[i]]
            end
            X = Symmetric(M,:L)
        end

        fact = @timeit "eig" eigfact!(X, 0.0, Inf)
        D = diagm(fact[:values])
        M2 = fact[:vectors] * D * fact[:vectors]'

        for i in eachindex(iv)
            v[iv[i]] = M2[im[i]]
        end
    end

    return v
end

function print_progress(k, primal_res, dual_res)
    s_k = @sprintf("%d",k)
    s_k *= " |"
    s_s = @sprintf("%.4f",primal_res + dual_res)
    s_s *= " |"
    s_p = @sprintf("%.4f",primal_res)
    s_p *= " |"
    s_d = @sprintf("%.4f",dual_res)
    s_d *= " |"
    a = "|"
    a *= " "^max(0,9-length(s_k))
    a *= s_k
    a *= " "^max(0,12-length(s_s))
    a *= s_s
    a *= " "^max(0,12-length(s_p))
    a *= s_p
    a *= " "^max(0,12-length(s_d))
    a *= s_d
    println(a)

end

end