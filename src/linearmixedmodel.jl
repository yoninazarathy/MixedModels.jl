abstract LinearMixedModel <: MixedModel

type LMMGeneral{Ti<:Union(Int32,Int64)} <: LinearMixedModel
    L::CholmodFactor{Float64,Ti}
    LambdatZt::CholmodSparse{Float64,Ti}
    X::ModelMatrix                      # fixed-effects model matrix
    Xs::Vector{Matrix{Float64}}         # X_1,X_2,...,X_k
    beta::Vector{Float64}
    inds::Vector{Any}
    lambda::Vector{Matrix{Float64}}     # k lower triangular mats
    u::Vector{Matrix{Float64}}
    y::Vector{Float64}
end

const template = Formula(:(~ foo))      # for evaluating the lhs of r.e. terms

function lmer(f::Formula, fr::AbstractDataFrame)
    mf = ModelFrame(f, fr); df = mf.df

    ## extract random-effects terms and reorder by non-increasing number of levels
    re = filter(x->Meta.isexpr(x,:call) && x.args[1] == :|, mf.terms.terms)
    0 < length(re) || error("Formula $f has no random-effects terms")
    re = re[sortperm(map(x->length(df[x.args[3]].pool),re),Sort.Reverse)]

    ## create and fill vectors Xs, etc. from the random-effects terms
    Xs = Matrix{Float64}[]; lambda = Matrix{Float64}[]; u = Matrix{Float64}[]
    inds = {}; rowval = Matrix{Int}[]; offset = 0
    for t in re                    # iterate over random-effects terms
        mm = t.args[2] == 1 ? ones(size(df,1),1) : # Matrix{Float64} from lhs of t
             (template.rhs=t.args[2]; ModelMatrix(ModelFrame(template, df))).m
        push!(Xs, mm)
        p = size(mm,2)
        push!(lambda, eye(p))
        gf = df[t.args[3]]     # grouping factor as a PooledDataVector
        l = length(gf.pool)
        push!(u, zeros(p,l))
        nu = p*l
        ii = gf.refs
        push!(inds, ii)
        push!(rowval, (reshape(1:nu,(p,l)) + offset)[:,ii])
        offset += nu
    end
    Ti = Int; if offset < typemax(Int32) Ti = Int32 end ## use 32-bit ints if possible
    X = ModelMatrix(mf)
    nz = hcat(Xs...)'
    ## Allow a CholmodSparse! method for SparseMatrixCSC to prevent a copy here
    LambdatZt = CholmodSparse(SparseMatrixCSC(offset, size(df,1),
                                               convert(Vector{Ti}, [1:size(nz,1):length(nz)+1]),
                                               convert(Vector{Ti}, vec(vcat(rowval...))),
                                               vec(nz)))
    L = chm_analyze(LambdatZt)
    LMMGeneral(chm_analyze(LambdatZt),LambdatZt,X,Xs,zeros(size(X.m,2)),inds,lambda,
               u,vector(model_response(mf)))
end
lmer(ex::Expr, fr::AbstractDataFrame) = lmer(Formula(ex), fr)

function updateL(m::LMMGeneral, theta::Vector{Float64})
    n = length(m.y); k = length(m.inds)
    nzmat = reshape(m.LambdatZt.nzval, (div(length(m.LambdatZt.nzval),n),n))
    lambda = m.lambda; Xs = m.Xs
    tpos = 1; roff = 0                  # position in theta, row offset
    for i in 1:k
        T = lambda[i]
        p = size(T,1)                   # size of i'th template matrix
        for j in 1:p, i in j:p          # fill lower triangle from theta
            T[i,j] = theta[tpos]; tpos += 1
            (i == j && T[i,j] < 0.) || error("Negative diagonal element in T")
        end
        gemm!('T','T',1.0,T,Xs[i],0.0,sub(nzmat,roff+(1:p),1:n))
        roff += p
    end
    chm_factorize_p!(m.L,m.LambdatZt,1.)
    m
end


## Optimization of objective using BOBYQA
## According to convention the name should be fit! as this is a
## mutating function but I figure fit is obviously mutating and I
## wanted to piggy-back on the fit generic created in Distributions
function fit(m::LinearMixedModel, verbose::Bool)
    if !isfit(m)
        k = length(thvec!(m))
        opt = Opt(:LN_BOBYQA, k)
        ftol_abs!(opt, 1e-6)    # criterion on deviance changes
        xtol_abs!(opt, 1e-6)    # criterion on all parameter value changes
        lower_bounds!(opt, lower!(m))
        function obj(x::Vector{Float64}, g::Vector{Float64})
            if length(g) > 0 error("gradient evaluations are not provided") end
            objective!(m, x)
        end
        if verbose
            count = 0
            function vobj(x::Vector{Float64}, g::Vector{Float64})
                if length(g) > 0 error("gradient evaluations are not provided") end
                count += 1
                val = obj(x, g)
                println("f_$count: $val, $x")
                val
            end
            min_objective!(opt, vobj)
        else
            min_objective!(opt, obj)
        end
        fmin, xmin, ret = optimize(opt, thvec!(m))
        if verbose println(ret) end
        setfit!(m)
    end
    m
