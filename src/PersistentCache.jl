module PersistentCache

using Printf
using JLD2
using MacroTools
using Glob

export @pcache, @pcacheref, @punref, value, readcaches, namedtuple

#export Parameters, @addstorepars, @storepars, @cachepars, filename, namedtuple

# TODO: structures can store the parameters passed to many functions, but it is not clear we ever need more than one function

###########################################################
## Functions used to capture parameters passed to functions
###########################################################

"""
Structure used to store the values of the parameters passed to functions

# Fields
+ `fun::Vector{Symbol}`: function name
+ `args::Vector{Tuple}`: values of positional arguments
+ `kwargs::Vector{Dict{Symbol,Any}}`: values of keyword arguments

!!! note
    Current implementation supports storing values passed to many functions. Subsequent versions may
    be restricted to one function per structure.

!!! note
    This is an internal function, not likely to be externally accessed
"""
mutable struct Parameters
    fun::Vector{Symbol}
    args::Vector{Tuple}
    kwargs::Vector{Dict{Symbol,Any}}
    Parameters(fun::Vector{Symbol}, args::Vector{Tuple}, kwargs::Vector{Dict{Symbol,Any}}) = new(fun, args, kwargs)
    Parameters() = new(Symbol[], Tuple[], Dict{Symbol,Any}[])
end
function Base.push!(
    pars::Parameters,
    fun::Symbol,
    args::Tuple=tuple(),
    kwargs::Dict{Symbol,Any}=Dict{Symbol,Any}()
)
    push!(pars.fun, fun)
    push!(pars.args, deepcopy(args))
    push!(pars.kwargs, deepcopy(kwargs))
    return pars.kwargs[end]
end
function Base.display(pars::Parameters)
    parameterSize = Base.summarysize(pars)
    @printf("Parameters (%d bytes)\n", parameterSize)
    for i in eachindex(pars.fun, pars.args, pars.kwargs)
        v = pars.args[i]
        str = string(v)
        if length(str) > 50
            parameterSize = Base.summarysize(v)
            str = @sprintf("%s ... (%d bytes)", str[1:50], parameterSize)
        end
        @printf("  fun: %-20s args = %s\n", pars.fun[i], str)
        for (k, v) in pars.kwargs[i]
            str = string(v)
            if length(str) > 50
                parameterSize = Base.summarysize(v)
                str = @sprintf("%s ... (%d bytes)", str[1:50], parameterSize)
            end
            @printf("    %-22s: %s\n", k, str)
        end
    end
end

"""
    getParameters(arg1, arg2, ... ; kwargs1=..., kwarg2=..., ...)

Capture parameters into a tuple with (positional arguments, keyword arguments)
"""
getParameters(args...; kwargs...) = (args, kwargs)

"""
    storeParameters!(pars, functionName, arg1, arg2, ... ; kwargs1=..., kwarg2=..., ...)

Stores parameters in a `Parameters` structure:
+ `pars::Parameters`: structure where parameters will be stored
+ `functionName::String`: function name
+ `arg1, arg2, ...`: positional arguments
+ `kwargs1=..., kwarg2=..., ...`: keyword arguments

!!! note
    This is an internal function, not likely to be externally accessed
"""
function storeParameters!(
    pars::Parameters,
    functionName::String,
    args...; kwargs...)
    dic = push!(pars, Symbol(functionName), args)
    for (k, v) in kwargs
        #@show (k, v)
        dic[k] = v
    end
end

"""
    filename(pars; prefix, suffix::String=".jld2", full::Bool=false)

Select filename based on Parameters structure:
1) if structure is "small" essentially convert it to a string
2) if structure is "large" augments the function name with an "hash" of the parameter values 

+ `pars::Parameters`: parameters based 
+ `prefix::String=""`
+ `suffix::String=".jld2"`
+ `full::Bool=false`

!!! note
    This is an internal function, not likely to be externally accessed
"""
function filename(pars::Parameters; prefix::String="", suffix::String=".jld2", full::Bool=false)

    function argsName(args::Tuple)
        if length(args) == 1
            return string(args[1])
        else
            return join([string(a) for a in args], ",")
        end
    end

    kwargsName(kwargs::Dict{Symbol,Any}) =
        join([(isa(v, Bool) && v == true) ? string(k) : string(k) * "=" * string(v)
              for (k, v) in kwargs if !isa(v, Bool) || v == true
            ], "_")

    filename = join([string(pars.fun[i]) * "[" *
                     argsName(pars.args[i]) * ";" *
                     kwargsName(pars.kwargs[i]) * "]"
                     for i in eachindex(pars.fun)], "_")

    if length(filename) > 40 && !full
        # names too long get hashed
        if length(pars.fun) == 1
            filename = string(pars.fun[1]) * "[hash_" * string(hash(filename)) * "]"
        else
            filename = "hash_" * string(hash(filename))
        end
    end
    return prefix * filename * suffix
