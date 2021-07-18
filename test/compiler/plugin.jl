# This file is a part of Julia. License is MIT: https://julialang.org/license

using Test
const CC = Core.Compiler
import .CC:
    AbstractCompilerPlugin,
    InferenceState,
    OptimizationState

# hook invocations
# ----------------

const basic_counter = Ref(0)
increment_basic_counter!() = basic_counter[] += 1
struct HookCounter <: AbstractCompilerPlugin end
CC.preinf_hook!(::Type{HookCounter}, frame::InferenceState) = increment_basic_counter!()
CC.postinf_hook!(::Type{HookCounter}, frame::InferenceState) = increment_basic_counter!()
CC.preopt_hook!(::Type{HookCounter}, opt::OptimizationState) = increment_basic_counter!()
CC.postopt_hook!(::Type{HookCounter}, opt::OptimizationState) = increment_basic_counter!()

basic_counter_nullary_lambda() = return 42
function invoke_hook_counter()
    HookCounter(basic_counter_nullary_lambda)
end
@test invoke_hook_counter() == 42
@test basic_counter[] == 8 # 4 × (frames of HookCounter(nullary lambda), frames of nullary lambda)

# super simple rewrite
# --------------------

struct IdentityRewriter <: AbstractCompilerPlugin end
function CC.preinf_hook!(::Type{IdentityRewriter}, frame::InferenceState)
    linfo = frame.linfo
    if CC.is_shadow(linfo)
        if CC.getindex(CC.OVERDUB_CACHE_TABLE, linfo).def.name === :identity
            frame.src.code[1] = Core.ReturnNode(QuoteNode("42"))
        end
    end
end

# basic
call_identity_basic(a) = identity(a)
function change_identity_basic(a)
    return IdentityRewriter() do
        call_identity_basic(a)
    end
end
@test change_identity_basic(42) == "42"
@test call_identity_basic(42) == 42

# dynamic
call_identity_dynamic(a) = identity(Base.inferencebarrier(a))
function change_identity_dynamic(a)
    return IdentityRewriter() do
        call_identity_dynamic(a)
    end
end
@test change_identity_dynamic(42) == "42"
# code transformation works even if signature isn't fully concrete
@test Base.return_types(change_identity_dynamic, (Int,)) == Any[String]
@test call_identity_dynamic(42) == 42

# # to see the difference from Cassette.jl
# using Cassette
# Cassette.@context ChangeIdentity
# function change_identity_pass(::Type{<:ChangeIdentity}, ref::Cassette.Reflection)
#     if ref.method.name === :identity
#         ref.code_info.code[1] = Core.ReturnNode(QuoteNode("42"))
#     end
#     return ref.code_info
# end
# const context = ChangeIdentity(; pass = Cassette.@pass change_identity_pass)
# function change_identity_dynamic_cassette(a)
#     function nullary_lambda(); identity(Base.inferencebarrier(a)); end
#     return Cassette.overdub(context, nullary_lambda)
# end
# change_identity_dynamic_cassette(42)
# @test Base.return_types(change_identity_dynamic_cassette, (Int,)) == Any[Any]

# no rewrite
myidentity(a) = a
call_myidentity(a) = myidentity(a)
function dontchange_myidentity(a)
    return IdentityRewriter() do
        call_myidentity(a)
    end
end
@test dontchange_myidentity(42) == 42

# invalidations
# -------------

struct CheckInvalidation <: AbstractCompilerPlugin end
may_change_def_later(a) = a
function change_identity(a)
    return CheckInvalidation() do
        may_change_def_later(a)
    end
end
@test change_identity(42) == 42
may_change_def_later(a) = typeof(a)
@test_broken change_identity(42) == Int

