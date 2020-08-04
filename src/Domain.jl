using Parameters
using LinearAlgebra
using StaticArrays
using Calculus
using SmoothingSplines
using DiffEqBase
using ForwardDiff
using Tracker
using ReverseDiff

abstract type AbstractDomain end
export AbstractDomain

abstract type AbstractConstantKDomain <: AbstractDomain  end
export AbstractConstantKDomain

abstract type AbstractVariableKDomain <: AbstractDomain end
export AbstractVariableKDomain

@with_kw mutable struct ConstantTPDomain{N<:AbstractPhase,S<:Integer,W<:Real, W2<:Real, I<:Integer, Q<:AbstractArray} <: AbstractConstantKDomain
    phase::N
    indexes::Q #assumed to be in ascending order
    parameterindexes::Q
    constantspeciesinds::Array{S,1}
    T::W
    P::W
    kfs::Array{W,1}
    krevs::Array{W,1}
    efficiencyinds::Array{I,1}
    Gs::Array{W,1}
    rxnarray::Array{Int64,2}
    mu::W = 0.0
    diffusivity::Array{W,1} = Array{Float64,1}()
    jacobian::Array{W,2} = Array{Float64,2}(undef,(0,0))
    sensitivity::Bool = false
    jacuptodate::MArray{Tuple{1},Bool,1,1}=MVector(false)
    t::MArray{Tuple{1},W2,1,1}=MVector(0.0)
    p::Array{W,1}
end
function ConstantTPDomain(;phase::E2,initialconds::Dict{X,X2},constantspecies::Array{X3,1}=Array{String,1}(),
    sparse::Bool=false,sensitivity::Bool=false) where {E<:Real,E2<:AbstractPhase,Q<:AbstractInterface,W<:Real,X,X2,X3}
    #set conditions and initialconditions
    T = 0.0
    P = 0.0
    y0 = zeros(length(phase.species)+1)
    spnames = [x.name for x in phase.species]
    for (key,val) in initialconds
        if key == "T"
            T = val
        elseif key == "P"
            P = val
        else
            ind = findfirst(isequal(key),spnames)
            @assert typeof(ind)<: Integer  "$key not found in species list: $spnames"
            y0[ind] = val
        end
    end


    @assert T != 0.0
    @assert P != 0.0
    ns = y0[1:end-1]
    N = sum(ns)

    if length(constantspecies) > 0
        spcnames = getfield.(phase.species,:name)
        constspcinds = [findfirst(isequal(k),spcnames) for k in constantspecies]
    else
        constspcinds = Array{Int64,1}()
    end
    efficiencyinds = [rxn.index for rxn in phase.reactions if typeof(rxn.kinetics)<:AbstractFalloffRate && length(rxn.kinetics.efficiencies) > 0]
    Gs = calcgibbs(phase,T)
    if :solvent in fieldnames(typeof(phase)) && typeof(phase.solvent) != EmptySolvent
        mu = phase.solvent.mu(T)
    else
        mu = 0.0
    end
    if phase.diffusionlimited
        diffs = getfield.(phase.species,:diffusion)(T=T,mu=mu,P=P)::Array{typeof(T),1}
    else
        diffs = Array{typeof(T),1}()
    end
    C = P/(R*T)
    V = N*R*T/P
    y0[end] = V
    kfs,krevs = getkfkrevs(phase=phase,T=T,P=P,C=C,N=N,ns=ns,Gs=Gs,diffs=diffs,V=V)
    kfsp = deepcopy(kfs)
    for ind in efficiencyinds
        kfsp[ind] = 1.0
    end
    p = vcat(deepcopy(Gs),kfsp)
    if sparse
        jacobian=spzeros(typeof(T),length(phase.species),length(phase.species))
    else
        jacobian=zeros(typeof(T),length(phase.species),length(phase.species))
    end
    rxnarray = getreactionindices(phase)
    return ConstantTPDomain(phase,[phase.species[1].index,phase.species[end].index,phase.species[end].index+1],[1,length(phase.species)+length(phase.reactions)],constspcinds,
        T,P,kfs,krevs,efficiencyinds,Gs,rxnarray,mu,diffs,jacobian,sensitivity,MVector(false),MVector(0.0),p), y0, p
end
export ConstantTPDomain

@with_kw struct ConstantVDomain{N<:AbstractPhase,S<:Integer,W<:Real,W2<:Real,I<:Integer,Q<:AbstractArray} <: AbstractVariableKDomain
    phase::N
    indexes::Q #assumed to be in ascending order
    parameterindexes::Q
    constantspeciesinds::Array{S,1}
    V::W
    efficiencyinds::Array{I,1}
    rxnarray::Array{Int64,2}
    jacobian::Array{W,2}
    sensitivity::Bool = false
    jacuptodate::MArray{Tuple{1},Bool,1,1}=MVector(false)
    t::MArray{Tuple{1},W2,1,1}=MVector(0.0)
    p::Array{W,1}
end
function ConstantVDomain(;phase::Z,initialconds::Dict{X,E},constantspecies::Array{X2,1}=Array{String,1}(),
    sparse::Bool=false,sensitivity::Bool=false) where {E,X,X2,Z<:IdealGas,Q<:AbstractInterface}

    #set conditions and initialconditions
    T = 0.0
    P = 0.0
    V = 0.0
    ns = zeros(length(phase.species))
    spnames = [x.name for x in phase.species]
    for (key,val) in initialconds
        if key == "T"
            T = val
        elseif key == "P"
            P = val
        elseif key == "V"
            V = val
        else
            ind = findfirst(isequal(key),spnames)
            @assert typeof(ind)<: Integer  "$key not found in species list: $spnames"
            ns[ind] = val
        end
    end
    @assert V != 0.0 || (T != 0.0 && P != 0.0)
    N = sum(ns)
    if V == 0.0
        V = N*R*T/P
    elseif T == 0.0
        T = P*V/(R*N)
    elseif P == 0.0
        P = N*R*T/V
    else
        throw(error("ConstantVDomain overspecified with T,P and V"))
    end
    y0 = vcat(ns,T,P)
    p = vcat(zeros(length(phase.species)),ones(length(phase.reactions)))
    if length(constantspecies) > 0
        spcnames = getfield.(phase.species,:name)
        constspcinds = [findfirst(isequal(k),spcnames) for k in constantspecies]
    else
        constspcinds = Array{Int64,1}()
    end
    efficiencyinds = [rxn.index for rxn in phase.reactions if typeof(rxn.kinetics)<:AbstractFalloffRate && length(rxn.kinetics.efficiencies) > 0]
    if sparse
        jacobian=zeros(typeof(T),length(phase.species)+2,length(phase.species)+2)
    else
        jacobian=zeros(typeof(T),length(phase.species)+2,length(phase.species)+2)
    end
    rxnarray = getreactionindices(phase)
    return ConstantVDomain(phase,[phase.species[1].index,phase.species[end].index,phase.species[end].index+1,phase.species[end].index+2],[1,length(phase.species)+length(phase.reactions)],constspcinds,
    V,efficiencyinds,rxnarray,jacobian,sensitivity,MVector(false),MVector(0.0),p), y0, p
end
export ConstantVDomain

@with_kw struct ConstantPDomain{N<:AbstractPhase,S<:Integer,W<:Real,W2<:Real,I<:Integer,Q<:AbstractArray} <: AbstractVariableKDomain
    phase::N
    indexes::Q #assumed to be in ascending order
    parameterindexes::Q
    constantspeciesinds::Array{S,1}
    P::W
    efficiencyinds::Array{I,1}
    rxnarray::Array{Int64,2}
    jacobian::Array{W,2}
    sensitivity::Bool = false
    jacuptodate::MArray{Tuple{1},Bool,1,1}=MVector(false)
    t::MArray{Tuple{1},W2,1,1}=MVector(0.0)
    p::Array{W,1}
end
function ConstantPDomain(;phase::Z,initialconds::Dict{X,E},constantspecies::Array{X2,1}=Array{String,1}(),
    sparse::Bool=false,sensitivity::Bool=false) where {E,X,X2,Z<:IdealGas,Q<:AbstractInterface}

    #set conditions and initialconditions
    T = 0.0
    P = 0.0
    V = 0.0
    ns = zeros(length(phase.species))
    spnames = [x.name for x in phase.species]
    for (key,val) in initialconds
        if key == "T"
            T = val
        elseif key == "P"
            P = val
        elseif key == "V"
            V = val
        else
            ind = findfirst(isequal(key),spnames)
            @assert typeof(ind)<: Integer  "$key not found in species list: $spnames"
            ns[ind] = val
        end
    end
    @assert P != 0.0 || (T != 0.0 && V != 0.0)
    N = sum(ns)
    if P == 0.0
        P = N*R*T/V
    elseif T == 0.0
        T = P*V/(R*N)
    elseif V == 0.0
        V = N*R*T/P
    else
        throw(error("ConstantPDomain overspecified with T,P and V"))
    end
    y0 = vcat(ns,T,V)
    p = vcat(zeros(length(phase.species)),ones(length(phase.reactions)))
    if length(constantspecies) > 0
        spcnames = getfield.(phase.species,:name)
        constspcinds = [findfirst(isequal(k),spcnames) for k in constantspecies]
    else
        constspcinds = Array{Int64,1}()
    end
    efficiencyinds = [rxn.index for rxn in phase.reactions if typeof(rxn.kinetics)<:AbstractFalloffRate && length(rxn.kinetics.efficiencies) > 0]
    if sparse
        jacobian=zeros(typeof(T),length(phase.species)+2,length(phase.species)+2)
    else
        jacobian=zeros(typeof(T),length(phase.species)+2,length(phase.species)+2)
    end
    rxnarray = getreactionindices(phase)
    return ConstantPDomain(phase,[phase.species[1].index,phase.species[end].index,phase.species[end].index+1,phase.species[end].index+2],[1,length(phase.species)+length(phase.reactions)],constspcinds,
    P,efficiencyinds,rxnarray,jacobian,sensitivity,MVector(false),MVector(0.0),p), y0, p
end
export ConstantPDomain

@with_kw struct ParametrizedTPDomain{N<:AbstractPhase,S<:Integer,W<:Real,W2<:Real,I<:Integer,Q<:AbstractArray} <: AbstractVariableKDomain
    phase::N
    indexes::Q #assumed to be in ascending order
    parameterindexes::Q
    constantspeciesinds::Array{S,1}
    T::Function
    P::Function
    efficiencyinds::Array{I,1}
    rxnarray::Array{Int64,2}
    jacobian::Array{W,2}
    sensitivity::Bool = false
    jacuptodate::MArray{Tuple{1},Bool,1,1}=MVector(false)
    t::MArray{Tuple{1},W2,1,1}=MVector(0.0)
    p::Array{W,1}
end
function ParametrizedTPDomain(;phase::Z,initialconds::Dict{X,Any},constantspecies::Array{X2,1}=Array{String,1}(),
    sparse::Bool=false,sensitivity::Bool=false) where {X,X2,Z<:IdealGas,Q<:AbstractInterface}

    #set conditions and initialconditions
    T = 0.0
    P = 0.0
    V = 0.0
    ts = 0.0
    ns = zeros(length(phase.species))
    spnames = [x.name for x in phase.species]
    for (key,val) in initialconds
        if key == "T"
            T = val
        elseif key == "P"
            P = val
        elseif key == "V"
            V = val
        elseif key == "ts"
            ts = val
        else
            ind = findfirst(isequal(key),spnames)
            @assert typeof(ind) <: Integer  "$key not found in species list: $spnames"
            ns[ind] = val
        end
    end
    @assert V != 0.0 || (T != 0.0 && P != 0.0)
    if isa(T,AbstractArray)
        Tfcn = getspline(ts,T)
    elseif isa(T,Function)
        Tfcn = T
    else
        throw(error("ParametrizedTPDomain must take \"T\" as a function or if an array of times for \"ts\" is supplied as an array of volumes"))
    end
    if isa(P,AbstractArray)
        Pfcn = getspline(ts,P)
    elseif isa(P,Function)
        Pfcn = P
    else
        throw(error("ParametrizedTPDomain must take \"P\" as a function or if an array of times for \"ts\" is supplied as an array of volumes"))
    end

    N = sum(ns)
    V = N*R*Tfcn(0.0)/Pfcn(0.0)
    y0 = zeros(length(phase.species)+1)
    y0[phase.species[1].index:phase.species[end].index] = ns
    y0[phase.species[end].index+1] = V
    p = vcat(zeros(length(phase.species)),ones(length(phase.reactions)))
    if length(constantspecies) > 0
        spcnames = getfield.(phase.species,:name)
        constspcinds = [findfirst(isequal(k),spcnames) for k in constantspecies]
    else
        constspcinds = Array{Int64,1}()
    end
    efficiencyinds = [rxn.index for rxn in phase.reactions if typeof(rxn.kinetics)<:AbstractFalloffRate && length(rxn.kinetics.efficiencies) > 0]
    if sparse
        jacobian=zeros(typeof(V),length(phase.species)+1,length(phase.species)+1)
    else
        jacobian=zeros(typeof(V),length(phase.species)+1,length(phase.species)+1)
    end
    rxnarray = getreactionindices(phase)
    return ParametrizedTPDomain(phase,[phase.species[1].index,phase.species[end].index,phase.species[end].index+1],[1,length(phase.species)+length(phase.reactions)],constspcinds,
    Tfcn,Pfcn,efficiencyinds,rxnarray,jacobian,sensitivity,MVector(false),MVector(0.0),p), y0, p
end
export ParametrizedTPDomain

@with_kw struct ParametrizedVDomain{N<:AbstractPhase,S<:Integer,W<:Real,W2<:Real,I<:Integer,Q<:AbstractArray} <: AbstractVariableKDomain
    phase::N
    indexes::Q #assumed to be in ascending order
    parameterindexes::Q
    constantspeciesinds::Array{S,1}
    V::Function
    efficiencyinds::Array{I,1}
    rxnarray::Array{Int64,2}
    jacobian::Array{W,2}
    sensitivity::Bool = false
    jacuptodate::MArray{Tuple{1},Bool,1,1}=MVector(false)
    t::MArray{Tuple{1},W2,1,1}=MVector(0.0)
    p::Array{W,1}