end

###################
## Persistent cache
###################

"""
    Structure used to store a reference to a variable, in the form of a filename in a file system.

!!! note
    The reference does not store the `type` of the variable stored. 
    This has advantages and problems:
    + When there is a cache "hit" @pcacheref returns the reference, but does not need to read the
      file to check the type. This makes the function `inCache()` fast
    - Types cannot be "propagated" when a reference is encountered.
"""
struct RefToCache
    filename::String
end

""" Automatic unreferencing """
function Base.convert(::Type{RefToCache}, ref::RefToCache)
    #@printf("no convert(%s)", ref.filename)
    return ref
end
function Base.convert(::Type{T}, ref::RefToCache) where {T}
    @printf("convert(%s,%s)", T, ref.filename)
    return Base.convert(T, value(ref))
end
# needed to prevent error in  @ Base some.jl:36 that arises when using Distributed.fetch()
Base.convert(::Type{Any}, ref::RefToCache) = ref


value(ref::RefToCache) = load(ref.filename, "output")

function resolveReferences(args...; kwargs...)
    # resolve references in non-keyword arguments
    if any(isa.(args, Ref(RefToCache)))
        args = Tuple(isa(a, RefToCache) ?
                     value(a) :
                     a for a in args)
    end
    kwargs = Dict(isa(v, RefToCache) ? k => value(v) : k => v for (k, v) in kwargs)
    return (args, kwargs)
end

function inCache(pars::Parameters; prefix::String="")
    name = filename(pars; prefix)
    if isfile(name)
        # value exists in cache: return file content
        @printf("cache load(\"%s\", %dM)\n", name, filesize(name) / 1e6)
        data = load(name, "pars")
        @assert data != pars "hash collision"
        return (true, name)
    else
        #println("inCache: no hit for \"$name\"")
        return (false, name)
    end
end

function getFromCache(pars::Parameters; prefix::String="")
    name = filename(pars; prefix)
    if isfile(name)
        # value exists in cache: return file content
        @printf("cache load(\"%s\", %dM)\n", name, filesize(name) / 1e6)
        data = load(name)
        @assert data["pars"] != pars "hash collision"
        return (true, data["output"], name)
    else
        # value does not exist in cache: expanded parameters needed for function call
        return (false, nothing, name)
    end
end

function saveToCache(pars::Parameters, output; prefix::String="")
    parameterSize = Base.summarysize(pars)
    if parameterSize > 2000
        #display(pars)
        @warn @sprintf("parameters too large (%d bytes), consider using @pcacheref to create parameters (see example in @pcacheref documentation)", parameterSize)
    end
    name = filename(pars; prefix)
    @assert !isfile(name) "cache file \"$name\" already exists"
    jldsave(name; pars, output)
    @printf("cache save(\"%s\", %dM)\n", name, filesize(name) / 1e6)
    return name
end

"""
    readcaches(prefix)

This function displays information about all the files containing cached function parameters/values with the given prefix.
"""
function readcaches(prefix="")
    files = glob(prefix * "*.jld2")
    caches = [load(name, "pars") for name in files]
    for i in eachindex(files, caches)
        cache = caches[i]
        parameterSize = Base.summarysize(cache)
        @printf("file \"%s\" (file =%dM, pars=%dK)\n  ",
            files[i], filesize(files[i]) / 1e6, parameterSize / 1e3)
        display(caches[i])
    end
    return (caches, files)
end

#########
## Macros
#########

