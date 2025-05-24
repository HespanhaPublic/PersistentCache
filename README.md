# `PersistentCache`

This julia package stores the result of computationally expensive function calls and returns the
values stored in the cache when the function is subsequently called with the same input (i.e.,
parameters), a technique often called [memoization](https://en.wikipedia.org/wiki/Memoization).

It differs from other memoization packages, like
[Memoize.jl](https://github.com/JuliaCollections/Memoize.jl) or
[Memoization.jl](https://github.com/marius311/Memoization.jl), in that the results are stored in the
file system and will persist across julia sessions. Each function call and its results are stored in
an individual file, which facilitates erasing only the data specific to one function or even to just
one particular input to a function.

This package targets functions that are computationally very expensive, such as training an ML model
or processing a large dataset.

When the output returned by the function is very large (e.g., a trained ML model), loading the
result from disk can be slow so this package offers a "lazy-load" option of simply getting a reference to the
relevant file. This reference can be passed to other functions, without actually loading the data until it is
really needed. 

# Usage

This package can be used in an almost transparent way using the `@pcache` macro, but in scenarios
involving a workflow where outputs of one function turn into inputs to subsequent functions the
macro `@pcacheref` is often much better.

## The `@pcache` macro

The simplest way to use `PersistentCache` is through the `@pcache` macro, which takes the form

```julia
@pcache filename_prefix function_call
```

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

A typical example is

```julia
using PersistentCache
x = @pcache "./pc_" ones(Float64, 3, 3) 
    cache save("./pc_ones[Float64,3,3;].jld2", 0M)
display(x)
    3×3 Matrix{Float64}:
    1.0  1.0  1.0
    1.0  1.0  1.0
    1.0  1.0  1.0
```

for which a subsequent call to `ones(Float64, 3, 3)` retrieves the perviously stored result,
without re-evaluating the function:

```julia
y = @pcache "./pc_" ones(Float64, 3, 3) 
    cache load("./pc_ones[Float64,3,3;].jld2", 0M)
display(y)
    3×3 Matrix{Float64}:
    1.0  1.0  1.0
    1.0  1.0  1.0
    1.0  1.0  1.0
```

The information was store-to/retrieved-from in the current folder and the name of the file
used to store the data tries to reflect the input parameters. In this example, the file name was
`"pc_ones[Float64,3,3;].jld2"`, which is pretty much the function call `ones(Float64, 3, 3)`. However,
when function has many input parameters, or the input parameters are very long, the file name will
be more "opaque". E.g., with

```julia
z = @pcache "./pc_" sum(ones(Float64, 3, 3)) 
    cache save("./pc_sum[hash_4373253462404454046].jld2", 0M)
display(z)
    9.0
```

the filename becomes "pc_sum[hash_4373253462404454046].jld2", which still indicates that it is storing
results from a call to the function `sum` but the 3x3 matrix with the input parameter were "hashed"
into a unique file name.

The function `readcaches(prefix)` can be used to displays information about all the files containing
cached function parameters/values with the given prefix. After executing the examples above, we get:

```julia
readcaches("./pc_")

    file "./pc_ones[Float64,3,3;].jld2" (file =0M, pars=1K)
    Parameters (576 bytes)
    fun: ones                 args = (Float64, 3, 3)
    file "./pc_sum[hash_4373253462404454046].jld2" (file =0M, pars=1K)
    Parameters (680 bytes)
    fun: sum                  args = ([1.0 1.0 1.0; 1.0 1.0 1.0; 1.0 1.0 1.0],)
```

## The `@pcacheref` macro

The `@pcacheref` takes the same parameters as `@pcache` and behaves very similarly, except that it
returns a "reference" to the file where the data is saved, rather than the data itself. The actual
output can be recovered from the reference using `value()`

When these "references" are used as input parameters to functions called with `@pcacheref` or `@punref`,
the value of the "references" are automatically expanded using `value()`.

A typical example would be as follows:

First we cache the result to a function call

```julia
x = @pcacheref "./pc_" ones(Float64, 3, 3) 
    cache save("./ones[Float64,3,3;].jld2", 0M)
display(x)
    PersistentCache.RefToCache("./ones[Float64,3,3;].jld2")
display(value(x))
    3×3 Matrix{Float64}:
    1.0  1.0  1.0
    1.0  1.0  1.0
    1.0  1.0  1.0
```

The returned variable `x` is just a "reference" to the result and its type is
`PersistentCache.RefToCache`. To get the actual value os `x`, we used `value(x)`

We now perform further operations on `x`. Since we are caching all these operations using
`@pcacheref`, we can use `x` directly without bothering to call `value(x)`. The macro `@pcacheref`
will take care of that for us.

```julia
y = @pcacheref "./pc_" ones(Float64, 3, 3) 
    cache load("./ones[Float64,3,3;].jld2")
z = @pcacheref "./pc_" +(x,y)        
    cache save("./hash_7438214170582956065.jld2", 0M)
display(z)
    PersistentCache.RefToCache("./pc_+[hash_16068786971509888720].jld2")
display(value(z))
    3×3 Matrix{Float64}:
    2.0  2.0  2.0
    2.0  2.0  2.0
    2.0  2.0  2.0
```

The final variable `z` is still a reference, so to see its value we do need to use `value(z)`.

## The `@punref` macro

This macro can be applied to any function call to convert all "references" return by `@pcacheref`
into actual values. 

This would useful in the last example if we did not want to cache the result of `+(x,y)` but still
wanted to transparently "de-referencing" x and y:

```julia
x = @pcacheref "./pc_" ones(Float64, 3, 3) 
    cache save("./pc_ones[Float64,3,3;].jld2", 0M)
y = @pcacheref "./pc_" ones(Float64, 3, 3) 
    cache load("./pc_ones[Float64,3,3;].jld2")
w = @punref "./pc_" +(x,y)        
display(w)
    3×3 Matrix{Float64}:
    2.0  2.0  2.0
    2.0  2.0  2.0
    2.0  2.0  2.0
```

Note that now the result of `+(x,y)` was not cached and therefore the actual result was returned.

Note that `@punref` is not needed in calls to functions that specify input types. In that case
`PersistentCache` "references" are automatically converted to the types required by the function.

# Limitations

1. First and foremost: No check is made regarding whether or not the code of the functions cached
   have changed since the results were originally stored. 
   
   This means that, after changing a function, all cached results for that function should be
   erased. This should be relatively easy since the name of the function always appear in the
   filename.

2. `PersistentCall` only supports types that can be save with `JLD2`. Two important types currently
   not supported by `JLD2` are `PythonCall.Py` and `LRUCache.LRU`.

    Trying to use `PythonCall.Py` with `JLD2` will likely produce a segmentation fault (see
    https://github.com/JuliaPy/PythonCall.jl/issues/406 )

    To prevent a segmentation violation when using PythonCall, add the following custom serialization function.

    ```julia
    struct PySerialization
        dummy::String
    end
    JLD2.writeas(::Type{Py}) = PySerialization
    JLD2.wconvert(::Type{PySerialization},p::Py) =error("saving PythonCall.Py not supported")
    JLD2.rconvert(::Type{Py},p::PySerialization) =error("loading PythonCall.Py not supported")
    ```

    A similar problem/"fix" applies to `LRUCache.LRU`