end
function ParametrizedVDomain(;phase::Z,initialconds::Dict{X,Any},constantspecies::Array{X2,1}=Array{String,1}(),
    sparse::Bool=false,sensitivity::Bool=false) where {X,X2,E<:Real,Z<:IdealGas,Q<:AbstractInterface}

    #set conditions and initialconditions
    T = 0.0
    P = 0.0
    V = 0.0
    ts = Array{Float64,1}()
    ns = zeros(length(phase.species))
    spnames = [x.name for x in phase.species]
    @assert "V" in keys(initialconds)
    for (key,val) in initialconds
        if key == "T"
            T = val
        elseif key == "P"
            P = val
        elseif key == "V"
            V = val
        elseif key == "ts"
            ts = val
        else
            ind = findfirst(isequal(key),spnames)
            @assert typeof(ind)<: Integer  "$key not found in species list: $spnames"
            ns[ind] = val
        end
    end
    @assert isa(V,Function) || isa(V,AbstractArray)
    if isa(V,AbstractArray)
        Vfcn = getspline(ts,V)
    elseif isa(V,Function)
        Vfcn = V
    else
        throw(error("ParametrizedVDomain must take \"V\" as a function or if an array of times for \"ts\" is supplied as an array of volumes"))
    end
    N = sum(ns)
    if T == 0.0
        T = P*Vfcn(0.0)/(R*N)
    elseif P == 0.0
        P = N*R*T/Vfcn(0.0)
    else
        ns *= (P*Vfcn(0.0)/(R*T))/sum(ns) #automatically scale down moles if pressure specified
    end
    y0 = vcat(ns,T,P)
    p = vcat(zeros(length(phase.species)),ones(length(phase.reactions)))
    if length(constantspecies) > 0
        spcnames = getfield.(phase.species,:name)
        constspcinds = [findfirst(isequal(k),spcnames) for k in constantspecies]
    else
        constspcinds = Array{Int64,1}()
    end
    efficiencyinds = [rxn.index for rxn in phase.reactions if typeof(rxn.kinetics)<:AbstractFalloffRate && length(rxn.kinetics.efficiencies) > 0]
    if sparse
        jacobian=zeros(typeof(T),length(phase.species)+2,length(phase.species)+2)
    else
        jacobian=zeros(typeof(T),length(phase.species)+2,length(phase.species)+2)
    end
    rxnarray = getreactionindices(phase)
    return ParametrizedVDomain(phase,[phase.species[1].index,phase.species[end].index,phase.species[end].index+1,phase.species[end].index+2],[1,length(phase.species)+length(phase.reactions)],constspcinds,
    Vfcn,efficiencyinds,rxnarray,jacobian,sensitivity,MVector(false),MVector(0.0),p), y0, p
end
export ParametrizedVDomain

@with_kw struct ParametrizedPDomain{N<:AbstractPhase,S<:Integer,W<:Real,W2<:Real,I<:Integer,Q<:AbstractArray} <: AbstractVariableKDomain
    phase::N
    indexes::Q #assumed to be in ascending order
    parameterindexes::Q
    constantspeciesinds::Array{S,1}
    P::Function
    efficiencyinds::Array{I,1}
    rxnarray::Array{Int64,2}
    jacobian::Array{W,2}
    sensitivity::Bool = false
    jacuptodate::MArray{Tuple{1},Bool,1,1}=MVector(false)
    t::MArray{Tuple{1},W2,1,1}=MVector(0.0)
    p::Array{W,1}
end
function ParametrizedPDomain(;phase::Z,initialconds::Dict{X,Any},constantspecies::Array{X2,1}=Array{String,1}(),
    sparse::Bool=false,sensitivity::Bool=false) where {X,X2,E<:Real,Z<:IdealGas,Q<:AbstractInterface}

    #set conditions and initialconditions
    T = 0.0
    P = 0.0
    V = 0.0
    ts = Array{Float64,1}()
    ns = zeros(length(phase.species))
    spnames = [x.name for x in phase.species]
    @assert "P" in keys(initialconds)
    for (key,val) in initialconds
        if key == "T"
            T = val
        elseif key == "P"
            P = val
        elseif key == "V"
            V = val
        elseif key == "ts"
            ts = val
        else
            ind = findfirst(isequal(key),spnames)
            @assert typeof(ind)<: Integer  "$key not found in species list: $spnames"
            ns[ind] = val
        end
    end
    @assert isa(P,Function) || isa(P,AbstractArray)
    if isa(P,AbstractArray)
        Pfcn = getspline(ts,P)
    elseif isa(P,Function)
        Pfcn = P
    else
        throw(error("ParametrizedPDomain must take \"P\" as a function or if an array of times for \"ts\" is supplied as an array of volumes"))
    end
    N = sum(ns)
    if T == 0.0
        T = Pfcn(0.0)*V/(R*N)
    elseif V == 0.0
        V = N*R*T/Pfcn(0.0)
    else
        ns *= (Pfcn(0.0)*V/(R*T))/sum(ns) #automatically scale down moles if volume specified
    end
    y0 = vcat(ns,T,V)
    p = vcat(zeros(length(phase.species)),ones(length(phase.reactions)))
    if length(constantspecies) > 0
        spcnames = getfield.(phase.species,:name)
        constspcinds = [findfirst(isequal(k),spcnames) for k in constantspecies]
    else
        constspcinds = Array{Int64,1}()
    end
    efficiencyinds = [rxn.index for rxn in phase.reactions if typeof(rxn.kinetics)<:AbstractFalloffRate && length(rxn.kinetics.efficiencies) > 0]
    if sparse
        jacobian=zeros(typeof(T),length(phase.species)+2,length(phase.species)+2)
    else
        jacobian=zeros(typeof(T),length(phase.species)+2,length(phase.species)+2)
    end
    rxnarray = getreactionindices(phase)
    return ParametrizedPDomain(phase,[phase.species[1].index,phase.species[end].index,phase.species[end].index+1,phase.species[end].index+2],[1,length(phase.species)+length(phase.reactions)],constspcinds,
    Pfcn,efficiencyinds,rxnarray,jacobian,sensitivity,MVector(false),MVector(0.0),p), y0, p
end
export ParametrizedPDomain

@with_kw mutable struct ConstantTVDomain{N<:AbstractPhase,S<:Integer,W<:Real, W2<:Real, I<:Integer, Q<:AbstractArray} <: AbstractConstantKDomain
    phase::N
    indexes::Q #assumed to be in ascending order
    parameterindexes::Q
    constantspeciesinds::Array{S,1}
    T::W
    V::W
    kfs::Array{W,1}
    krevs::Array{W,1}
    kfsnondiff::Array{W,1}
    efficiencyinds::Array{I,1}
    Gs::Array{W,1}
    rxnarray::Array{Int64,2}
    mu::W = 0.0
    diffusivity::Array{W,1} = Array{Float64,1}()
    jacobian::Array{W,2} = Array{Float64,2}(undef,(0,0))
    sensitivity::Bool = false
    jacuptodate::MArray{Tuple{1},Bool,1,1}=MVector(false)
    t::MArray{Tuple{1},W2,1,1}=MVector(0.0)
    p::Array{W,1}
end
function ConstantTVDomain(;phase::Z,initialconds::Dict{X,E},constantspecies::Array{X2,1}=Array{String,1}(),
    sparse=false,sensitivity=false) where {E,X,X2, Z<:AbstractPhase,Q<:AbstractInterface,W<:Real}
    #set conditions and initialconditions
    T = 0.0
    V = 0.0
    P = 1.0e8
    y0 = zeros(length(phase.species))
    spnames = [x.name for x in phase.species]
    for (key,val) in initialconds
        if key == "T"
            T = val
        elseif key == "P"
            throw(error("ConstantTVDomain cannot specify P"))
        elseif key == "V"
            V = val
        else
            ind = findfirst(isequal(key),spnames)
            @assert typeof(ind)<: Integer  "$key not found in species list: $spnames"
            y0[ind] = val
        end
    end
    @assert T != 0.0
    @assert V != 0.0
    ns = y0
    N = sum(ns)

    if length(constantspecies) > 0
        spcnames = getfield.(phase.species,:name)
        constspcinds = [findfirst(isequal(k),spcnames) for k in constantspecies]
    else
        constspcinds = Array{Int64,1}()
    end
    efficiencyinds = [rxn.index for rxn in phase.reactions if typeof(rxn.kinetics)<:AbstractFalloffRate && length(rxn.kinetics.efficiencies) > 0]
    Gs = calcgibbs(phase,T)
    if :solvent in fieldnames(typeof(phase)) && typeof(phase.solvent) != EmptySolvent
        mu = phase.solvent.mu(T)
    else
        mu = 0.0
    end
    if phase.diffusionlimited
        diffs = [x(T=T,mu=mu,P=P) for x in getfield.(phase.species,:diffusion)]
    else
        diffs = Array{Float64,1}()
    end
    P = 1.0e8  #essentiallly assuming this is a liquid
    C = N/V
    kfs,krevs = getkfkrevs(phase=phase,T=T,P=P,C=C,N=N,ns=ns,Gs=Gs,diffs=diffs,V=V)
    kfsnondiff = getkfs(phase,T,P,C,ns,V)
    p = vcat(Gs,kfsnondiff)
    if sparse
        jacobian=zeros(typeof(T),length(phase.species),length(phase.species))
    else
        jacobian=zeros(typeof(T),length(phase.species),length(phase.species))
    end
    rxnarray = getreactionindices(phase)
    return ConstantTVDomain(phase,[phase.species[1].index,phase.species[end].index],[1,length(phase.species)+length(phase.reactions)],constspcinds,
        T,V,kfs,krevs,kfsnondiff,efficiencyinds,Gs,rxnarray,mu,diffs,jacobian,sensitivity,MVector(false),MVector(0.0),p), y0, p
end
export ConstantTVDomain

@with_kw struct ParametrizedTConstantVDomain{N<:AbstractPhase,S<:Integer,W<:Real,W2<:Real,I<:Integer,Q<:AbstractArray} <: AbstractVariableKDomain
    phase::N
    indexes::Q #assumed to be in ascending order
    parameterindexes::Q
    constantspeciesinds::Array{S,1}
    T::Function
    V::W
    efficiencyinds::Array{I,1}
    rxnarray::Array{Int64,2}
    jacobian::Array{W,2}
    sensitivity::Bool = false
    jacuptodate::MArray{Tuple{1},Bool,1,1}=MVector(false)
    t::MArray{Tuple{1},W2,1,1}=MVector(0.0)
    p::Array{W,1}
end
function ParametrizedTConstantVDomain(;phase::IdealDiluteSolution,initialconds::Dict{X,X3},constantspecies::Array{X2,1}=Array{String,1}(),
    sparse::Bool=false,sensitivity::Bool=false) where {X,X2,X3,Q<:AbstractInterface}
    #set conditions and initialconditions
    T = 0.0
    P = 1.0e8 #essentiallly assuming this is a liquid
    V = 0.0
    ts = Array{Float64,1}()
    ns = zeros(length(phase.species))
    spnames = [x.name for x in phase.species]
    @assert "V" in keys(initialconds)
    for (key,val) in initialconds
        if key == "T"
            T = val
        elseif key == "P"
            throw(error("ParametrizedTConstantVDomain cannot specify P"))
        elseif key == "V"
            V = val
        elseif key == "ts"
            ts = val
        else
            ind = findfirst(isequal(key),spnames)
            @assert typeof(ind)<: Integer  "$key not found in species list: $spnames"
            ns[ind] = val
        end
    end
    if isa(T,AbstractArray)
        Tfcn = getspline(ts,T)
    elseif isa(T,Function)
        Tfcn = T
    else
        throw(error("ParametrizedTConstantVDomain must take \"T\" as a function or if an array of times for \"ts\" is supplied as an array of volumes"))
    end
    N = sum(ns)
    y0 = zeros(length(phase.species))
    y0[phase.species[1].index:phase.species[end].index] = ns
    p = vcat(zeros(length(phase.species)),ones(length(phase.reactions)))
    if length(constantspecies) > 0
        spcnames = getfield.(phase.species,:name)
        constspcinds = [findfirst(isequal(k),spcnames) for k in constantspecies]
    else
        constspcinds = Array{Int64,1}()
    end
    efficiencyinds = [rxn.index for rxn in phase.reactions if typeof(rxn.kinetics)<:AbstractFalloffRate && length(rxn.kinetics.efficiencies) > 0]
    if sparse
        jacobian=zeros(typeof(V),length(phase.species)+1,length(phase.species)+1)
    else
        jacobian=zeros(typeof(V),length(phase.species)+1,length(phase.species)+1)
    end
    rxnarray = getreactionindices(phase)
    return ParametrizedTConstantVDomain(phase,[phase.species[1].index,phase.species[end].index],[1,length(phase.species)+length(phase.reactions)],constspcinds,
    Tfcn,V,efficiencyinds,rxnarray,jacobian,sensitivity,MVector(false),MVector(0.0),p), y0, p
end
export ParametrizedTConstantVDomain

@with_kw struct ConstantTADomain{N<:AbstractPhase,S<:Integer,W<:Real, W2<:Real, I<:Integer, Q<:AbstractArray} <: AbstractConstantKDomain
    phase::N
    indexes::Q #assumed to be in ascending order
    parameterindexes::Q
    constantspeciesinds::Array{S,1}
    T::W
    A::W
    kfs::Array{W,1}
    krevs::Array{W,1}
    efficiencyinds::Array{I,1}
    Gs::Array{W,1}
    rxnarray::Array{UInt16,2}
    mu::W = 0.0
    diffusivity::Array{W,1} = Array{Float64,1}()
    jacobian::Array{W,2} = Array{Float64,2}(undef,(0,0))
    sensitivity::Bool = false
    jacuptodate::MArray{Tuple{1},Bool,1,1}=MVector(false)
    t::MArray{Tuple{1},W2,1,1}=MVector(0.0)
    p::Array{W,1}
end
function ConstantTADomain(;phase::E2,initialconds::Dict{X,X2},constantspecies::Array{X3,1}=Array{String,1}(),
    sparse::Bool=false,sensitivity::Bool=false,stationary::Bool=false) where {E<:Real,E2<:AbstractPhase,W<:Real,X,X2,X3}
    #set conditions and initialconditions
    T = 0.0
    A = 0.0
    y0 = zeros(length(phase.species))
    spnames = [x.name for x in phase.species]
    for (key,val) in initialconds
        if key == "T"
            T = val
        elseif key == "A"
            A = val
        else
            ind = findfirst(isequal(key),spnames)
            @assert typeof(ind)<: Integer  "$key not found in species list: $spnames"
            y0[ind] = val
        end
    end

    @assert A != 0.0
    @assert T != 0.0
    ns = y0
    N = sum(ns)

    if length(constantspecies) > 0
        spcnames = getfield.(phase.species,:name)
        constspcinds = [findfirst(isequal(k),spcnames) for k in constantspecies]
    else
        constspcinds = Array{Int64,1}()
    end
    efficiencyinds = [rxn.index for rxn in phase.reactions if typeof(rxn.kinetics)<:AbstractFalloffRate && length(rxn.kinetics.efficiencies) > 0]
    Gs = calcgibbs(phase,T)
    if :solvent in fieldnames(typeof(phase)) && typeof(phase.solvent) != EmptySolvent
        mu = phase.solvent.mu(T)
    else
        mu = 0.0
    end
    C = phase.sitedensity
    kfs,krevs = getkfkrevs(phase=phase,T=T,P=0.0,C=C,N=N,ns=ns,Gs=Gs,diffs=[],V=A)
    p = vcat(Gs,kfs)
    if sparse
        jacobian=spzeros(typeof(T),length(phase.species),length(phase.species))
    else
        jacobian=zeros(typeof(T),length(phase.species),length(phase.species))
    end
    rxnarray = getreactionindices(phase)
    return ConstantTADomain(phase,[phase.species[1].index,phase.species[end].index],[1,length(phase.species)+length(phase.reactions)],constspcinds,
        T,A,kfs,krevs,efficiencyinds,Gs,rxnarray,mu,jacobian,sensitivity,MVector(false),MVector(0.0),stationary), y0, p