#=
# TODO not really used
"""
"Decorator" to a function definition that creates an additional function definition that takes a
Parameter structure where parameter values are stored

# Example

```julia
@addstorepars function example(aa; a::Int, b::String)
    return aa+a
end

pars=Parameters()    
c=example(pars,3;a=1,b="s")
display(pars)
```

!!! note
    Seems very wasteful to create a new function. Might as well save parameters before each call.

    This is not used and will likely be removed in subsequent versions.
"""
macro addstorepars(expr::Expr)
    #@show expr
    @assert @capture(expr, function functionName_(functionParameters__)
        body_
    end) "@addstorepars can only by applied to function definition"
    #@show functionName
    #@show prettify(pars)
    #@show prettify(body)
    quote
        # original function
        $(esc(expr))
        # version that saves parameters
        function $(esc(functionName))(pars::Parameters, args...; kwargs...)
            storeParameters!(pars, $(string(functionName)), args...; kwargs...)
            return $(esc(functionName))(args...; kwargs...)
        end
    end
end

=#

#=
# TODO not really needed 
"""Recursive escape"""
function deepesc(expr)
    #@show expr
    #@show typeof(expr)
    if isa(expr, Expr)
        if expr.head == :call
            return :($(esc(expr)))
        elseif expr.head == :kw
            return Expr(:kw, expr.args[1], deepesc(expr.args[2]))
        elseif expr.head == :parameters
            if length(expr.args) == 1
                return Expr(:parameters, deepesc(expr.args[1]))
            else
                return Expr(:parameters, deepesc.(expr.args))
            end
        end
    elseif isa(expr, Symbol)
        return :($(esc(expr)))
    end
    return expr

end
=#

"""
    "Decorator" for a call to a function that stores parameters in a `Parameters` structure before calling a function

# Example

```julia
pars=Parameters()    
c= @storepars pars rand(3,3)
display(pars)
```
"""
macro storepars(pars::Symbol, functionCall::Expr)
    @assert @capture(functionCall, functionName_(functionParameters__)) "@storepars can only be applied to function call"
    ## create function call to getParameters
    saveCall = copy(functionCall)
    saveCall.args[1] = :(PersistentCache.getParameters)
    #escFunctionParameters = deepesc.(functionParameters)
    #escSaveCall = Expr(:call, :getParameters, escFunctionParameters...)
    quote
        ## save parameters
        (args, kwargs) = $(esc(saveCall))
        #(args, kwargs) = $escSaveCall
        storeParameters!($(esc(pars)), $(string(functionName)), args...; kwargs...)
        ## call function
        $(esc(functionCall))
    end
end

macro cachepars(pars::Symbol, prefix, functionCall::Expr)
    @assert @capture(functionCall, functionName_(functionParameters__)) "@storepars can only be applied to function call"
    ## create function call to getParameters
    saveCall = copy(functionCall)
    saveCall.args[1] = :(PersistentCache.getParameters)
    quote
        ## save parameters
        (args, kwargs) = $(esc(saveCall))
        storeParameters!($(esc(pars)), $(string(functionName)), args...; kwargs...)
        outputFilename = filename($(esc(pars)), prefix=$(esc(prefix)))
        ## call function
        rc = $(esc(functionCall))
        ## save return
        println("cachepars(\"$outputFilename\")")
        jldsave(outputFilename; pars=$(esc(pars)), output=rc)
        ## return
        rc
    end
end

#=
macro cachepars(pars::Symbol, prefix::String, functionCall::Expr)
    #Meta.@dump p
    #Meta.@dump x
    #@show pars
    @assert functionCall.head == :call  # macro only applies to function call
    functionName = functionCall.args[1]
    args = functionCall.args[2:end]
    #@show functionName
    #@show args
    nkargs = Expr(:tuple)
    kargs_kw = Symbol[]
    kargs_values = Expr(:tuple)
    for arg in args
        if typeof(arg) == Expr && arg.head == :parameters
            for ar in arg.args
                #@show ar
                if typeof(ar) == Expr && ar.head == :kw
                    # keyword=value
                    arg2 = ar.args[2]
                    push!(kargs_kw, ar.args[1])
                    push!(kargs_values.args, :($(esc(arg2))))
                elseif isa(ar, Symbol)
                    # keyword
                    push!(kargs_kw, ar)
                    push!(kargs_values.args, :($(esc(ar))))
                end
            end
        elseif typeof(arg) != Expr || arg.head != :kw
            # store values of non-keyword argument
            push!(nkargs.args, :($(esc(arg))))
        else
            # store symbols and values of keyword argument
            arg2 = arg.args[2]
            push!(kargs_kw, arg.args[1])
            push!(kargs_values.args, :($(esc(arg2))))
        end
    end
    #@show nkargs
    #@show kargs_kw
    #@show kargs_values
    quote
        # non-keyword argument
        dic = push!($(esc(pars)), Symbol($(string(functionName))), $nkargs)
        #$(esc(pars)).values[Symbol($(string(functionName)))] = $nkargs
        # keyword argument
        for i in 1:length($kargs_kw)
            kw = $kargs_kw[i]
            #println(typeof(kw), " : ", kw)
            #$(esc(pars)).values[kw] = ($kargs_values)[i]
            dic[kw] = ($kargs_values)[i]
        end
        outputFilename = filename($(esc(pars)), prefix=$(esc(prefix)))
        rc = $(esc(functionCall))
        println("cachepars(\"$outputFilename\")")
        jldsave(outputFilename; pars=$(esc(pars)), output=rc)
        rc
    end