# # adapted from https://gist.github.com/Keno/d0c2df947f67be543036238a0caeb1c6
# module FastSinCompiler
#
# # this compiler-plugin will rewrite all the `sin(::Float64)` calls into `fast_sin(::Float64)` calls:
# # - it will work on post-inf IR
# # - it shouldn't rewrite `sin(::Float64)` within `fast_sin(::Float64)`
# # - it should handle dynamic dispatches correctly
#
# # setup
# # -----
#
# import Core:
#     MethodInstance
# const CC = Core.Compiler
# import .CC:
#     InferenceState,
#     OptimizationState,
#     OptimizationParams,
#     IRCode,
#     optimize,
#     argextype,
#     widenconst,
#     AbstractCompilerPlugin,
#     preinf_hook!,
#     postinf_hook!,
#     preopt_hook!
# import Base:
#     @invoke,
#     get_world_counter,
#     to_tuple_type
# import Base.Meta: isexpr
# using Test
#
# let counter = 0
#     global fast_sin, get_fast_sin_counter, reset_counter
#     fast_sin(x::Float64) = (counter += 1; sin(x::Float64))
#     get_fast_sin_counter() = counter
#     reset_counter() = (counter = 0)
# end
#
# # impl
# # ----
#
# struct FastSinRewriter2 <: AbstractCompilerPlugin end
#
# function postinf_hook!(::Type{FastSinRewriter2}, frame::InferenceState)
#     for (i,x) in enumerate(frame.src.code)
#         if isexpr(x, :call)
#             if isexpr(x, :call) && length(x.args) == 2 &&
#                widenconst(argextype(x.args[1], frame)) === typeof(sin) &&
#                widenconst(argextype(x.args[2], frame)) === Float64
#                 frame.src.code[i] = Expr(:call, GlobalRef(@__MODULE__, :fast_sin), x.args[2])
#                 frame.stmt_info[i] = nothing
#                 global rewritecounter += 1
#             end
#         end
#     end
# end
# rewritecounter = 0
#
# function preopt_hook!(::Type{FastSinRewriter}, opt::OptimizationState)
#     ir = opt.ir
#     @assert isa(ir, IRCode)
#     (; sptypes, argtypes) = ir
#     for (i, s) in enumerate(ir.stmts)
#         stmt = s[:inst]
#         if isexpr(stmt, :call) && length(stmt.args) == 2 &&
#            widenconst(argextype(stmt.args[1], ir, sptypes, argtypes)) === typeof(sin) &&
#            widenconst(argextype(stmt.args[2], ir, sptypes, argtypes)) === Float64
#             ir.stmts.inst[i] = Expr(:call, GlobalRef(@__MODULE__, :fast_sin), stmt.args[2])
#             ir.stmts.info[i] = false
#             global rewritecounter += 1
#         end
#     end
# end
# rewritecounter = 0
#
# function foo()
#     FastSinRewriter2() do
#         sin(10)
#     end
# end
# @code_typed FastSinRewriter2(sin, 10)
# rewritecounter
# foo()
# get_fast_sin_counter()
#
# let
#     tme = first(methods(fast_sin, (Float64,)))
#     ttt = to_tuple_type((typeof(fast_sin), Float64,))
#
#     function CC.optimize(interp::FastSinInterpreter, opt::OptimizationState, params::OptimizationParams, @nospecialize(result))
#         @assert isnothing(opt.ir)
#
#         linfo = opt.linfo
#         if !(linfo.def === tme && linfo.specTypes === ttt)
#             (; src, sptypes, slottypes) = opt
#             for (i, x) in enumerate(src.code)
#                 if isexpr(x, :call) && length(x.args) == 2
#                     ft = widenconst(argextype(x.args[1], src, sptypes, slottypes))
#                     if ft === typeof(sin)
#                         at = widenconst(argextype(x.args[2], src, sptypes, slottypes))
#                         if at === Float64
#                             src.code[i] = Expr(:call, GlobalRef(@__MODULE__, :fast_sin), x.args[2])
#                         end
#                     end
#                 end
#             end
#         end
#
#         return optimize(native(interp), opt, params, result)
#     end
# end
#
# # test
# # ----
#
# get_sin() = sin
# function f(x, replace)
#     reset_counter()
#
#     @testset "simple" begin
#         sin(x)
#         @test get_fast_sin_counter() == (replace ? 1 : 0)
#     end
#
#     @testset "a bit complex, still inferred" begin
#         get_sin()(x)
#         @test get_fast_sin_counter() == (replace ? 2 : 0)
#     end
#
#     @testset "dynamic dispatch" begin
#         get_sin()(Base.inferencebarrier(x))
#         @test get_fast_sin_counter() == (replace ? 3 : 0) # fail, we can't hijack the dynamic dispatch
#     end
# end
#
# @testset "testset" begin
#     @testset "customized compilation" begin
#         FastSinRewriter() do
#             f(1.0, true)
#         end
#     end
#
#     @testset "don't affect native code cache" begin
#         f(1.0, false) # fail, since code cache can be inserted outside of `CC.code_cache`
#     end
# end
#
# end # module FastSinCompiler