end
export ConstantTADomain

@inline function calcthermo(d::ConstantTPDomain{W,Y},y::J,t::Q,p::W3=DiffEqBase.NullParameters()) where {W3<:DiffEqBase.NullParameters,W<:IdealGas,Y<:Integer,J<:Array{Float64,1},Q} #no parameter input
    if t != d.t[1]
        d.t[1] = t
        d.jacuptodate[1] = false
    end
    ns = y[d.indexes[1]:d.indexes[2]]
    V = y[d.indexes[3]]
    N = d.P*V/(R*d.T)
    cs = ns./V
    C = N/V
    for ind in d.efficiencyinds #efficiency related rates may have changed
        d.kfs[ind],d.krevs[ind] = getkfkrev(d.phase.reactions[ind],d.phase,d.T,d.P,C,N,ns,d.Gs,d.diffusivity,V)
    end
    return ns,cs,d.T,d.P,V,C,N,d.mu,d.kfs,d.krevs,Array{Float64,1}(),Array{Float64,1}(),Array{Float64,1}(),Array{Float64,1}(),0.0,Array{Float64,1}()
end

@inline function calcthermo(d::ConstantTPDomain{W,Y},y::J,t::Q,p::W2=DiffEqBase.NullParameters()) where {W2<:Array{Float64,1},W<:IdealGas,Y<:Integer,J<:Array{Float64,1},Q<:Float64} #uses parameter input
    if t != d.t[1]
        d.t[1] = t
        d.jacuptodate[1] = false
    end
    ns = y[d.indexes[1]:d.indexes[2]]
    V = y[d.indexes[3]]
    N = d.P*V/(R*d.T)
    cs = ns./V
    C = N/V
    @views kfps = p[d.parameterindexes[1]-1+length(d.phase.species)+1:d.parameterindexes[1]-1+length(d.phase.species)+length(d.phase.reactions)]
    @views nothermochg= d.Gs == p[d.parameterindexes[1]-1+1:d.parameterindexes[1]-1+length(d.phase.species)]
    @views nokfchg = count(d.kfs .!= kfps) <= length(d.efficiencyinds) && all(kfps[d.efficiencyinds] .== 1.0)
    if nothermochg && nokfchg
        for ind in d.efficiencyinds #efficiency related rates may have changed
            d.kfs[ind],d.krevs[ind] = getkfkrev(d.phase.reactions[ind],d.phase,d.T,d.P,C,N,ns,d.Gs,d.diffusivity,V;f=kfps[ind])
        end
        return ns,cs,d.T,d.P,V,C,N,d.mu,d.kfs,d.krevs,Array{Float64,1}(),Array{Float64,1}(),Array{Float64,1}(),Array{Float64,1}(),0.0,Array{Float64,1}()
    elseif nothermochg
        d.kfs = kfps
        for ind in d.efficiencyinds #efficiency related rates may have changed
            d.kfs[ind],d.krevs[ind] = getkfkrev(d.phase.reactions[ind],d.phase,d.T,d.P,C,N,ns,d.Gs,d.diffusivity,V;f=kfps[ind]) 
        end
        return ns,cs,d.T,d.P,V,C,N,d.mu,d.kfs,d.krevs,Array{Float64,1}(),Array{Float64,1}(),Array{Float64,1}(),Array{Float64,1}(),0.0,Array{Float64,1}()
    else #need to handle thermo changes
        d.kfs = p[d.parameterindexes[1]-1+length(d.phase.species)+1:d.parameterindexes[1]-1+length(d.phase.species)+length(d.phase.reactions)]
        d.Gs = p[d.parameterindexes[1]-1+1:d.parameterindexes[1]-1+length(d.phase.species)]
        krevs = getkfkrevs(;phase=d.phase,T=d.T,P=d.P,C=C,N=N,ns=ns,Gs=d.Gs,diffs=d.diffusivity,V=V,kfs=d.kfs)[2]
        for ind in d.efficiencyinds #efficiency related rates may have changed
            d.kfs[ind],d.krevs[ind] = getkfkrev(d.phase.reactions[ind],d.phase,d.T,d.P,C,N,ns,d.Gs,d.diffusivity,V;f=kfps[ind])
        end
        return ns,cs,d.T,d.P,V,C,N,d.mu,d.kfs,d.krevs,Array{Float64,1}(),Array{Float64,1}(),Array{Float64,1}(),Array{Float64,1}(),0.0,Array{Float64,1}()
    end
end

@inline function calcthermo(d::ConstantTPDomain{W,Y},y::Array{W3,1},t::Q,p::W2=DiffEqBase.NullParameters()) where {W2,W<:IdealGas,Y<:Integer,W3<:ForwardDiff.Dual,Q} #Autodiff y
    if t != d.t[1]
        d.t[1] = t
        d.jacuptodate[1] = false
    end
    ns = y[d.indexes[1]:d.indexes[2]]
    V = y[d.indexes[3]]
    N = d.P*V/(R*d.T)
    cs = ns./V
    C = N/V
    kfs = convert(typeof(y),p[d.parameterindexes[1]-1+length(d.phase.species)+1:d.parameterindexes[1]-1+length(d.phase.species)+length(d.phase.reactions)])
    Gs = p[d.parameterindexes[1]-1+1:d.parameterindexes[1]-1+length(d.phase.species)]
    krevs = convert(typeof(y),getkfkrevs(;phase=d.phase,T=d.T,P=d.P,C=C,N=N,ns=ns,Gs=Gs,diffs=d.diffusivity,V=V,kfs=kfs)[2])
    for ind in d.efficiencyinds #efficiency related rates may have changed
        kfs[ind],krevs[ind] = getkfkrev(d.phase.reactions[ind],d.phase,d.T,d.P,C,N,ns,Gs,d.diffusivity,V;f=kfs[ind])
    end
    return ns,cs,d.T,d.P,V,C,N,d.mu,kfs,krevs,Array{Float64,1}(),Array{Float64,1}(),Array{Float64,1}(),Array{Float64,1}(),0.0,Array{Float64,1}()
end

@inline function calcthermo(d::ConstantTPDomain{W,Y},y::J,t::Q,p::W2=DiffEqBase.NullParameters()) where {W2,W<:IdealGas,Y<:Integer,J,Q} #Autodiff p
    if t != d.t[1]
        d.t[1] = t
        d.jacuptodate[1] = false
    end
    ns = y[d.indexes[1]:d.indexes[2]]
    V = y[d.indexes[3]]
    N = d.P*V/(R*d.T)
    cs = ns./V
    C = N/V
    kfs = p[d.parameterindexes[1]-1+length(d.phase.species)+1:d.parameterindexes[1]-1+length(d.phase.species)+length(d.phase.reactions)]
    Gs = p[d.parameterindexes[1]-1+1:d.parameterindexes[1]-1+length(d.phase.species)]
    krevs = getkfkrevs(;phase=d.phase,T=d.T,P=d.P,C=C,N=N,ns=ns,Gs=Gs,diffs=d.diffusivity,V=V,kfs=kfs)[2]
    for ind in d.efficiencyinds #efficiency related rates may have changed
        kfs[ind],krevs[ind] = getkfkrev(d.phase.reactions[ind],d.phase,d.T,d.P,C,N,ns,Gs,d.diffusivity,V;f=kfs[ind])
    end
    return ns,cs,d.T,d.P,V,C,N,d.mu,kfs,krevs,Array{Float64,1}(),Array{Float64,1}(),Array{Float64,1}(),Array{Float64,1}(),0.0,Array{Float64,1}()
end

@inline function calcthermo(d::ConstantTPDomain{W,Y},y::J,t::Q,p::W2=DiffEqBase.NullParameters()) where {W2<:Union{ReverseDiff.TrackedArray,Tracker.TrackedArray},W<:IdealGas,Y<:Integer,J,Q} #Tracker/reversediff
    if t != d.t[1]
        d.t[1] = t
        d.jacuptodate[1] = false
    end
    ns = y[d.indexes[1]:d.indexes[2]]
    V = y[d.indexes[3]]
    N = d.P*V/(R*d.T)
    cs = ns./V
    C = N/V
    Gs = p[d.parameterindexes[1]-1+1:d.parameterindexes[1]-1+length(d.phase.species)]
    kfs = [ind in d.efficiencyinds ? getkfkrev(d.phase.reactions[ind],d.phase,d.T,d.P,C,N,ns,Gs,d.diffusivity,V)[1]*p[d.parameterindexes[1]-1+length(d.phase.species)+ind] : p[d.parameterindexes[1]-1+length(d.phase.species)+ind] for ind in 1:length(d.phase.reactions)]
    krevs = getkfkrevs(;phase=d.phase,T=d.T,P=d.P,C=C,N=N,ns=ns,Gs=Gs,diffs=d.diffusivity,V=V,kfs=kfs)[2]
    return ns,cs,d.T,d.P,V,C,N,d.mu,kfs,krevs,Array{Float64,1}(),Array{Float64,1}(),Array{Float64,1}(),Array{Float64,1}(),0.0,Array{Float64,1}()
end

@inline function calcthermo(d::ConstantVDomain{W,Y},y::J,t::Q,p::W2=DiffEqBase.NullParameters()) where {W2<:DiffEqBase.NullParameters,W<:IdealGas,Y<:Integer,J<:AbstractArray,Q<:Real}
    if t != d.t[1]
        d.t[1] = t
        d.jacuptodate[1] = false
    end
    ns = y[d.indexes[1]:d.indexes[2]]
    T = y[d.indexes[3]]
    P = y[d.indexes[4]]
    N = P*d.V/(R*T)
    cs = ns./d.V
    C = N/d.V
    Gs = zeros(length(d.phase.species))
    Us = zeros(length(d.phase.species))
    Cvave = 0.0
    cpdivR,hdivRT,sdivR = calcHSCpdless(d.phase.vecthermo,T)
    @fastmath Gs = (hdivRT.-sdivR)*(R*T)
    @fastmath Us = (hdivRT.-1.0)*(R*T)
    @fastmath Cvave = dot(cpdivR,ns)
    @fastmath Cvave *= R/N
    @fastmath Cvave -= R
    if d.phase.diffusionlimited
        diffs = getfield.(d.phase.species,:diffusion)(T=T,mu=0.0,P=P)::Array{typeof(T),1}
    else
        diffs = Array{Float64,1}()
    end
    kfs,krevs = getkfkrevs(phase=d.phase,T=T,P=P,C=C,N=N,ns=ns,Gs=Gs,diffs=diffs,V=d.V)
    return ns,cs,T,P,d.V,C,N,0.0,kfs,krevs,Array{Float64,1}(),Us,Gs,diffs,Cvave,cpdivR
end

@inline function calcthermo(d::ConstantVDomain{W,Y},y::J,t::Q,p::W2=DiffEqBase.NullParameters()) where {W2<:Array{Float64,1},W<:IdealGas,Y<:Integer,J<:AbstractArray,Q<:Real}
    if t != d.t[1]
        d.t[1] = t
        d.jacuptodate[1] = false
    end
    ns = y[d.indexes[1]:d.indexes[2]]
    T = y[d.indexes[3]]
    P = y[d.indexes[4]]
    N = P*d.V/(R*T)
    cs = ns./d.V
    C = N/d.V
    Gs = zeros(length(d.phase.species))
    Us = zeros(length(d.phase.species))
    Cvave = 0.0
    cpdivR,hdivRT,sdivR = calcHSCpdless(d.phase.vecthermo,T)
    @views @fastmath hdivRT .+= p[d.parameterindexes[1]-1+1:d.parameterindexes[1]-1+length(d.phase.species)]./(R*T)
    @fastmath Gs = (hdivRT.-sdivR)*(R*T)
    @fastmath Us = (hdivRT.-1.0)*(R*T)
    @fastmath Cvave = dot(cpdivR,ns)
    @fastmath Cvave *= R/N
    @fastmath Cvave -= R
    if d.phase.diffusionlimited
        diffs = getfield.(d.phase.species,:diffusion)(T=T,mu=0.0,P=P)::Array{typeof(T),1}
    else
        diffs = Array{Float64,1}()
    end
    kfs,krevs = getkfkrevs(phase=d.phase,T=T,P=P,C=C,N=N,ns=ns,Gs=Gs,diffs=diffs,V=d.V)
    return @views @fastmath ns,cs,T,P,d.V,C,N,0.0,kfs.*p[d.parameterindexes[1]-1+length(d.phase.species)+1:d.parameterindexes[1]-1+length(d.phase.species)+length(kfs)],krevs.*p[d.parameterindexes[1]-1+length(d.phase.species)+1:d.parameterindexes[1]-1+length(d.phase.species)+length(kfs)],Array{Float64,1}(),Us,Gs,diffs,Cvave,cpdivR
end

@inline function calcthermo(d::ConstantVDomain{W,Y},y::J,t::Q,p::W2=DiffEqBase.NullParameters()) where {W2,W<:IdealGas,Y<:Integer,J<:AbstractArray,Q<:Real}
    if t != d.t[1]
        d.t[1] = t
        d.jacuptodate[1] = false
    end
    ns = y[d.indexes[1]:d.indexes[2]]
    T = y[d.indexes[3]]
    P = y[d.indexes[4]]
    N = P*d.V/(R*T)
    cs = ns./d.V
    C = N/d.V
    Gs = zeros(length(d.phase.species))
    Us = zeros(length(d.phase.species))
    Cvave = 0.0
    cpdivR,hdivRT1,sdivR = calcHSCpdless(d.phase.vecthermo,T)
    @fastmath @views hdivRT = hdivRT1 .+ p[d.parameterindexes[1]-1+1:d.parameterindexes[1]-1+length(d.phase.species)]./(R*T)
    @fastmath Gs = (hdivRT.-sdivR)*(R*T)
    @fastmath Us = (hdivRT.-1.0)*(R*T)
    @fastmath Cvave = dot(cpdivR,ns)
    @fastmath Cvave *= R/N
    @fastmath Cvave -= R
    if d.phase.diffusionlimited
        diffs = getfield.(d.phase.species,:diffusion)(T=T,mu=0.0,P=P)::Array{typeof(T),1}
    else
        diffs = Array{Float64,1}()
    end
    kfs,krevs = getkfkrevs(phase=d.phase,T=T,P=P,C=C,N=N,ns=ns,Gs=Gs,diffs=diffs,V=d.V)
    return @views @fastmath ns,cs,T,P,d.V,C,N,0.0,kfs.*p[d.parameterindexes[1]-1+length(d.phase.species)+1:d.parameterindexes[1]-1+length(d.phase.species)+length(kfs)],krevs.*p[d.parameterindexes[1]-1+length(d.phase.species)+1:d.parameterindexes[1]-1+length(d.phase.species)+length(kfs)],Array{Float64,1}(),Us,Gs,diffs,Cvave,cpdivR
