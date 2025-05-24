using Revise

using PersistentCache
using MacroTools
using Glob

using Test

prefix = "test/data/tmp_"


#=
# TODO: not really used
@testset "testParameters: testing @addstorepars" begin
    ## test @addstorepars
    prettify(
        @macroexpand PersistentCache.@addstorepars function example(aa; a::Int, b::String)
            println("example1")
            #display(aa)
            #display(a)
            #display(b)
            return aa + a
        end
    )

    PersistentCache.@addstorepars function example(aa; a::Int, b::String)
        println("example2")
        #display(aa)
        #display(a)
        #display(b)
        return aa + a
    end

    #PersistentCache.@addstorepars a = 1 # should give error at compile time (so cannot be caught by catch)

    function example2(; a=3, b="beta")
        return a
    end

    display(prettify(@macroexpand PersistentCache.@storepars p example(5 * a1, a=a1, b="two")))
    display(prettify(@macroexpand PersistentCache.@cachepars p prefix example(5 * a1, a=a1, b="two")))
    @macroexpand PersistentCache.@storepars p rand(3, 3)

    ## test @addstorepars

    p1 = PersistentCache.Parameters()
    a1 = 1
    rc1 = example(p1, 4 * a1, a=1, b="two") # automatically created by @addstorepars
    @test rc1 == 4 * a1 + 1
    @test p1.fun == [:example]
    @test p1.args == [(4 * a1,)]
    @test p1.kwargs == [Dict{Symbol,Any}(:a => 1, :b => "two")]
    display(p1)
    filename1 = PersistentCache.filename(p1)
    @test filename1 == "example[4;a=1_b=two].jld2"
    @show filename1

end;
=#

@testset "testParameters: testing @storepars" begin
    function example(aa; a::Int, b::String)
        println("example2")
        #display(aa)
        #display(a)
        #display(b)
        return aa + a
    end

    function example2(; a=3, b="beta")
        return a
    end

    ## test @storepars
    a1 = 2
    p2 = PersistentCache.Parameters()
    rc2 = PersistentCache.@storepars p2 example(5 * a1, a=2 * a1, b="two")
    @test p2.fun == [:example]
    @test p2.args == [(5 * a1,)]
    @test p2.kwargs == [Dict{Symbol,Any}(:a => 4, :b => "two")]

    p2 = PersistentCache.Parameters()
    rc2 = PersistentCache.@cachepars p2 prefix example(5 * a1; a=2 * a1, b="two")
    @test p2.fun == [:example]
    @test p2.args == [(5 * a1,)]
    @test p2.kwargs == [Dict{Symbol,Any}(:a => 4, :b => "two")]

    filename2 = PersistentCache.filename(p2)
    @test filename2 == "example[10;a=4_b=two].jld2"
    @show filename2

    b = "four"
    p2 = PersistentCache.Parameters()
    rc2 = PersistentCache.@storepars p2 example(5 * a1, a=2 * a1; b="two")
    rc3 = PersistentCache.@storepars p2 rand(3, 3)

    filename2 = PersistentCache.filename(p2)
    @test filename2 == "example[10;a=4_b=two]_rand[3,3;].jld2"
    @show filename2


    rc4 = PersistentCache.@storepars p2 example2(a=5)
    rc5 = PersistentCache.@storepars p2 example2(a=5; b="three")
    rc6 = PersistentCache.@storepars p2 example2(a=5; b)
    rc7 = PersistentCache.@storepars p2 example2(; a=5)
    #@show p2
    @test rc2 == 5 * a1 + 2 * a1
    @test rc4 == 5
    @test rc5 == 5
    @test rc6 == 5
    @test rc7 == 5
    display(p2)
    @test p2.fun == [:example, :rand, :example2, :example2, :example2, :example2]
    @test p2.args == [(5 * a1,), (3, 3), tuple(), tuple(), tuple(), tuple()]
    @test p2.kwargs == [Dict{Symbol,Any}(:a => 4, :b => "two"),
        Dict{Symbol,Any}(),
        Dict{Symbol,Any}(:a => 5),
        Dict{Symbol,Any}(:a => 5, :b => "three"),
        Dict{Symbol,Any}(:a => 5, :b => "four"),
        Dict{Symbol,Any}(:a => 5)]

    filename2 = PersistentCache.filename(p2)
    @test filename2[1:5] == "hash_"
    @show filename2