end
=#

"""
Function used to create a named tuple from keyword arguments. 
This function is useful in conjunction with @pcacheref to "hide" large parameters.

# Example

```julia
par1 = @pcacheref "./" ones(Float64, 100, 100)
par2 = @pcacheref "./" zeros(Float64, 100, 100)
par3 = @pcacheref "./" tuple(1,2,3)
par4 = @pcacheref "./" namedtuple(name="aaa", value=53)

# will do automatic unreferencing
rc = @pcacheref "./" myfunction(par1,par2,par3,par4) 
display(value(rc))
```
"""
function namedtuple(; kwargs...)::NamedTuple
    return (; kwargs...)
end


"""
"Transparent" persistent cache with each call to the function saved in an individual file.

Each file stores 
+ function name
+ function parameters
+ function output

# Usage

    @pcache filename_prefix function_call

where
+ `filename_prefix::String` is a prefix for the name of the file where the function
      name/parameters/output will be stored. Often `filename_prefix` includes an absolute or
      relative path; e.g.,
    + `file_name="./"` results in files saved in the current folder
    + `file_name="/tmp/` results in files saved in tme "/tmp" folder
    + `file_name="./pc_` results in files saved in the current folder, with filenames starting
          with the 3 characters "pc_"

    It is generally a good idea to keep all the cache files in a specific folder or, at least, use
    some distinct prefix. Otherwise, the current folder will rapidly become very crowded with `JLD2`
    files.

+ `function_call::Any` is a call to a julia function 

# Example

```julia
x = @pcache "./" ones(Float64, 3, 3) 
    cache save("./ones[Float64,3,3;].jld2")
    3×3 Matrix{Float64}:
    1.0  1.0  1.0
    1.0  1.0  1.0
    1.0  1.0  1.0
y = @pcache "./" ones(Float64, 3, 3) 
    cache load("./ones[Float64,3,3;].jld2")
    3×3 Matrix{Float64}:
    1.0  1.0  1.0
    1.0  1.0  1.0
    1.0  1.0  1.0
```

See also @pcacheref for a "non-transparent" version of @pcache
"""
macro pcache(prefix, functionCall::Expr)
    @assert @capture(functionCall, functionName_(functionParameters__)) "@storepars can only be applied to function call"
    ## create function call to getParameters
    saveCall = copy(functionCall)
    saveCall.args[1] = :(PersistentCache.getParameters)
    ## create function call to resolveReferences
    unreferenceCall = copy(functionCall)
    unreferenceCall.args[1] = :(PersistentCache.resolveReferences)
    quote
        ## save parameters
        (args, kwargs) = $(esc(saveCall))
        pars1 = Parameters()
        storeParameters!(pars1, $(string(functionName)), args...; kwargs...)
        ## check if in cache
        oldParameters1 = deepcopy(pars1) # save pars in case function makes in-place changes
        (hit, rc, _) = getFromCache(oldParameters1; prefix=$(esc(prefix)))
        if !hit
            ## call function
            #rc = $(esc(functionCall))
            (args, kwargs) = $(esc(unreferenceCall))
            rc = $(esc(functionName))(args...; kwargs...)
            # save unreferenced parameters (to keep short)
            name = saveToCache(oldParameters1, rc; prefix=$(esc(prefix)))
        end
        rc
    end
end