end

@inline function calcthermo(d::ConstantPDomain{W,Y},y::J,t::Q,p::W2=DiffEqBase.NullParameters()) where {W2<:DiffEqBase.NullParameters,W<:IdealGas,Y<:Integer,J<:AbstractArray,Q<:Real}
    if t != d.t[1]
        d.t[1] = t
        d.jacuptodate[1] = false
    end
    ns = y[d.indexes[1]:d.indexes[2]]
    T = y[d.indexes[3]]
    V = y[d.indexes[4]]
    N = d.P*V/(R*T)
    cs = ns./V
    C = N/V
    Gs = zeros(length(d.phase.species))
    Hs = zeros(length(d.phase.species))
    cpdivR,hdivRT,sdivR = calcHSCpdless(d.phase.vecthermo,T)
    @fastmath Gs = (hdivRT.-sdivR)*(R*T)
    @fastmath Hs = hdivRT.*(R*T)
    @fastmath Cvave = dot(cpdivR,ns)
    @fastmath Cvave *= R/N
    @fastmath Cvave -= R
    if d.phase.diffusionlimited
        diffs = getfield.(d.phase.species,:diffusion)(T=T,mu=0.0,P=d.P)::Array{typeof(T),1}
    else
        diffs = Array{Float64,1}()
    end
    kfs,krevs = getkfkrevs(phase=d.phase,T=T,P=d.P,C=C,N=N,ns=ns,Gs=Gs,diffs=diffs,V=V)
    return ns,cs,T,d.P,V,C,N,0.0,kfs,krevs,Hs,Array{Float64,1}(),Gs,diffs,Cvave,cpdivR
end

@inline function calcthermo(d::ConstantPDomain{W,Y},y::J,t::Q,p::W2=DiffEqBase.NullParameters()) where {W2<:Array{Float64,1},W<:IdealGas,Y<:Integer,J<:AbstractArray,Q<:Real}
    if t != d.t[1]
        d.t[1] = t
        d.jacuptodate[1] = false
    end
    ns = y[d.indexes[1]:d.indexes[2]]
    T = y[d.indexes[3]]
    V = y[d.indexes[4]]
    N = d.P*V/(R*T)
    cs = ns./V
    C = N/V
    Gs = zeros(length(d.phase.species))
    Hs = zeros(length(d.phase.species))
    cpdivR,hdivRT,sdivR = calcHSCpdless(d.phase.vecthermo,T)
    @fastmath @views hdivRT .+= p[d.parameterindexes[1]-1+1:d.parameterindexes[1]-1+length(d.phase.species)]./(R*T)
    @fastmath Gs = (hdivRT.-sdivR)*(R*T)
    @fastmath Hs = hdivRT.*(R*T)
    @fastmath Cvave = dot(cpdivR,ns)
    @fastmath Cvave *= R/N
    @fastmath Cvave -= R
    if d.phase.diffusionlimited
        diffs = getfield.(d.phase.species,:diffusion)(T=T,mu=0.0,P=d.P)::Array{typeof(T),1}
    else
        diffs = Array{Float64,1}()
    end
    kfs,krevs = getkfkrevs(phase=d.phase,T=T,P=d.P,C=C,N=N,ns=ns,Gs=Gs,diffs=diffs,V=V)
    if p != DiffEqBase.NullParameters()
        return @views @fastmath ns,cs,T,d.P,V,C,N,0.0,kfs.*p[d.parameterindexes[1]-1+length(d.phase.species)+1:d.parameterindexes[1]-1+length(d.phase.species)+length(kfs)],krevs.*p[d.parameterindexes[1]-1+length(d.phase.species)+1:d.parameterindexes[1]-1+length(d.phase.species)+length(kfs)],Hs,Array{Float64,1}(),Gs,diffs,Cvave,cpdivR
    else
        return ns,cs,T,d.P,V,C,N,0.0,kfs,krevs,Hs,Array{Float64,1}(),Gs,diffs,Cvave,cpdivR
    end
end

@inline function calcthermo(d::ConstantPDomain{W,Y},y::J,t::Q,p::W2=DiffEqBase.NullParameters()) where {W2,W<:IdealGas,Y<:Integer,J<:AbstractArray,Q<:Real}
    if t != d.t[1]
        d.t[1] = t
        d.jacuptodate[1] = false
    end
    ns = y[d.indexes[1]:d.indexes[2]]
    T = y[d.indexes[3]]
    V = y[d.indexes[4]]
    N = d.P*V/(R*T)
    cs = ns./V
    C = N/V
    Gs = zeros(length(d.phase.species))
    Hs = zeros(length(d.phase.species))
    cpdivR,hdivRT1,sdivR = calcHSCpdless(d.phase.vecthermo,T)
    @fastmath @views hdivRT = hdivRT1 .+ p[d.parameterindexes[1]-1+1:d.parameterindexes[1]-1+length(d.phase.species)]./(R*T)
    @fastmath Gs = (hdivRT.-sdivR)*(R*T)
    @fastmath Hs = hdivRT.*(R*T)
    @fastmath Cvave = dot(cpdivR,ns)
    @fastmath Cvave *= R/N
    @fastmath Cvave -= R
    if d.phase.diffusionlimited
        diffs = getfield.(d.phase.species,:diffusion)(T=T,mu=0.0,P=d.P)::Array{typeof(T),1}
    else
        diffs = Array{Float64,1}()
    end
    kfs,krevs = getkfkrevs(phase=d.phase,T=T,P=d.P,C=C,N=N,ns=ns,Gs=Gs,diffs=diffs,V=V)
    return @views @fastmath ns,cs,T,d.P,V,C,N,0.0,kfs.*p[d.parameterindexes[1]-1+length(d.phase.species)+1:d.parameterindexes[1]-1+length(d.phase.species)+length(kfs)],krevs.*p[d.parameterindexes[1]-1+length(d.phase.species)+1:d.parameterindexes[1]-1+length(d.phase.species)+length(kfs)],Hs,Array{Float64,1}(),Gs,diffs,Cvave,cpdivR
end

@inline function calcthermo(d::ParametrizedVDomain{W,Y},y::J,t::Q,p::W2=DiffEqBase.NullParameters()) where {W2<:DiffEqBase.NullParameters,W<:IdealGas,Y<:Integer,J<:AbstractArray,Q<:Real}
    if t != d.t[1]
        d.t[1] = t
        d.jacuptodate[1] = false
    end
    V = d.V(t)
    ns = y[d.indexes[1]:d.indexes[2]]
    T = y[d.indexes[3]]
    P = y[d.indexes[4]]
    N = P*V/(R*T)
    cs = ns./V
    C = N/V
    Gs = zeros(length(d.phase.species))
    Us = zeros(length(d.phase.species))
    cpdivR,hdivRT,sdivR = calcHSCpdless(d.phase.vecthermo,T)
    @fastmath Gs = (hdivRT.-sdivR)*(R*T)
    @fastmath Us = (hdivRT.-1.0)*(R*T)
    @fastmath Cvave = dot(cpdivR,ns)
    @fastmath Cvave *= R/N
    @fastmath Cvave -= R
    if d.phase.diffusionlimited
        diffs = getfield.(d.phase.species,:diffusion)(T=T,mu=0.0,P=P)::Array{typeof(T),1}
    else
        diffs = Array{Float64,1}()
    end
    kfs,krevs = getkfkrevs(phase=d.phase,T=T,P=P,C=C,N=N,ns=ns,Gs=Gs,diffs=diffs,V=V)
    return ns,cs,T,P,V,C,N,0.0,kfs,krevs,Array{Float64,1}(),Us,Gs,diffs,Cvave,cpdivR
end

@inline function calcthermo(d::ParametrizedVDomain{W,Y},y::J,t::Q,p::W2=DiffEqBase.NullParameters()) where {W2<:Array{Float64,1},W<:IdealGas,Y<:Integer,J<:AbstractArray,Q<:Real}
    if t != d.t[1]
        d.t[1] = t
        d.jacuptodate[1] = false
    end
    V = d.V(t)
    ns = y[d.indexes[1]:d.indexes[2]]
    T = y[d.indexes[3]]
    P = y[d.indexes[4]]
    N = P*V/(R*T)
    cs = ns./V
    C = N/V
    Gs = zeros(length(d.phase.species))
    Us = zeros(length(d.phase.species))
    cpdivR,hdivRT,sdivR = calcHSCpdless(d.phase.vecthermo,T)
    @fastmath @views hdivRT .+= p[d.parameterindexes[1]-1+1:d.parameterindexes[1]-1+length(d.phase.species)]./(R*T)
    @fastmath Gs = (hdivRT.-sdivR)*(R*T)
    @fastmath Us = (hdivRT.-1.0)*(R*T)
    @fastmath Cvave = dot(cpdivR,ns)
    @fastmath Cvave *= R/N
    @fastmath Cvave -= R
    if d.phase.diffusionlimited
        diffs = getfield.(d.phase.species,:diffusion)(T=T,mu=0.0,P=P)::Array{typeof(T),1}
    else
        diffs = Array{Float64,1}()
    end
    kfs,krevs = getkfkrevs(phase=d.phase,T=T,P=P,C=C,N=N,ns=ns,Gs=Gs,diffs=diffs,V=V)
    return @views @fastmath ns,cs,T,P,V,C,N,0.0,kfs.*p[d.parameterindexes[1]-1+length(d.phase.species)+1:d.parameterindexes[1]-1+length(d.phase.species)+length(kfs)],krevs.*p[d.parameterindexes[1]-1+length(d.phase.species)+1:d.parameterindexes[1]-1+length(d.phase.species)+length(kfs)],Array{Float64,1}(),Us,Gs,diffs,Cvave,cpdivR
end

@inline function calcthermo(d::ParametrizedVDomain{W,Y},y::J,t::Q,p::W2=DiffEqBase.NullParameters()) where {W2,W<:IdealGas,Y<:Integer,J<:AbstractArray,Q<:Real}
    if t != d.t[1]
        d.t[1] = t
        d.jacuptodate[1] = false
    end
    V = d.V(t)
    ns = y[d.indexes[1]:d.indexes[2]]
    T = y[d.indexes[3]]
    P = y[d.indexes[4]]
    N = P*V/(R*T)
    cs = ns./V
    C = N/V
    Gs = zeros(length(d.phase.species))
    Us = zeros(length(d.phase.species))
    cpdivR,hdivRT1,sdivR = calcHSCpdless(d.phase.vecthermo,T)
    @fastmath @views hdivRT = hdivRT1 .+ p[d.parameterindexes[1]-1+1:d.parameterindexes[1]-1+length(d.phase.species)]./(R*T)
    @fastmath Gs = (hdivRT.-sdivR)*(R*T)
    @fastmath Us = (hdivRT.-1.0)*(R*T)
    @fastmath Cvave = dot(cpdivR,ns)
    @fastmath Cvave *= R/N
    @fastmath Cvave -= R
    if d.phase.diffusionlimited
        diffs = getfield.(d.phase.species,:diffusion)(T=T,mu=0.0,P=P)::Array{typeof(T),1}
    else
        diffs = Array{Float64,1}()
    end
    kfs,krevs = getkfkrevs(phase=d.phase,T=T,P=P,C=C,N=N,ns=ns,Gs=Gs,diffs=diffs,V=V)
    return @views @fastmath ns,cs,T,P,V,C,N,0.0,kfs.*p[d.parameterindexes[1]-1+length(d.phase.species)+1:d.parameterindexes[1]-1+length(d.phase.species)+length(kfs)],krevs.*p[d.parameterindexes[1]-1+length(d.phase.species)+1:d.parameterindexes[1]-1+length(d.phase.species)+length(kfs)],Array{Float64,1}(),Us,Gs,diffs,Cvave,cpdivR
end

@inline function calcthermo(d::ParametrizedPDomain{W,Y},y::J,t::Q,p::W2=DiffEqBase.NullParameters()) where {W2<:DiffEqBase.NullParameters,W<:IdealGas,Y<:Integer,J<:AbstractArray,Q<:Real}
    if t != d.t[1]
        d.t[1] = t
        d.jacuptodate[1] = false
    end
    P = d.P(t)
    ns = y[d.indexes[1]:d.indexes[2]]
    T = y[d.indexes[3]]
    V = y[d.indexes[4]]
    N = P*V/(R*T)
    cs = ns./V
    C = N/V
    Gs = zeros(length(d.phase.species))
    Hs = zeros(length(d.phase.species))
    cpdivR,hdivRT,sdivR = calcHSCpdless(d.phase.vecthermo,T)
    @fastmath Gs = (hdivRT.-sdivR)*(R*T)
    @fastmath Hs = hdivRT.*(R*T)
    @fastmath Cvave = dot(cpdivR,ns)
    @fastmath Cvave *= R/N
    @fastmath Cvave -= R
    if d.phase.diffusionlimited
        diffs = getfield.(d.phase.species,:diffusion)(T=T,mu=0.0,P=P)::Array{typeof(T),1}
    else
        diffs = Array{Float64,1}()
    end
    kfs,krevs = getkfkrevs(phase=d.phase,T=T,P=P,C=C,N=N,ns=ns,Gs=Gs,diffs=diffs,V=V)
    return ns,cs,T,P,V,C,N,0.0,kfs,krevs,Hs,Array{Float64,1}(),Gs,diffs,Cvave,cpdivR
end

@inline function calcthermo(d::ParametrizedPDomain{W,Y},y::J,t::Q,p::W2=DiffEqBase.NullParameters()) where {W2<:Array{Float64,1},W<:IdealGas,Y<:Integer,J<:AbstractArray,Q<:Real}
    if t != d.t[1]
        d.t[1] = t
        d.jacuptodate[1] = false
    end
    P = d.P(t)
    ns = y[d.indexes[1]:d.indexes[2]]
    T = y[d.indexes[3]]
    V = y[d.indexes[4]]
    N = P*V/(R*T)
    cs = ns./V
    C = N/V
    Gs = zeros(length(d.phase.species))
    Hs = zeros(length(d.phase.species))
    cpdivR,hdivRT,sdivR = calcHSCpdless(d.phase.vecthermo,T)
    @fastmath @views hdivRT .+= p[d.parameterindexes[1]-1+1:d.parameterindexes[1]-1+length(d.phase.species)]./(R*T)
    @fastmath Gs = (hdivRT.-sdivR)*(R*T)
    @fastmath Hs = hdivRT.*(R*T)
    @fastmath Cvave = dot(cpdivR,ns)
    @fastmath Cvave *= R/N
    @fastmath Cvave -= R
    if d.phase.diffusionlimited
        diffs = getfield.(d.phase.species,:diffusion)(T=T,mu=0.0,P=P)::Array{typeof(T),1}
    else
        diffs = Array{Float64,1}()
    end
    kfs,krevs = getkfkrevs(phase=d.phase,T=T,P=P,C=C,N=N,ns=ns,Gs=Gs,diffs=diffs,V=V)
    return @views @fastmath ns,cs,T,P,V,C,N,0.0,kfs.*p[d.parameterindexes[1]-1+length(d.phase.species)+1:d.parameterindexes[1]-1+length(d.phase.species)+length(kfs)],krevs.*p[d.parameterindexes[1]-1+length(d.phase.species)+1:d.parameterindexes[1]-1+length(d.phase.species)+length(kfs)],Hs,Array{Float64,1}(),Gs,diffs,Cvave,cpdivR