end
fit(m::LinearMixedModel) = fit(m, false)      # non-verbose

## A type for a linear mixed model should provide, directly or
## indirectly, methods for:
##  obs!(m) -> *reference to* the observed response vector
##  exptd!(m) -> *reference to* mean response vector at current parameter values
##  sqrtwts!(m) -> *reference to* square roots of the case weights if used, can be of
##      length 0, *not copied*
##  L(m) -> a vector of matrix representations that together provide
##      the Cholesky factor of the random-effects part of the system matrix
##  wrss(m) -> weighted residual sum of squares
##  pwrss(m) -> penalized weighted residual sum of squares
##  Zt!(m) -> an RSC matrix representation of the transpose of Z - can be a reference
##  size(m) -> n, p, q, t (lengths of y, beta, u and # of re terms)
##  X!(x) -> a reference to the fixed-effects model matrix
##  RX!(x) -> a reference to a Cholesky factor of the downdated X'X
##  isfit(m) -> Bool - Has the model been fit?
##  lower!(m) -> *reference to* the vector of lower bounds on the theta parameters
##  thvec!(m) -> current theta as a vector - can be a reference
##  fixef!(m) -> value of betahat - the model is fit before extraction
##  ranef!(m) -> conditional modes of the random effects
##  setfit!(m) -> set the boolean indicator of the model having been
##     fit; returns m
##  uvec(m) -> a reference to the current conditional means of the
##     spherical random effects. Unlike a call to ranef or fixef, a
##     call to uvec does not cause the model to be fit.
##  reml!(m) -> set the REML flag and clear the fit flag; returns m
##  objective!(m, thv) -> set a new value of the theta vector; update
##     beta, u and mu; return the objective (deviance or REML criterion)
##  grplevels(m) -> a vector giving the number of levels in the
##     grouping factor for each re term.
##  VarCorr!(m) -> a vector of estimated variance-covariance matrices
##     for each re term and for the residuals - can trigger a fit

## Default implementations
function wrss(m::LinearMixedModel)
    y = obs!(m); mu = exptd!(m); wt = sqrtwts!(m)
    w = bool(length(wt))
    s = zero(eltype(y))
    for i in 1:length(y)
        r = y[i] - mu[i]
        if w r /= sqrtwts[i] end
        s += r * r
    end
    s
end
pwrss(m::LinearMixedModel) = (s = wrss(m);for u in uvec!(m) s += u*u end; s)
setfit!(m::LinearMixedModel) = (m.fit = true; m)
unsetfit!(m::LinearMixedModel) = (m.fit = false; m)
setreml!(m::LinearMixedModel) = (m.REML = true; m.fit = false; m)
unsetreml!(m::LinearMixedModel) = (m.REML = false; m.fit = false; m)
obs!(m::LinearMixedModel) = m.y
fixef!(m::LinearMixedModel) = fit(m).beta
isfit(m::LinearMixedModel) = m.fit
isreml(m::LinearMixedModel) = m.REML
lower(m::LinearMixedModel) = m.lower
thvec!(m::LinearMixedModel) = fit(m).theta
exptd!(m::LinearMixedModel) = m.mu
uvec!(m::LinearMixedModel) = m.u

function deviance(m::LinearMixedModel)
    if isreml(m) unsetreml!(m) end
    objective!(m, thvec!(m))
end
reml(m::LinearMixedModel) = (setreml!(m); fit(unsetfit!(m)); objective(m, thvec!(m)))

function show(io::IO, m::LinearMixedModel)
    fit(m)
    REML = m.REML
    criterionstr = REML ? "REML" : "maximum likelihood"
    println(io, "Linear mixed model fit by $criterionstr")
    oo = objective!(m,m.theta)
    if REML
        println(io, " REML criterion: $oo")
    else
        println(io, " logLik: $(-oo/2), deviance: $oo")
    end
    vc = VarCorr(m)
    println("\n  Variance components: $vc")
    n, p, q = size(m)
    println("  Number of obs: $n; levels of grouping factors: $(grplevs(m))")
    println("  Fixed-effects parameters: $(fixef(m))")
end

abstract ScalarLinearMixedModel <: LinearMixedModel

function VarCorr(m::ScalarLinearMixedModel)
    fit(m)
    n, p, q = size(m)
    [m.theta .^ 2, 1.] * (pwrss(m)/float(n - (m.REML ? p : 0)))
end

function grplevs(m::ScalarLinearMixedModel)
    rv = m.Zt.rowval
    [length(unique(rv[i,:]))::Int for i in 1:size(rv,1)]
end

## Check validity and install a new value of theta;
##  update lambda, A
## function installtheta(m::SimpleLinearMixedModel, theta::Vector{Float64})
##     n, p, q = size(m)
##     if length(theta) != length(m.theta) error("Dimension mismatch") end
##     if any(theta .< m.lower)
##         error("theta = $theta violates lower bounds $(m.lower)")
##     end
##     m.theta[:] = theta[:]               # copy in place
##     for i in 1:length(theta)            # update Lambda (stored as a vector)
##         fill!(m.lambda, theta[i], int(m.Zt.rowrange[i]))
##     end
## end