"""
"Non-transparent" persistent cache with each call to the function saved in an individual file.

Each file stores 
+ function name
+ function parameters
+ function output


The function is "non-transparent" because it returns a "reference" to the file where the data was
saved. The actual output can be recovered using `value()`

When these "references" are used as input parameters to functions called with `@pcacheref` or
`@punref`, the value of the "references" are automatically expanded.

# Usage

    @pcacheref filename_prefix function_call

where
+ `filename_prefix::String` is a prefix for the name of the file where the function
      name/parameters/output will be stored. Often `filename_prefix` includes an absolute or
      relative path; e.g.,
    + `file_name="./"` results in files saved in the current folder
    + `file_name="/tmp/` results in files saved in tme "/tmp" folder
    + `file_name="./pc_` results in files saved in the current folder, with filenames starting
          with the 3 characters "pc_"

    It is generally a good idea to keep all the cache files in a specific folder or, at least, use
    some distinct prefix. Otherwise, the current folder will rapidly become very crowded with `JLD2`
    files.

+ `function_call::Any` is a call to a julia function 

# Example

```julia
x = @pcacheref "./" ones(Float64, 3, 3) 
    cache save("./ones[Float64,3,3;].jld2")
    PersistentCache.RefToCache("./ones[Float64,3,3;].jld2")
value(x)
    3×3 Matrix{Float64}:
    1.0  1.0  1.0
    1.0  1.0  1.0
    1.0  1.0  1.0
y = @pcacheref "./" ones(Float64, 3, 3) 
    cache load("./ones[Float64,3,3;].jld2")
    PersistentCache.RefToCache("./ones[Float64,3,3;].jld2")
z = @pcacheref "./" +(x,y)        
    cache save("./hash_7438214170582956065.jld2")
    PersistentCache.RefToCache("./hash_7438214170582956065.jld2")
value(z)
    3×3 Matrix{Float64}:
    2.0  2.0  2.0
    2.0  2.0  2.0
    2.0  2.0  2.0
```

See also @pcache for "transparent" version
"""
macro pcacheref(prefix, functionCall::Expr)
    @assert @capture(functionCall, functionName_(functionParameters__)) "@storepars can only be applied to function call"
    ## create function call to getParameters
    saveCall = copy(functionCall)
    saveCall.args[1] = :(PersistentCache.getParameters)
    ## create function call to resolveReferences
    unreferenceCall = copy(functionCall)
    unreferenceCall.args[1] = :(PersistentCache.resolveReferences)
    quote
        ## save parameters
        (args, kwargs) = $(esc(saveCall))
        pars1 = Parameters()
        storeParameters!(pars1, $(string(functionName)), args...; kwargs...)
        ## check if in cache
        oldParameters1 = deepcopy(pars1) # save pars in case function makes in-place changes
        (hit, name) = inCache(oldParameters1; prefix=$(esc(prefix)))
        if !hit
            ## call function
            #rc = $(esc(functionCall))
            (args, kwargs) = $(esc(unreferenceCall))
            rc = $(esc(functionName))(args...; kwargs...)
            # save unreferenced parameters (to keep short)
            name = saveToCache(oldParameters1, rc; prefix=$(esc(prefix)))
        end
        RefToCache(name)
    end
end

"""
Call function, expanding any persistent references created by @pcacheref 

To simply expand a variable, use the `identity` function.

# Example

```julia
x = @pcacheref "./" ones(Float64, 3, 3) 
    cache save("./ones[Float64,3,3;].jld2")
    PersistentCache.RefToCache("./ones[Float64,3,3;].jld2")
y = @pcacheref "./" ones(Float64, 3, 3) 
    cache load("./ones[Float64,3,3;].jld2")
    PersistentCache.RefToCache("./ones[Float64,3,3;].jld2")
w = @punref "./" +(x,y)        
    cache save("./hash_7438214170582956065.jld2")
    PersistentCache.RefToCache("./hash_7438214170582956065.jld2")
z = @punref "./" identity(x)
```

!!! note

    @punref is not be needed when the function defines input types, which automatically call for convert()
"""
macro punref(prefix, functionCall::Expr)
    @assert @capture(functionCall, functionName_(functionParameters__)) "@storepars can only be applied to function call"
    ## create function call to resolveReferences
    unreferenceCall = copy(functionCall)
    unreferenceCall.args[1] = :(PersistentCache.resolveReferences)
    quote
        (args, kwargs) = $(esc(unreferenceCall))
        rc = $(esc(functionName))(args...; kwargs...)
    end
end

end