end
@inline function calcthermo(d::ParametrizedPDomain{W,Y},y::J,t::Q,p::W2=DiffEqBase.NullParameters()) where {W2,W<:IdealGas,Y<:Integer,J<:AbstractArray,Q<:Real}
    if t != d.t[1]
        d.t[1] = t
        d.jacuptodate[1] = false
    end
    P = d.P(t)
    ns = y[d.indexes[1]:d.indexes[2]]
    T = y[d.indexes[3]]
    V = y[d.indexes[4]]
    N = P*V/(R*T)
    cs = ns./V
    C = N/V
    Gs = zeros(length(d.phase.species))
    Hs = zeros(length(d.phase.species))
    cpdivR,hdivRT1,sdivR = calcHSCpdless(d.phase.vecthermo,T)
    @fastmath @views hdivRT = hdivRT1 .+ p[d.parameterindexes[1]-1+1:d.parameterindexes[1]-1+length(d.phase.species)]./(R*T)
    @fastmath Gs = (hdivRT.-sdivR)*(R*T)
    @fastmath Hs = hdivRT.*(R*T)
    @fastmath Cvave = dot(cpdivR,ns)
    @fastmath Cvave *= R/N
    @fastmath Cvave -= R
    if d.phase.diffusionlimited
        diffs = getfield.(d.phase.species,:diffusion)(T=T,mu=0.0,P=P)::Array{typeof(T),1}
    else
        diffs = Array{Float64,1}()
    end
    kfs,krevs = getkfkrevs(phase=d.phase,T=T,P=P,C=C,N=N,ns=ns,Gs=Gs,diffs=diffs,V=V)
    return @views @fastmath ns,cs,T,P,V,C,N,0.0,kfs.*p[d.parameterindexes[1]-1+length(d.phase.species)+1:d.parameterindexes[1]-1+length(d.phase.species)+length(kfs)],krevs.*p[d.parameterindexes[1]-1+length(d.phase.species)+1:d.parameterindexes[1]-1+length(d.phase.species)+length(kfs)],Hs,Array{Float64,1}(),Gs,diffs,Cvave,cpdivR
end

@inline function calcthermo(d::ParametrizedTConstantVDomain{W,Y},y::J,t::Q,p::W2=DiffEqBase.NullParameters()) where {W2<:DiffEqBase.NullParameters,W<:IdealDiluteSolution,Y<:Integer,J<:AbstractArray,Q<:Real}
    if t != d.t[1]
        d.t[1] = t
        d.jacuptodate[1] = false
    end
    V = d.V
    T = d.T(t)
    ns = y[d.indexes[1]:d.indexes[2]]
    N = sum(ns)
    cs = ns./V
    C = N/V
    P = 1.0e8 #liquid phase
    Gs = zeros(length(d.phase.species))
    mu = d.phase.solvent.mu(T)
    cpdivR,hdivRT,sdivR = calcHSCpdless(d.phase.vecthermo,T)
    @fastmath Gs = (hdivRT.-sdivR)*(R*T)
    if d.phase.diffusionlimited
        diffs = [x(T=T,mu=mu,P=P) for x in getfield.(d.phase.species,:diffusion)]::Array{typeof(T),1}
    else
        diffs = Array{Float64,1}()
    end
    kfs,krevs = getkfkrevs(phase=d.phase,T=T,P=P,C=C,N=N,ns=ns,Gs=Gs,diffs=diffs,V=V)
    return ns,cs,T,P,V,C,N,mu,kfs,krevs,Array{Float64,1}(),Array{Float64,1}(),Gs,diffs,0.0,Array{Float64,1}()
end

@inline function calcthermo(d::ParametrizedTConstantVDomain{W,Y},y::J,t::Q,p::W2=DiffEqBase.NullParameters()) where {W2<:Array{Float64,1},W<:IdealDiluteSolution,Y<:Integer,J<:AbstractArray,Q<:Real}
    if t != d.t[1]
        d.t[1] = t
        d.jacuptodate[1] = false
    end
    V = d.V
    T = d.T(t)
    ns = y[d.indexes[1]:d.indexes[2]]
    N = sum(ns)
    cs = ns./V
    C = N/V
    P = 1.0e8 #liquid phase
    Gs = zeros(length(d.phase.species))
    mu = d.phase.solvent.mu(T)
    cpdivR,hdivRT,sdivR = calcHSCpdless(d.phase.vecthermo,T)
    @fastmath @views hdivRT .+= p[d.parameterindexes[1]-1+1:d.parameterindexes[1]-1+length(d.phase.species)]./(R*T)
    @fastmath Gs = (hdivRT.-sdivR)*(R*T)
    if d.phase.diffusionlimited
        diffs = [x(T=T,mu=mu,P=P) for x in getfield.(d.phase.species,:diffusion)]::Array{typeof(T),1}
    else
        diffs = Array{Float64,1}()
    end
    kfs,krevs = getkfkrevs(phase=d.phase,T=T,P=P,C=C,N=N,ns=ns,Gs=Gs,diffs=diffs,V=V)
    return @views @fastmath ns,cs,T,P,V,C,N,mu,kfs.*p[d.parameterindexes[1]-1+length(d.phase.species)+1:d.parameterindexes[1]-1+length(d.phase.species)+length(kfs)],krevs.*p[d.parameterindexes[1]-1+length(d.phase.species)+1:d.parameterindexes[1]-1+length(d.phase.species)+length(kfs)],Array{Float64,1}(),Array{Float64,1}(),Gs,diffs,0.0,Array{Float64,1}()
end

@inline function calcthermo(d::ParametrizedTConstantVDomain{W,Y},y::J,t::Q,p::W2=DiffEqBase.NullParameters()) where {W2,W<:IdealDiluteSolution,Y<:Integer,J<:AbstractArray,Q<:Real}
    if t != d.t[1]
        d.t[1] = t
        d.jacuptodate[1] = false
    end
    V = d.V
    T = d.T(t)
    ns = y[d.indexes[1]:d.indexes[2]]
    N = sum(ns)
    cs = ns./V
    C = N/V
    P = 1.0e8 #liquid phase
    Gs = zeros(length(d.phase.species))
    mu = d.phase.solvent.mu(T)
    cpdivR,hdivRT1,sdivR = calcHSCpdless(d.phase.vecthermo,T)
    @fastmath @views hdivRT = hdivRT1 .+ p[d.parameterindexes[1]-1+1:d.parameterindexes[1]-1+length(d.phase.species)]./(R*T)
    @fastmath Gs = (hdivRT.-sdivR)*(R*T)
    if d.phase.diffusionlimited
        diffs = [x(T=T,mu=mu,P=P) for x in getfield.(d.phase.species,:diffusion)]::Array{typeof(T),1}
    else
        diffs = Array{Float64,1}()
    end
    kfs,krevs = getkfkrevs(phase=d.phase,T=T,P=P,C=C,N=N,ns=ns,Gs=Gs,diffs=diffs,V=V)
    return @views @fastmath ns,cs,T,P,V,C,N,mu,kfs.*p[d.parameterindexes[1]-1+length(d.phase.species)+1:d.parameterindexes[1]-1+length(d.phase.species)+length(kfs)],krevs.*p[d.parameterindexes[1]-1+length(d.phase.species)+1:d.parameterindexes[1]-1+length(d.phase.species)+length(kfs)],Array{Float64,1}(),Array{Float64,1}(),Gs,diffs,0.0,Array{Float64,1}()
end

@inline function calcthermo(d::ParametrizedTPDomain{W,Y},y::J,t::Q,p::W2=DiffEqBase.NullParameters()) where {W2<:DiffEqBase.NullParameters,W<:IdealGas,Y<:Integer,J<:AbstractArray,Q<:Real}
    if t != d.t[1]
        d.t[1] = t
        d.jacuptodate[1] = false
    end
    T = d.T(t)
    @assert T < 10000.0
    P = d.P(t)
    ns = y[d.indexes[1]:d.indexes[2]]
    V = y[d.indexes[3]]
    N = P*V/(R*T)
    cs = ns./V
    C = N/V
    Gs = zeros(length(d.phase.species))
    Us = zeros(length(d.phase.species))
    cpdivR,hdivRT,sdivR = calcHSCpdless(d.phase.vecthermo,T)
    @fastmath Gs = (hdivRT.-sdivR)*(R*T)
    @fastmath Cvave = dot(cpdivR,ns)
    @fastmath Cvave *= R/N
    @fastmath Cvave -= R
    if d.phase.diffusionlimited
        diffs = getfield.(d.phase.species,:diffusion)(T=T,mu=0.0,P=P)::Array{typeof(T),1}
    else
        diffs = Array{Float64,1}()
    end
    kfs,krevs = getkfkrevs(phase=d.phase,T=T,P=P,C=C,N=N,ns=ns,Gs=Gs,diffs=diffs,V=V)
    return ns,cs,T,P,V,C,N,0.0,kfs,krevs,Array{Float64,1}(),Array{Float64,1}(),Gs,diffs,0.0,Array{Float64,1}()
end

@inline function calcthermo(d::ParametrizedTPDomain{W,Y},y::J,t::Q,p::W2=DiffEqBase.NullParameters()) where {W2<:Array{Float64,1},W<:IdealGas,Y<:Integer,J<:AbstractArray,Q<:Real}
    if t != d.t[1]
        d.t[1] = t
        d.jacuptodate[1] = false
    end
    T = d.T(t)
    @assert T < 10000.0
    P = d.P(t)
    ns = y[d.indexes[1]:d.indexes[2]]
    V = y[d.indexes[3]]
    N = P*V/(R*T)
    cs = ns./V
    C = N/V
    Gs = zeros(length(d.phase.species))
    Us = zeros(length(d.phase.species))
    cpdivR,hdivRT,sdivR = calcHSCpdless(d.phase.vecthermo,T)
    @fastmath @views hdivRT .+= p[d.parameterindexes[1]-1+1:d.parameterindexes[1]-1+length(d.phase.species)]./(R*T)
    @fastmath Gs = (hdivRT.-sdivR)*(R*T)
    @fastmath Cvave = dot(cpdivR,ns)
    @fastmath Cvave *= R/N
    @fastmath Cvave -= R
    if d.phase.diffusionlimited
        diffs = getfield.(d.phase.species,:diffusion)(T=T,mu=0.0,P=P)::Array{typeof(T),1}
    else
        diffs = Array{Float64,1}()
    end
    kfs,krevs = getkfkrevs(phase=d.phase,T=T,P=P,C=C,N=N,ns=ns,Gs=Gs,diffs=diffs,V=V)
    return @views @fastmath ns,cs,T,P,V,C,N,0.0,kfs.*p[d.parameterindexes[1]-1+length(d.phase.species)+1:d.parameterindexes[1]-1+length(d.phase.species)+length(kfs)],krevs.*p[d.parameterindexes[1]-1+length(d.phase.species)+1:d.parameterindexes[1]-1+length(d.phase.species)+length(kfs)],Array{Float64,1}(),Array{Float64,1}(),Gs,diffs,0.0,Array{Float64,1}()
end

@inline function calcthermo(d::ParametrizedTPDomain{W,Y},y::J,t::Q,p::W2=DiffEqBase.NullParameters()) where {W2,W<:IdealGas,Y<:Integer,J<:AbstractArray,Q<:Real}
    if t != d.t[1]
        d.t[1] = t
        d.jacuptodate[1] = false
    end
    T = d.T(t)
    @assert T < 10000.0
    P = d.P(t)
    ns = y[d.indexes[1]:d.indexes[2]]
    V = y[d.indexes[3]]
    N = P*V/(R*T)
    cs = ns./V
    C = N/V
    Gs = zeros(length(d.phase.species))
    Us = zeros(length(d.phase.species))
    cpdivR,hdivRT1,sdivR = calcHSCpdless(d.phase.vecthermo,T)
    @fastmath @views hdivRT = hdivRT1 .+ p[d.parameterindexes[1]-1+1:d.parameterindexes[1]-1+length(d.phase.species)]./(R*T)
    @fastmath Gs = (hdivRT.-sdivR)*(R*T)
    @fastmath Cvave = dot(cpdivR,ns)
    @fastmath Cvave *= R/N
    @fastmath Cvave -= R
    if d.phase.diffusionlimited
        diffs = getfield.(d.phase.species,:diffusion)(T=T,mu=0.0,P=P)::Array{typeof(T),1}
    else
        diffs = Array{Float64,1}()
    end
    kfs,krevs = getkfkrevs(phase=d.phase,T=T,P=P,C=C,N=N,ns=ns,Gs=Gs,diffs=diffs,V=V)
    return @views @fastmath ns,cs,T,P,V,C,N,0.0,kfs.*p[d.parameterindexes[1]-1+length(d.phase.species)+1:d.parameterindexes[1]-1+length(d.phase.species)+length(kfs)],krevs.*p[d.parameterindexes[1]-1+length(d.phase.species)+1:d.parameterindexes[1]-1+length(d.phase.species)+length(kfs)],Array{Float64,1}(),Array{Float64,1}(),Gs,diffs,0.0,Array{Float64,1}()
end

@inline function calcthermo(d::ConstantTVDomain{W,Y},y::J,t::Q,p::Q2=DiffEqBase.NullParameters()) where {Q2<:DiffEqBase.NullParameters,W<:IdealDiluteSolution,Y<:Integer,J<:AbstractArray,Q<:Real}
    if t != d.t[1]
        d.t[1] = t
        d.jacuptodate[1] = false
    end
    ns = y[d.indexes[1]:d.indexes[2]]
    N = sum(ns)
    cs = ns./d.V
    C = N/d.V
    P = 1.0e8
    return ns,cs,d.T,P,d.V,C,N,d.mu,d.kfs,d.krevs,Array{Float64,1}(),Array{Float64,1}(),Array{Float64,1}(),Array{Float64,1}(),0.0,Array{Float64,1}()
end