end;

@testset "testParameters: testing cache without macros" begin
    p2 = PersistentCache.Parameters()
    rc = PersistentCache.@storepars p2 ones(Float64, 3, 3)
    display(p2)
    functionName = PersistentCache.filename(p2; prefix)
    if isfile(functionName)
        println("erasing \"$functionName\"")
        rm(functionName)
    end
    (found1, rc1) = PersistentCache.getFromCache(p2; prefix)
    @test found1 == false

    name = PersistentCache.saveToCache(p2, rc; prefix)

    (found2, rc2) = PersistentCache.getFromCache(p2; prefix)
    @test found2 == true
    @test rc2 == rc

end

@testset "testParameters: testing cache with macros" begin
    p2 = PersistentCache.Parameters()
    rc = PersistentCache.@storepars p2 ones(Float64, 3, 3)
    functionName = PersistentCache.filename(p2; prefix)
    if isfile(functionName)
        println("erasing \"$functionName\"")
        rm(functionName)
    end

    prettify(@macroexpand @pcache prefix ones(Float64, 3, 3))

    rc1 = @pcache prefix ones(Float64, 3, 3)
    rc2 = @pcache prefix ones(Float64, 3, 3)
    @test rc1 == ones(Float64, 3, 3)
    @test rc1 == rc2

    rc3 = @pcacheref prefix ones(Float64, 3, 3)
    display(rc3)
    @test rc3 == PersistentCache.RefToCache("test/data/tmp_ones[Float64,3,3;].jld2")
    @test value(rc3) == ones(Float64, 3, 3)

    rc4 = @pcacheref prefix ones(Float64, 3, 4)
    rc5 = @pcacheref prefix ones(Float64, 3, 4)
    @test rc4 == PersistentCache.RefToCache("test/data/tmp_ones[Float64,3,4;].jld2")
    @test rc5 == PersistentCache.RefToCache("test/data/tmp_ones[Float64,3,4;].jld2")
    s = @punref prefix +(rc4, rc5)
    @test s == 2 * ones(3, 4)

    readcaches(prefix * "example*")
    readcaches(prefix * "ones*")
    rm(prefix * "example[10;a=4_b=two].jld2")
    rm(prefix * "ones[Float64,3,3;].jld2")
    rm(prefix * "ones[Float64,3,4;].jld2")
end;

@testset "testParameters: testing namedtuple and automatic unref" begin

    par1 = @pcacheref prefix ones(Float64, 100, 100)
    @test value(par1) == ones(Float64, 100, 100)
    par2 = @pcacheref prefix zeros(Float64, 100, 100)
    @test value(par2) == zeros(Float64, 100, 100)

    par3 = @pcacheref prefix +(par1, par2)
    @test value(par3) == ones(Float64, 100, 100)

    par4 = @pcacheref prefix tuple(1, 2, 3)
    @test value(par4) == (1, 2, 3)
    par5 = @pcacheref prefix namedtuple(name="aaa", value=53)
    @test value(par5) == (value=53, name="aaa") # order gets messed up

    function test(par1, par2, par3, par4, par5)
        return (par1, par2, par3, par4, par5)
    end

    rc = @pcacheref prefix test(par1, par2, par3, par4, par5) # will do automatic unreferencing
    display(value(rc))
    @test value(rc) == (
        ones(Float64, 100, 100),
        zeros(Float64, 100, 100),
        ones(Float64, 100, 100),
        (1, 2, 3),
        (value=53, name="aaa")
    )

    files = glob(prefix * "*.jld2")
    for file in files
        rm(file)
    end
end

#=
# check compatibility with PythonCall
begin
    struct PySerialization
        dummy::String
    end
    JLD2.writeas(::Type{Py}) = PySerialization
    JLD2.wconvert(::Type{PySerialization},p::Py) =error("saving PythonCall.Py not supported")
    JLD2.rconvert(::Type{Py},p::PySerialization) =error("loading PythonCall.Py not supported")

    using JLD2
    using PythonCall

    # dictionary
    d = pydict(a=1, b=2)
    jldsave(prefix * "pydict.jld2"; d)
    dd = load(prefix * "pydict.jld2")
end
=#