@inline function calcthermo(d::ConstantTVDomain{W,Y},y::J,t::Q,p::Q2=DiffEqBase.NullParameters()) where {Q2<:Array{Float64,1},W<:IdealDiluteSolution,Y<:Integer,J<:Array{Float64,1},Q<:Real}
    if t != d.t[1]
        d.t[1] = t
        d.jacuptodate[1] = false
    end
    ns = y[d.indexes[1]:d.indexes[2]]
    N = sum(ns)
    cs = ns./d.V
    C = N/d.V
    P = 1.0e8
    @views nothermochg = d.Gs == p[d.parameterindexes[1]-1+1:d.parameterindexes[1]-1+length(d.phase.species)]
    @views nokfchg = d.kfsnondiff == p[d.parameterindexes[1]-1+length(d.phase.species)+1:d.parameterindexes[1]-1+length(d.phase.species)+length(d.phase.reactions)]
    if nothermochg && nokfchg
        return ns,cs,d.T,P,d.V,C,N,d.mu,d.kfs,d.krevs,Array{Float64,1}(),Array{Float64,1}(),Array{Float64,1}(),Array{Float64,1}(),0.0,Array{Float64,1}()
    elseif nothermochg
        d.kfsnondiff = p[d.parameterindexes[1]-1+length(d.phase.species)+1:d.parameterindexes[1]-1+length(d.phase.species)+length(d.phase.reactions)]
        d.kfs,d.krevs = getkfkrevs(;phase=d.phase,T=d.T,P=P,C=C,N=N,ns=ns,Gs=d.Gs,diffs=d.diffusivity,V=d.V,kfs=d.kfsnondiff)
        return ns,cs,d.T,P,d.V,C,N,d.mu,d.kfs,d.krevs,Array{Float64,1}(),Array{Float64,1}(),Array{Float64,1}(),Array{Float64,1}(),0.0,Array{Float64,1}()
    else
        d.kfsnondiff = p[d.parameterindexes[1]-1+length(d.phase.species)+1:d.parameterindexes[1]-1+length(d.phase.species)+length(d.phase.reactions)]
        d.Gs = p[d.parameterindexes[1]-1+1:d.parameterindexes[1]-1+length(d.phase.species)]
        d.kfs,d.krevs = getkfkrevs(;phase=d.phase,T=d.T,P=P,C=C,N=N,ns=ns,Gs=d.Gs,diffs=d.diffusivity,V=d.V,kfs=d.kfsnondiff)
        return ns,cs,d.T,P,d.V,C,N,d.mu,d.kfs,d.krevs,Array{Float64,1}(),Array{Float64,1}(),Array{Float64,1}(),Array{Float64,1}(),0.0,Array{Float64,1}()
    end
end

@inline function calcthermo(d::ConstantTVDomain{W,Y},y::Array{W2,1},t::Q,p::Q2=DiffEqBase.NullParameters()) where {W2<:ForwardDiff.Dual,Q2,W<:IdealDiluteSolution,Y<:Integer,J<:AbstractArray,Q<:Real} #autodiff y
    if t != d.t[1]
        d.t[1] = t
        d.jacuptodate[1] = false
    end
    ns = y[d.indexes[1]:d.indexes[2]]
    N = sum(ns)
    cs = ns./d.V
    C = N/d.V
    P = 1.0e8
    Gs = p[d.parameterindexes[1]-1+1:d.parameterindexes[1]-1+length(d.phase.species)]
    kfsnondiff = p[d.parameterindexes[1]-1+length(d.phase.species)+1:d.parameterindexes[1]-1+length(d.phase.species)+length(d.phase.reactions)]
    kfs,krevs = getkfkrevs(;phase=d.phase,T=d.T,P=P,C=C,N=N,ns=ns,Gs=Gs,diffs=d.diffusivity,V=d.V,kfs=kfsnondiff)
    kfs = convert(typeof(y),kfs)
    krevs = convert(typeof(y),krevs)
    return ns,cs,d.T,P,d.V,C,N,d.mu,kfs,krevs,Array{Float64,1}(),Array{Float64,1}(),Array{Float64,1}(),Array{Float64,1}(),0.0,Array{Float64,1}()
end

@inline function calcthermo(d::ConstantTVDomain{W,Y},y::J,t::Q,p::Q2=DiffEqBase.NullParameters()) where {Q2,W<:IdealDiluteSolution,Y<:Integer,J<:AbstractArray,Q<:Real} #autodiff p
    if t != d.t[1]
        d.t[1] = t
        d.jacuptodate[1] = false
    end
    ns = y[d.indexes[1]:d.indexes[2]]
    N = sum(ns)
    cs = ns./d.V
    C = N/d.V
    P = 1.0e8
    Gs = p[d.parameterindexes[1]-1+1:d.parameterindexes[1]-1+length(d.phase.species)]
    kfsnondiff = p[d.parameterindexes[1]-1+length(d.phase.species)+1:d.parameterindexes[1]-1+length(d.phase.species)+length(d.phase.reactions)]
    kfs,krevs = getkfkrevs(;phase=d.phase,T=d.T,P=P,C=C,N=N,ns=ns,Gs=Gs,diffs=d.diffusivity,V=d.V,kfs=kfsnondiff)
    return ns,cs,d.T,P,d.V,C,N,d.mu,kfs,krevs,Array{Float64,1}(),Array{Float64,1}(),Array{Float64,1}(),Array{Float64,1}(),0.0,Array{Float64,1}()
end

@inline function calcthermo(d::ConstantTADomain{W,Y},y::J,t::Q,p::Q2=DiffEqBase.NullParameters()) where {Q2<:DiffEqBase.NullParameters,W<:IdealSurface,Y<:Integer,J<:AbstractArray,Q<:Real}
    if t != d.t[1]
        d.t[1] = t
        d.jacuptodate[1] = false
    end
    ns = y[d.indexes[1]:d.indexes[2]]
    N = sum(ns)
    cs = ns./d.A
    C = N/d.A
    P = 0.0
    return ns,cs,d.T,P,d.A,C,N,d.mu,d.kfs,d.krevs,Array{Float64,1}(),Array{Float64,1}(),Array{Float64,1}(),Array{Float64,1}(),0.0,Array{Float64,1}()
end

@inline function calcthermo(d::ConstantTADomain{W,Y},y::J,t::Q,p::Q2=DiffEqBase.NullParameters()) where {Q2<:Array{Float64,1},W<:IdealSurface,Y<:Integer,J<:Array{Float64,1},Q<:Real}
    if t != d.t[1]
        d.t[1] = t
        d.jacuptodate[1] = false
    end
    ns = y[d.indexes[1]:d.indexes[2]]
    N = sum(ns)
    cs = ns./d.A
    C = N/d.A
    P = 0.0
    @views nothermochg = d.Gs == p[d.parameterindexes[1]-1+1:d.parameterindexes[1]-1+length(d.phase.species)]
    if nothermochg
        return ns,cs,d.T,P,d.A,C,N,d.mu,p[d.parameterindexes[1]-1+length(d.phase.species)+1:d.parameterindexes[1]-1+length(d.phase.species)+length(d.phase.reactions)],d.krevs,Array{Float64,1}(),Array{Float64,1}(),Array{Float64,1}(),Array{Float64,1}(),0.0
    else
        d.kfs = p[d.parameterindexes[1]-1+length(d.phase.species)+1:d.parameterindexes[1]-1+length(d.phase.species)+length(d.phase.reactions)]
        d.Gs = p[d.parameterindexes[1]-1+1:d.parameterindexes[1]-1+length(d.phase.species)]
        d.krevs = getkfkrevs(;phase=d.phase,T=d.T,P=P,C=C,N=N,ns=ns,Gs=d.Gs,diffs=d.diffusivity,V=d.V,kfs=d.kfs)[2]
        return ns,cs,d.T,P,d.A,C,N,d.mu,d.kfs,d.krevs,Array{Float64,1}(),Array{Float64,1}(),Array{Float64,1}(),Array{Float64,1}(),0.0,Array{Float64,1}()
    end
end

@inline function calcthermo(d::ConstantTADomain{W,Y},y::Array{W2,1},t::Q,p::Q2=DiffEqBase.NullParameters()) where {W2<:ForwardDiff.Dual,Q2,W<:IdealSurface,Y<:Integer,J<:AbstractArray,Q<:Real} #autodiff y
    if t != d.t[1]
        d.t[1] = t
        d.jacuptodate[1] = false
    end
    ns = y[d.indexes[1]:d.indexes[2]]
    N = sum(ns)
    cs = ns./d.A
    C = N/d.A
    P = 0.0
    Gs = p[d.parameterindexes[1]-1+1:d.parameterindexes[1]-1+length(d.phase.species)]
    kfs = convert(typeof(y),p[d.parameterindexes[1]-1+length(d.phase.species)+1:d.parameterindexes[1]-1+length(d.phase.species)+length(d.phase.reactions)])
    krevs = convert(typeof(y),getkfkrevs(;phase=d.phase,T=d.T,P=P,C=C,N=N,ns=ns,Gs=Gs,diffs=d.diffusivity,V=d.V,kfs=kfs)[2])
    return ns,cs,d.T,P,d.V,C,N,d.mu,kfs,krevs,Array{Float64,1}(),Array{Float64,1}(),Array{Float64,1}(),Array{Float64,1}(),0.0,Array{Float64,1}()
end

@inline function calcthermo(d::ConstantTADomain{W,Y},y::J,t::Q,p::Q2=DiffEqBase.NullParameters()) where {Q2,W<:IdealSurface,Y<:Integer,J<:AbstractArray,Q<:Real} #autodiff p
    if t != d.t[1]
        d.t[1] = t
        d.jacuptodate[1] = false
    end
    ns = y[d.indexes[1]:d.indexes[2]]
    N = sum(ns)
    cs = ns./d.A
    C = N/d.A
    P = 0.0
    Gs = p[d.parameterindexes[1]-1+1:d.parameterindexes[1]-1+length(d.phase.species)]
    kfs = p[d.parameterindexes[1]-1+length(d.phase.species)+1:d.parameterindexes[1]-1+length(d.phase.species)+length(d.phase.reactions)]
    krevs = getkfkrevs(;phase=d.phase,T=d.T,P=P,C=C,N=N,ns=ns,Gs=Gs,diffs=d.diffusivity,V=d.V,kfs=kfs)[2]
    return ns,cs,d.T,P,d.A,C,N,d.mu,kfs,krevs,Array{Float64,1}(),Array{Float64,1}(),Array{Float64,1}(),Array{Float64,1}(),0.0,Array{Float64,1}()
end
export calcthermo

@inline function calcdomainderivatives!(d::Q,dydt::Z7,interfaces::Z12;t::Z10,T::Z4,P::Z9,Us::Array{Z,1},Hs::Array{Z11,1},V::Z2,C::Z3,ns::Z5,N::Z6,Cvave::Z8) where {Q<:AbstractDomain,Z12,Z11,Z10,Z9,Z8<:Real,Z7,W<:IdealGas,Y<:Integer,Z6,Z,Z2,Z3,Z4,Z5}
    for ind in d.constantspeciesinds #make dydt zero for constant species
        @inbounds dydt[ind] = 0.0
    end
    for inter in interfaces
        if isa(inter,Inlet) && d == inter.domain
            dydt[d.indexes[1]:d.indexes[2]] .+= inter.y.*inter.F(t)
        elseif isa(inter,Outlet) && d == inter.domain
            dydt[d.indexes[1]:d.indexes[2]] .-= inter.F(t).*ns./N
        end
    end
end

@inline function calcdomainderivatives!(d::Q,dydt::Z7,interfaces::Z12;t::Z10,T::Z4,P::Z9,Us::Array{Z,1},Hs::Array{Z11,1},V::Z2,C::Z3,ns::Z5,N::Z6,Cvave::Z8) where {Q<:ConstantTPDomain,Z12,Z11,Z10,Z9,Z8<:Real,Z7,W<:IdealGas,Y<:Integer,Z6,Z,Z2,Z3,Z4,Z5}
    @views @fastmath @inbounds dydt[d.indexes[3]] = sum(dydt[d.indexes[1]:d.indexes[2]])*R*T/P
    for ind in d.constantspeciesinds #make dydt zero for constant species
        @inbounds dydt[ind] = 0.0
    end
    for inter in interfaces
        if isa(inter,Inlet) && d == inter.domain
            dydt[d.indexes[1]:d.indexes[2]] .+= inter.y.*inter.F(t)
            dydt[d.indexes[3]] += inter.F(t)*R*T/P
        elseif isa(inter,Outlet) && d == inter.domain
            dydt[d.indexes[1]:d.indexes[2]] .-= inter.F(t).*ns./N
            dydt[d.indexes[3]] -= inter.F(t)*R*T/P
        end
    end
end

@inline function calcdomainderivatives!(d::ConstantVDomain{W,Y},dydt::K,interfaces::Z12;t::Z10,T::Z4,P::Z9,Us::Z,Hs::Z11,V::Z2,C::Z3,ns::Z5,N::Z6,Cvave::Z7) where {Z12,Z11,Z10,Z9,W<:IdealGas,Z7,K,Y<:Integer,Z6,Z,Z2,Z3,Z4,Z5}
    @views @fastmath @inbounds dydt[d.indexes[3]] = -dot(Us,dydt[d.indexes[1]:d.indexes[2]])/(N*Cvave) #divide by V to cancel ωV to ω
    @views @fastmath @inbounds dydt[d.indexes[4]] = sum(dydt[d.indexes[1]:d.indexes[2]])*R*T/V + P/T*dydt[d.indexes[3]]
    for ind in d.constantspeciesinds #make dydt zero for constant species
        @inbounds dydt[ind] = 0.0
    end
    for inter in interfaces
        if isa(inter,Inlet) && d == inter.domain
            flow = inter.F(t)
            dydt[d.indexes[1]:d.indexes[2]] .+= inter.y.*flow
            dTdt = flow*(inter.H - dot(Us,ns)/N)/(N*Cvave)
            dydt[d.indexes[3]] += dTdt
            dydt[d.indexes[4]] += flow*R*T/V + P/T*dTdt
        elseif isa(inter,Outlet) && d == inter.domain
            flow = inter.F(t)
            dydt[d.indexes[1]:d.indexes[2]] .-= flow.*ns./N
            dTdt = (P*V/N*flow)/(N*Cvave)
            dydt[d.indexes[3]] -= dTdt
            dydt[d.indexes[4]] -= flow*R*T/V + P/T*dTdt
        end
    end
end

@inline function calcdomainderivatives!(d::ConstantPDomain{W,Y},dydt::K,interfaces::Z12;t::Z10,T::Z4,P::Z9,Us::Z,Hs::Z11,V::Z2,C::Z3,ns::Z5,N::Z6,Cvave::Z7) where {Z12,Z11,Z10,Z9,W<:IdealGas,Z7,K,Y<:Integer,Z6,Z,Z2,Z3,Z4,Z5}
    @fastmath Cpave = Cvave+R
    @views @fastmath @inbounds dydt[d.indexes[3]] = -dot(Hs,dydt[d.indexes[1]:d.indexes[2]])/(N*Cpave) #divide by V to cancel ωV to ω
    @views @fastmath @inbounds dydt[d.indexes[4]] = sum(dydt[d.indexes[1]:d.indexes[2]])*R*T/P + dydt[d.indexes[3]]*V/T
    for ind in d.constantspeciesinds #make dydt zero for constant species
        @inbounds dydt[ind] = 0.0
    end
    for inter in interfaces
        if isa(inter,Inlet) && d == inter.domain
            flow = inter.F(t)
            dydt[d.indexes[1]:d.indexes[2]] .+= inter.y.*flow
            dTdt = flow*(inter.H - dot(Hs,ns)/N)/(N*Cpave)
            dydt[d.indexes[3]] += dTdt
            dydt[d.indexes[4]] += flow*R*T/P + dTdt*V/T 
        elseif isa(inter,Outlet) && d == inter.domain
            flow = inter.F(t)
            dydt[d.indexes[1]:d.indexes[2]] .-= flow.*ns./N
            dydt[d.indexes[4]] -= flow*R*T/P
        end
    end
end

@inline function calcdomainderivatives!(d::ParametrizedTPDomain{W,Y},dydt::K,interfaces::Z12;t::Z10,T::Z4,P::Z9,Us::Z,Hs::Z11,V::Z2,C::Z3,ns::Z5,N::Z6,Cvave::Z7) where {Z11,Z10,Z9,W<:IdealGas,Z7,K,Y<:Integer,Z6,Z,Z2,Z3,Z4,Z5,Z12}
    @views @fastmath @inbounds dydt[d.indexes[3]] = sum(dydt[d.indexes[1]:d.indexes[2]])*R*T/P + Calculus.derivative(d.T,t)*V/T - Calculus.derivative(d.P,t)*V/P
    for ind in d.constantspeciesinds #make dydt zero for constant species
        @inbounds dydt[ind] = 0.0
    end
    for inter in interfaces
        if isa(inter,Inlet) && d == inter.domain
            flow = inter.F(t)
            dydt[d.indexes[1]:d.indexes[2]] .+= inter.y.*flow
            dydt[d.indexes[3]] += flow*R*T/P
        elseif isa(inter,Outlet) && d == inter.domain
            flow = inter.F(t)
            dydt[d.indexes[1]:d.indexes[2]] .-= flow*ns./N
            dydt[d.indexes[3]] -= flow*R*T/P
        end
    end
end

@inline function calcdomainderivatives!(d::ParametrizedVDomain{W,Y},dydt::K,interfaces::Z12;t::Z10,T::Z4,P::Z9,Us::Z,Hs::Z11,V::Z2,C::Z3,ns::Z5,N::Z6,Cvave::Z7) where {Z11,Z10,Z9,W<:IdealGas,Z7,K,Y<:Integer,Z6,Z,Z2,Z3,Z4,Z5,Z12}
    dVdt = Calculus.derivative(d.V,t)
    @views @fastmath @inbounds dydt[d.indexes[3]] = (-dot(Us,dydt[d.indexes[1]:d.indexes[2]])-P*dVdt)/(N*Cvave) #divide by V to cancel ωV to ω
    @views @fastmath @inbounds dydt[d.indexes[4]] = sum(dydt[d.indexes[1]:d.indexes[2]])*R*T/V + dydt[d.indexes[3]]*P/T - P/V*dVdt
    for ind in d.constantspeciesinds #make dydt zero for constant species
        @inbounds dydt[ind] = 0.0
    end
    for inter in interfaces
        if isa(inter,Inlet) && d == inter.domain
            flow = inter.F(t)
            dydt[d.indexes[1]:d.indexes[2]] .+= inter.y.*flow
            dTdt = flow*(inter.H - dot(Us,ns)/N)/(N*Cvave)
            dydt[d.indexes[3]] += dTdt
            dydt[d.indexes[4]] += flow*R*T/V + dTdt*P/T
        elseif isa(inter,Outlet) && d == inter.domain
            flow = inter.F(t)
            dydt[d.indexes[1]:d.indexes[2]] .-= flow*ns./N
            dTdt = (P*V/N*flow)/(N*Cvave)
            dydt[d.indexes[3]] -= dTdt
            dydt[d.indexes[4]] -= flow*R*T/V + dTdt*P/T
        end
    end
end

@inline function calcdomainderivatives!(d::ParametrizedPDomain{W,Y},dydt::K,interfaces::Z12;t::Z10,T::Z4,P::Z9,Us::Z,Hs::Z11,V::Z2,C::Z3,ns::Z5,N::Z6,Cvave::Z7) where {Z11,Z10,Z9,W<:IdealGas,Z7,K,Y<:Integer,Z6,Z,Z2,Z3,Z4,Z5,Z12}
    @fastmath Cpave = Cvave+R
    dPdt = Calculus.derivative(d.P,t)
    @views @fastmath @inbounds dydt[d.indexes[3]] = (-dot(Hs,dydt[d.indexes[1]:d.indexes[2]])+V*dPdt)/(N*Cpave) #divide by V to cancel ωV to ω
    @views @fastmath @inbounds dydt[d.indexes[4]] = sum(dydt[d.indexes[1]:d.indexes[2]])*R*T/P + dydt[d.indexes[3]]*V/T - dPdt*V/P 
    for ind in d.constantspeciesinds #make dydt zero for constant species
        @inbounds dydt[ind] = 0.0
    end
    for inter in interfaces
        if isa(inter,Inlet) && d == inter.domain
            flow = inter.F(t)
            dydt[d.indexes[1]:d.indexes[2]] .+= inter.y.*flow
            dTdt = flow*(inter.H - dot(Hs,ns)/N)/(N*Cpave)
            dydt[d.indexes[3]] += dTdt
            dydt[d.indexes[4]] += flow*R*T/P + dTdt*V/T
        elseif isa(inter,Outlet) && d == inter.domain
            flow = inter.F(t)
            dydt[d.indexes[1]:d.indexes[2]] .-= flow.*ns./N
            dydt[d.indexes[4]] -= flow*R*T/P
        end
    end
end
export calcdomainderivatives!

@inline function jacobianyefficiencyderiv!(jac::S,domain::Union{ConstantTPDomain,ConstantPDomain,ParametrizedTPDomain,ParametrizedPDomain},kinetics::AbstractFalloffRate,efficiencies::Dict{Int64,Float64},rxnarray::Array{Int64,2},rxnind::Int64,Vind::Int64,cs::Array{Float64,1},T::Float64,V::Float64,C::Float64,Ceff::Float64,Kc::Float64) where {S<:AbstractArray}
    dkdCeff = _calcdkdCeff(kinetics,T,Ceff)
    for (spcind,efficiencyval) in efficiencies
        @fastmath dkdni = dkdCeff*(efficiencyval/V)
        _jacobianykderiv!(jac,spcind,dkdni,dkdni/Kc,rxnarray,rxnind,cs,V)
    end
    @fastmath dkdV = dkdCeff*(C-Ceff)/V
    _jacobianykderiv!(jac,Vind,dkdV,dkdV/Kc,rxnarray,rxnind,cs,V)
end

@inline function jacobianyefficiencyderiv!(jac::S,domain::Union{ConstantVDomain,ParametrizedVDomain,ConstantTVDomain,ParametrizedTConstantVDomain},kinetics::AbstractFalloffRate,efficiencies::Dict{Int64,Float64},rxnarray::AbstractArray,rxnind::Int64,Vind::Int64,cs::Array{Float64,1},T::Float64,V::Float64,C::Float64,Ceff::Float64,Kc::Float64) where {S<:AbstractArray}
    dkdCeff = _calcdkdCeff(kinetics,T,Ceff)
    for (spcind,efficiencyval) in efficiencies
        @fastmath dkdni = dkdCeff*(efficiencyval/V)
        _jacobianykderiv!(jac,spcind,dkdni,dkdni/Kc,rxnarray,rxnind,cs,V)
    end
end

@inline function jacobianynsderiv!(jac::S,domain::Union{ConstantTPDomain,ParametrizedTPDomain},rxnarray::Array{Int64,2},efficiencyinds::Array{I,1},cs::Array{Float64,1},kfs::Array{Float64,1},krevs::Array{Float64,1},T::Float64,V::Float64,C::Float64) where {S<:AbstractArray,I<:Integer}
    @simd for rxnind = 1:size(rxnarray)[2]
        @inbounds _jacobianynswrtns!(jac,rxnarray,rxnind,cs,kfs[rxnind],krevs[rxnind])
        @inbounds _jacobianynswrtV!(jac,domain.indexes[3],rxnarray,rxnind,cs,kfs[rxnind],krevs[rxnind])
        if rxnind in efficiencyinds
            @inbounds @fastmath Kc = kfs[rxnind]/krevs[rxnind]
            @inbounds @fastmath Ceff = C + sum(cs[i]*val for (i,val) in domain.phase.reactions[rxnind].kinetics.efficiencies)
            @inbounds jacobianyefficiencyderiv!(jac,domain,domain.phase.reactions[rxnind].kinetics,domain.phase.reactions[rxnind].kinetics.efficiencies,rxnarray,rxnind,domain.indexes[3],cs,T,V,C,Ceff,Kc)
        end
    end
end

@inline function jacobianynsderiv!(jac::S,domain::Union{ConstantVDomain,ParametrizedVDomain,ConstantTVDomain,ParametrizedTConstantVDomain},rxnarray::Array{Int64,2},efficiencyinds::Array{I,1},cs::Array{Float64,1},kfs::Array{Float64,1},krevs::Array{Float64,1},T::Float64,V::Float64,C::Float64) where {S<:AbstractArray,I<:Integer}
    @simd for rxnind = 1:size(rxnarray)[2]
        @inbounds _jacobianynswrtns!(jac,rxnarray,rxnind,cs,kfs[rxnind],krevs[rxnind])
        if rxnind in efficiencyinds
            @inbounds @fastmath Kc = kfs[rxnind]/krevs[rxnind]
            @inbounds @fastmath Ceff = C + sum(cs[i]*val for (i,val) in domain.phase.reactions[rxnind].kinetics.efficiencies)
            @inbounds jacobianyefficiencyderiv!(jac,domain,domain.phase.reactions[rxnind].kinetics,domain.phase.reactions[rxnind].kinetics.efficiencies,rxnarray,rxnind,0,cs,T,V,C,Ceff,Kc)
        end
    end
end

@inline function jacobianynsderiv!(jac::S,domain::Union{ConstantPDomain,ParametrizedPDomain},rxnarray::Array{Int64,2},efficiencyinds::Array{I,1},cs::Array{Float64,1},kfs::Array{Float64,1},krevs::Array{Float64,1},T::Float64,V::Float64,C::Float64) where {S<:AbstractArray,I<:Integer}
    @simd for rxnind = 1:size(rxnarray)[2]
        @inbounds _jacobianynswrtns!(jac,rxnarray,rxnind,cs,kfs[rxnind],krevs[rxnind])
        @inbounds _jacobianynswrtV!(jac,domain.indexes[4],rxnarray,rxnind,cs,kfs[rxnind],krevs[rxnind])
        if rxnind in efficiencyinds
            @inbounds @fastmath Kc = kfs[rxnind]/krevs[rxnind]
            @inbounds @fastmath Ceff = C + sum(cs[i]*val for (i,val) in domain.phase.reactions[rxnind].kinetics.efficiencies)
            @inbounds jacobianyefficiencyderiv!(jac,domain,domain.phase.reactions[rxnind].kinetics,domain.phase.reactions[rxnind].kinetics.efficiencies,rxnarray,rxnind,domain.indexes[4],cs,T,V,C,Ceff,Kc)
        end
    end
end

@inline function jacobiany!(jac::Q,y::U,p::W,t::Z,domain::D,interfaces::Q3,colorvec::Q2=nothing) where {Q3<:AbstractArray,Q2,Q<:AbstractArray,U<:AbstractArray,W,Z<:Real,D<:ConstantTPDomain}
    ns,cs,T,P,V,C,N,mu,kfs,krevs,Hs,Us,Gs,diffs,Cvave,cpdivR = calcthermo(domain,y,t,p)
    jacobianynsderiv!(jac,domain,domain.rxnarray,domain.efficiencyinds,cs,kfs,krevs,T,V,C)
    
    @simd for i in domain.indexes[1]:domain.indexes[2]
        @views @inbounds @fastmath jac[domain.indexes[3],i] = sum(jac[domain.indexes[1]:domain.indexes[2],i])*R*T/P
    end
    @views @inbounds @fastmath jac[domain.indexes[3],domain.indexes[3]] = sum(jac[domain.indexes[1]:domain.indexes[2],domain.indexes[3]])*R*T/P
          
    @simd for ind in domain.constantspeciesinds
        @inbounds jac[ind,:] .= 0.
    end
    
    @simd for inter in interfaces
        if isa(inter,Outlet) && domain == inter.domain
            flow = inter.F(t)
            @simd for i in domain.indexes[1]:domain.indexes[2]
                @inbounds @fastmath jac[i,i] .-= flow/N
            end
            @views @inbounds @fastmath jac[domain.indexes[1]:domain.indexes[2],domain.indexes[3]] .-= flow.*ns.*(-C)
        end
    end
end

function jacobiany!(jac::Q,y::U,p::W,t::Z,domain::D,interfaces::Q3,colorvec::Q2=nothing) where {Q3<:AbstractArray,Q2,Q<:AbstractArray,U<:AbstractArray,W,Z<:Real,D<:ConstantVDomain}
    ns,cs,T,P,V,C,N,mu,kfs,krevs,Hs,Us,Gs,diffs,Cvave,cpdivR = calcthermo(domain,y,t,p)
    jacobianynsderiv!(jac,domain,domain.rxnarray,domain.efficiencyinds,cs,kfs,krevs,T,V,C)

    dydt = zeros(size(y))
    addreactionratecontributions!(dydt,domain.rxnarray,cs,kfs,krevs)
    dydt .*= V

    for i in domain.indexes[1]:domain.indexes[2]
        @inbounds @fastmath dCvavedni = cpdivR[i]*R/N
        @views @inbounds @fastmath jac[domain.indexes[3],i] = -dot(Us,jac[domain.indexes[1]:domain.indexes[2],i])/(N*Cvave)+dot(Us,dydt[domain.indexes[1]:domain.indexes[2]])/(N*Cvave*Cvave)*dCvavedni
        @views @inbounds @fastmath jac[domain.indexes[4],i] = sum(jac[domain.indexes[1]:domain.indexes[2],i])*R*T/V + P/T*jac[domain.indexes[3],i]
    end
    
    @simd for ind in domain.constantspeciesinds
        @inbounds jac[ind,:] .= 0.
    end
    
    for inter in interfaces
        if isa(inter,Inlet) && domain == inter.domain
            flow = inter.F(t)
            @simd for i in domain.indexes[1]:domain.indexes[2]
                @inbounds @fastmath dCvavedni = cpdivR[i]*R/N
                @fastmath dTdt = flow*(inter.H - dot(Us,ns)/N)/(N*Cvave)
                @inbounds @fastmath ddnidTdt = flow*(-Us[i]/N)/(N*Cvave)-dTdt*(dCvavedni/Cvave)
                @inbounds jac[domain.indexes[3],i] += ddnidTdt
                @inbounds @fastmath jac[domain.indexes[4],i] += P/T*ddnidTdt
            end
        elseif isa(inter,Outlet) && domain == inter.domain
            flow = inter.F(t)
            @simd for i in domain.indexes[1]:domain.indexes[2]
                @inbounds @fastmath jac[i,i] .-= flow/N
                @inbounds @fastmath dCvavedni = cpdivR[i]*R/N
                @fastmath dTdt = (P*V/N*flow)/(N*Cvave)
                @fastmath ddnidTdt = -dTdt*(dCvavedni/Cvave)
                @inbounds jac[domain.indexes[3],i] -= ddnidTdt
                @inbounds @fastmath jac[domain.indexes[4],i] -= P/T*ddnidTdt
            end
        end
    end
    
    @inbounds jacobianytherm!(jac,y,p,t,domain,interfaces,domain.indexes[3],T,colorvec)
    @inbounds jacobianytherm!(jac,y,p,t,domain,interfaces,domain.indexes[4],P,colorvec)

    return jac
end

function jacobiany!(jac::Q,y::U,p::W,t::Z,domain::D,interfaces::Q3,colorvec::Q2=nothing) where {Q3<:AbstractArray,Q2,Q<:AbstractArray,U<:AbstractArray,W,Z<:Real,D<:ConstantPDomain}
    ns,cs,T,P,V,C,N,mu,kfs,krevs,Hs,Us,Gs,diffs,Cvave,cpdivR = calcthermo(domain,y,t,p)
    jacobianynsderiv!(jac,domain,domain.rxnarray,domain.efficiencyinds,cs,kfs,krevs,T,V,C)
    
    dydt = zeros(size(y))
    addreactionratecontributions!(dydt,domain.rxnarray,cs,kfs,krevs)
    dydt .*= V
    
    @fastmath Cpave = Cvave+R
    @views @inbounds @fastmath dTdt = -dot(Hs,dydt[domain.indexes[1]:domain.indexes[2]])/(N*Cpave)
    @simd for i in domain.indexes[1]:domain.indexes[2]
        @inbounds @fastmath dCpavedni = cpdivR[i]*R/N
        @views @inbounds @fastmath jac[domain.indexes[3],i] = -dot(Hs,jac[domain.indexes[1]:domain.indexes[2],i])/(N*Cpave)-dTdt*(dCpavedni/Cpave)
        @views @inbounds @fastmath jac[domain.indexes[4],i] = sum(jac[domain.indexes[1]:domain.indexes[2],i])*R*T/P + V/T*jac[domain.indexes[3],i]
    end
    @views @inbounds @fastmath jac[domain.indexes[3],domain.indexes[4]] = -dot(Hs,jac[domain.indexes[1]:domain.indexes[2],domain.indexes[4]])/(N*Cpave)
    @views @inbounds @fastmath jac[domain.indexes[4],domain.indexes[4]] = sum(jac[domain.indexes[1]:domain.indexes[2],domain.indexes[4]])*R*T/P + dTdt/T + V/T*jac[domain.indexes[3],domain.indexes[4]]
    
    @simd for ind in domain.constantspeciesinds
        @inbounds jac[ind,:] .= 0.
    end
    
    @simd for inter in interfaces
        if isa(inter,Inlet) && domain == inter.domain
            flow = inter.F(t)
            @fastmath H = dot(Hs,ns)/N
            @fastmath dTdt = flow*(inter.H - H)/(N*Cpave)
            @simd for i in domain.indexes[1]:domain.indexes[2]
                @inbounds @fastmath dCpavedni = cpdivR[i]*R/N
                @inbounds @fastmath ddnidTdt = flow*(-Hs[i]/N)/(N*Cpave)-dTdt*(dCpavedni/Cpave)
                @inbounds jac[domain.indexes[3],i] += ddnidTdt
                @inbounds @fastmath jac[domain.indexes[4],i] += V/T*ddnidTdt
            end
            @fastmath ddVdTdt = -flow*H/V/(N*Cpave)
            @inbounds jac[domain.indexes[3],domain.indexes[4]] += ddVdTdt
            @inbounds @fastmath jac[domain.indexes[4],domain.indexes[4]] += dTdt/T + V/T*ddVdTdt
        elseif isa(inter,Outlet) && domain == inter.domain
            flow = inter.F(t)
            @simd for i in domain.indexes[1]:domain.indexes[2]
                @inbounds @fastmath jac[i,i] .-= flow/N
            end
        end
    end
    
    @inbounds jacobianytherm!(jac,y,p,t,domain,interfaces,domain.indexes[3],T,colorvec)
    
    return jac
end

function jacobiany!(jac::Q,y::U,p::W,t::Z,domain::D,interfaces::Q3,colorvec::Q2=nothing) where {Q3<:AbstractArray,Q2,Q<:AbstractArray,U<:AbstractArray,W,Z<:Real,D<:ParametrizedTPDomain}
    ns,cs,T,P,V,C,N,mu,kfs,krevs,Hs,Us,Gs,diffs,Cvave,cpdivR = calcthermo(domain,y,t,p)
    jacobianynsderiv!(jac,domain,domain.rxnarray,domain.efficiencyinds,cs,kfs,krevs,T,V,C)
    
    @simd for i in domain.indexes[1]:domain.indexes[2]
        @views @inbounds @fastmath jac[domain.indexes[3],i] = sum(jac[domain.indexes[1]:domain.indexes[2],i])*R*T/P
    end
    @views @inbounds @fastmath jac[domain.indexes[3],domain.indexes[3]] = sum(jac[domain.indexes[1]:domain.indexes[2],domain.indexes[3]])*R*T/P
    
    @simd for ind in domain.constantspeciesinds
        @inbounds jac[ind,:] .= 0.
    end
    
    @simd for inter in interfaces
        if isa(inter,Outlet) && domain == inter.domain
            flow = inter.F(t)
            @simd for i in domain:indexes[1]:domain.indexes[2]
                @inbounds @fastmath jac[i,i] .-= flow/N
            end
        end
    end
    
    @inbounds jacobianytherm!(jac,y,p,t,domain,interfaces,domain.indexes[3],V,colorvec)
    
    return jac
end

function jacobiany!(jac::Q,y::U,p::W,t::Z,domain::D,interfaces::Q3,colorvec::Q2=nothing) where {Q3<:AbstractArray,Q2,Q<:AbstractArray,U<:AbstractArray,W,Z<:Real,D<:ParametrizedVDomain}
    ns,cs,T,P,V,C,N,mu,kfs,krevs,Hs,Us,Gs,diffs,Cvave,cpdivR = calcthermo(domain,y,t,p)
    jacobianynsderiv!(jac,domain,domain.rxnarray,domain.efficiencyinds,cs,kfs,krevs,T,V,C)
    
    dydt = zeros(size(y))
    addreactionratecontributions!(dydt,domain.rxnarray,cs,kfs,krevs)
    dydt .*= V
    
    dVdt = Calculus.derivative(domain.V,t)
    @simd for i in domain.indexes[1]:domain.indexes[2]
        @fastmath @inbounds dCvavedni = cpdivR[i]*R/N
        @views @inbounds @fastmath jac[domain.indexes[3],i] = -dot(Us,jac[domain.indexes[1]:domain.indexes[2],i])/(N*Cvave)-(-dot(Us,dydt[domain.indexes[1]:domain.indexes[2]])-P*dVdt)/(N*Cvave*Cvave)*dCvavedni
        @views @inbounds @fastmath jac[domain.indexes[4],i] = sum(jac[domain.indexes[1]:domain.indexes[2],i])*R*T/V + P/T*jac[domain.indexes[3],i]
    end
    
    @simd for ind in domain.constantspeciesinds
        @inbounds jac[ind,:] .= 0.
    end
    
    @simd for inter in interfaces
        if isa(inter,Inlet) && domain == inter.domain
            flow = inter.F(t)
            @fastmath dTdt = flow*(inter.H - dot(Us,ns)/N)/(N*Cvave)
            @simd for i in domain.indexes[1]:domain.indexes[2]
                @inbounds @fastmath dCvavedni = cpdivR[i]*R/N
                @inbounds @fastmath ddnidTdt = flow*(-Us[i]/N)/(N*Cvave)-dTdt*(dCvavedni/Cvave)
                @inbounds jac[domain.indexes[3],i] += ddnidTdt
                @inbounds @fastmath jac[domain.indexes[4],i] += P/T*ddnidTdt
            end
        elseif isa(inter,Outlet) && domain == inter.domain
            flow = inter.F(t)
            @fastmath dTdt = (P*V/N*flow)/(N*Cvave)
            @simd for i in domain.indexes[1]:domain.indexes[2]
                @inbounds @fastmath jac[i,i] .-= flow/N
                @inbounds @fastmath dCvavedni = cpdivR[i]*R/N
                @fastmath ddnidTdt = -dTdt*(dCvavedni/Cvave)
                @inbounds jac[domain.indexes[3],i] -= ddnidTdt
                @inbounds @fastmath jac[domain.indexes[4],i] -= P/T*ddnidTdt
            end
        end
    end
    
    @inbounds jacobianytherm!(jac,y,p,t,domain,interfaces,domain.indexes[3],T,colorvec)
    @inbounds jacobianytherm!(jac,y,p,t,domain,interfaces,domain.indexes[4],P,colorvec)

    return jac
end

function jacobiany!(jac::Q,y::U,p::W,t::Z,domain::D,interfaces::Q3,colorvec::Q2=nothing) where {Q3<:AbstractArray,Q2,Q<:AbstractArray,U<:AbstractArray,W,Z<:Real,D<:ParametrizedPDomain}
    ns,cs,T,P,V,C,N,mu,kfs,krevs,Hs,Us,Gs,diffs,Cvave,cpdivR = calcthermo(domain,y,t,p)
    jacobianynsderiv!(jac,domain,domain.rxnarray,domain.efficiencyinds,cs,kfs,krevs,T,V,C)
    
    dydt = zeros(size(y))
    addreactionratecontributions!(dydt,domain.rxnarray,cs,kfs,krevs)
    dydt .*= V
    
    @fastmath Cpave = Cvave+R
    dPdt = Calculus.derivative(domain.P,t)
    @views @inbounds @fastmath dTdt = (-dot(Hs,dydt[domain.indexes[1]:domain.indexes[2]])+V*dPdt)/(N*Cpave)
    @simd for i in domain.indexes[1]:domain.indexes[2]
        @inbounds @fastmath dCpavedni = cpdivR[i]*R/N
        @views @inbounds @fastmath jac[domain.indexes[3],i] = -dot(Hs,jac[domain.indexes[1]:domain.indexes[2],i])/(N*Cpave)-dTdt*(dCpavedni/Cpave)
        @views @inbounds @fastmath jac[domain.indexes[4],i] = sum(jac[domain.indexes[1]:domain.indexes[2],i])*R*T/P + V/T*jac[domain.indexes[3],i]
    end
    @views @inbounds @fastmath jac[domain.indexes[3],domain.indexes[4]] = (-dot(Hs,jac[domain.indexes[1]:domain.indexes[2],domain.indexes[4]])+dPdt)/(N*Cpave)
    @views @inbounds @fastmath jac[domain.indexes[4],domain.indexes[4]] = sum(jac[domain.indexes[1]:domain.indexes[2],domain.indexes[4]])*R*T/P + dTdt/T + V/T*jac[domain.indexes[3],domain.indexes[4]]-dPdt/P 
    
    @simd for ind in domain.constantspeciesinds
        @inbounds jac[ind,:] .= 0.
    end
    
    @simd for inter in interfaces
        if isa(inter,Inlet) && domain == inter.domain
            flow = inter.F(t)
            @fastmath H = dot(Hs,ns)/N
            @fastmath dTdt = flow*(inter.H - H)/(N*Cpave)
            @simd for i in domain.indexes[1]:domain.indexes[2]
                @inbounds @fastmath dCpavedni = cpdivR[i]*R/N
                @inbounds @fastmath ddnidTdt = flow*(-Hs[i]/N)/(N*Cpave)-dTdt*(dCpavedni/Cpave)
                @inbounds jac[domain.indexes[3],i] += ddnidTdt
                @inbounds @fastmath jac[domain.indexes[4],i] += V/T*ddnidTdt
            end
            @fastmath ddVdTdt = -flow*H/V/(N*Cpave)
            @inbounds jac[domain.indexes[3],domain.indexes[4]] += ddVdTdt
            @inbounds @fastmath jac[domain.indexes[4],domain.indexes[4]] += dTdt/T + ddVdTdt*V/T
        elseif isa(inter,Outlet) && domain == inter.domain
            flow = inter.F(t)
            @simd for i in domain.indexes[1]:domain.indexes[2]
                @inbounds @fastmath jac[i,i] .-= flow/N
            end
            @views @inbounds @fastmath jac[domain.indexes[1]:domain.indexes[2],domain.indexes[4]] .-= -flow.*ns./N/V
        end
    end
    
    @inbounds jacobianytherm!(jac,y,p,t,domain,interfaces,domain.indexes[3],T,colorvec)
    
    return jac
end

function jacobiany!(jac::Q,y::U,p::W,t::Z,domain::D,interfaces::Q3,colorvec::Q2=nothing) where {Q3<:AbstractArray,Q2,Q<:AbstractArray,U<:AbstractArray,W,Z<:Real,D<:Union{ConstantTVDomain,ConstantTADomain,ParametrizedTConstantVDomain}}
    ns,cs,T,P,V,C,N,mu,kfs,krevs,Hs,Us,Gs,diffs,Cvave = calcthermo(domain,y,t,p)
    jacobianynsderiv!(jac,domain,domain.rxnarray,domain.efficiencyinds,cs,kfs,krevs,T,V,C)
    
    @simd for ind in domain.constantspeciesinds
        @inbounds jac[ind,:] .= 0.
    end
    
    @simd for inter in interfaces
        if isa(inter,Outlet) && domain == inter.domain
            flow = inter.F(t)
            @simd for i in domain.indexes[1]:domain.indexes[2]
                @inbounds @fastmath jac[i,i] .-= flow/N
            end
        end
    end

    return jac
end

export jacobiany!

function getreactionindices(ig::Q) where {Q<:AbstractPhase}
    arr = zeros(Int64,(6,length(ig.reactions)))
    for (i,rxn) in enumerate(ig.reactions)
        arr[1:length(rxn.reactantinds),i] = rxn.reactantinds
        arr[4:length(rxn.productinds)+3,i] = rxn.productinds
    end
    return arr
end
export getreactionindices

"""
fit a cubic spline to data and return a function evaluating that spline
"""
function getspline(xs,vals;s=1e-10)
    smspl = fit(SmoothingSpline,xs,vals,s)
    F(x::T) where {T} = predict(smspl,x)
    return F
end

function getthermovariableindex(domain::Union{ConstantTPDomain,ParametrizedTPDomain},target::String)
    return domain.indexes[3]
end

function getthermovariableindex(domain::Union{ConstantVDomain,ParametrizedVDomain},target::String)
    if target == "T"
        return domain.indexes[3]
    elseif target == "P"
        return domain.indexes[4]
    end
end

function getthermovariableindex(domain::Union{ConstantPDomain,ParametrizedPDomain},target::String)
    if target == "T"
        return domain.indexes[3]
    elseif target == "V"
        return domain.indexes[4]
    end
end
