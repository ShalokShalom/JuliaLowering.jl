#-------------------------------------------------------------------------------
abstract type AbstractLoweringContext end

"""
Unique symbolic identity for a variable
"""
const VarId = Int

const LayerId = Int

function syntax_graph(ctx::AbstractLoweringContext)
    ctx.graph
end

function new_var_id(ctx::AbstractLoweringContext)
    id = ctx.next_var_id[]
    ctx.next_var_id[] += 1
    return id
end

#-------------------------------------------------------------------------------
# AST creation utilities
_node_id(ex::NodeId) = ex
_node_id(ex::SyntaxTree) = ex.id

_node_id(graph::SyntaxGraph, ex::SyntaxTree) = (check_same_graph(graph, ex); ex.id)

_node_ids(graph::SyntaxGraph) = ()
_node_ids(graph::SyntaxGraph, ::Nothing, cs...) = _node_ids(graph, cs...)
_node_ids(graph::SyntaxGraph, c, cs...) = (_node_id(graph, c), _node_ids(graph, cs...)...)
_node_ids(graph::SyntaxGraph, cs::SyntaxList, cs1...) = (_node_ids(graph, cs...)..., _node_ids(graph, cs1...)...)
function _node_ids(graph::SyntaxGraph, cs::SyntaxList)
    check_same_graph(graph, cs)
    cs.ids
end

_unpack_srcref(graph, srcref::SyntaxTree) = _node_id(graph, srcref)
_unpack_srcref(graph, srcref::Tuple)      = _node_ids(graph, srcref...)
_unpack_srcref(graph, srcref)             = srcref

function makeleaf(graph::SyntaxGraph, srcref, proto; attrs...)
    id = newnode!(graph)
    ex = SyntaxTree(graph, id)
    copy_attrs!(ex, proto, true)
    setattr!(graph, id; source=_unpack_srcref(graph, srcref), attrs...)
    return ex
end

function makenode(graph::SyntaxGraph, srcref, proto, children...; attrs...)
    id = newnode!(graph)
    setchildren!(graph, id, _node_ids(graph, children...))
    ex = SyntaxTree(graph, id)
    copy_attrs!(ex, proto, true)
    setattr!(graph, id; source=_unpack_srcref(graph, srcref), attrs...)
    return SyntaxTree(graph, id)
end

function makenode(ctx, srcref, proto, children...; attrs...)
    makenode(syntax_graph(ctx), srcref, proto, children...; attrs...)
end

function makeleaf(ctx, srcref, proto; kws...)
    makeleaf(syntax_graph(ctx), srcref, proto; kws...)
end

function makeleaf(ctx, srcref, k::Kind, value; kws...)
    graph = syntax_graph(ctx)
    if k == K"Identifier" || k == K"core" || k == K"top" || k == K"Symbol" || k == K"globalref"
        makeleaf(graph, srcref, k; name_val=value, kws...)
    elseif k == K"SSAValue" || k == K"label"
        # FIXME?
        makeleaf(graph, srcref, k; var_id=value, kws...)
    else
        val = k == K"Integer" ? convert(Int,     value) :
              k == K"Float"   ? convert(Float64, value) :
              k == K"String"  ? convert(String,  value) :
              k == K"Char"    ? convert(Char,    value) :
              k == K"Value"   ? value                   :
              k == K"Bool"    ? value                   :
              error("Unexpected leaf kind `$k`")
        makeleaf(graph, srcref, k; value=val, kws...)
    end
end

# TODO: Replace this with makeleaf variant?
function mapleaf(ctx, src, kind)
    ex = makeleaf(syntax_graph(ctx), src, kind)
    # TODO: Value coersion might be broken here due to use of `name_val` vs
    # `value` vs ... ?
    copy_attrs!(ex, src)
    ex
end

# Convenience functions to create leaf nodes referring to identifiers within
# the Core and Top modules.
core_ref(ctx, ex, name) = makeleaf(ctx, ex, K"core", name)
Any_type(ctx, ex) = core_ref(ctx, ex, "Any")
svec_type(ctx, ex) = core_ref(ctx, ex, "svec")
nothing_(ctx, ex) = core_ref(ctx, ex, "nothing")
unused(ctx, ex) = core_ref(ctx, ex, "UNUSED")

top_ref(ctx, ex, name) = makeleaf(ctx, ex, K"top", name)

# Create a new SSA variable
function ssavar(ctx::AbstractLoweringContext, srcref)
    makeleaf(ctx, srcref, K"SSAValue", var_id=new_var_id(ctx))
end

# Assign `ex` to an SSA variable.
# Return (variable, assignment_node)
function assign_tmp(ctx::AbstractLoweringContext, ex)
    var = ssavar(ctx, ex)
    assign_var = makenode(ctx, ex, K"=", var, ex)
    var, assign_var
end


#-------------------------------------------------------------------------------
# @ast macro
function _match_srcref(ex)
    if Meta.isexpr(ex, :macrocall) && ex.args[1] == Symbol("@HERE")
        QuoteNode(ex.args[2])
    else
        esc(ex)
    end
end

function _match_kind_ex(defs, srcref, ex)
    kws = []
    if Meta.isexpr(ex, :call)
        kind = esc(ex.args[1])
        args = ex.args[2:end]
        if Meta.isexpr(args[1], :parameters)
            kws = map(esc, args[1].args)
            popfirst!(args)
        end
        while length(args) >= 1 && Meta.isexpr(args[end], :kw)
            pushfirst!(kws, esc(pop!(args)))
        end
        if length(args) == 1
            srcref = Symbol("srcref_$(length(defs))")
            push!(defs, :($srcref = $(_match_srcref(args[1]))))
        elseif length(args) > 1
            error("Unexpected: extra srcref argument in `$ex`?")
        end
    else
        kind = esc(ex)
    end
    kind, srcref, kws
end

function _expand_ast_tree(defs, ctx, srcref, tree)
    if Meta.isexpr(tree, :(::))
        # Leaf node
        kind, srcref, kws = _match_kind_ex(defs, srcref, tree.args[2])
        :(makeleaf($ctx, $srcref, $kind, $(esc(tree.args[1])), $(kws...)))
    elseif Meta.isexpr(tree, :call) && tree.args[1] === :(=>)
        # Leaf node with copied attributes
        kind = esc(tree.args[3])
        srcref = esc(tree.args[2])
        :(mapleaf($ctx, $srcref, $kind))
    elseif Meta.isexpr(tree, (:vcat, :hcat, :vect))
        # Interior node
        flatargs = []
        for a in tree.args
            if Meta.isexpr(a, :row)
                append!(flagargs, a.args)
            else
                push!(flatargs, a)
            end
        end
        kind, srcref, kws = _match_kind_ex(defs, srcref, flatargs[1])
        children = map(a->_expand_ast_tree(defs, ctx, srcref, a), flatargs[2:end])
        :(makenode($ctx, $srcref, $kind, $(children...), $(kws...)))
    elseif Meta.isexpr(tree, :(=))
        lhs = esc(tree.args[1])
        rhs = _expand_ast_tree(defs, ctx, srcref, tree.args[2])
        ssadef = Symbol("ssadef$(length(defs))")
        push!(defs, :(($lhs, $ssadef) = assign_tmp($ctx, $rhs)))
        ssadef
    elseif Meta.isexpr(tree, :if)
        Expr(:if, esc(tree.args[1]),
             map(a->_expand_ast_tree(defs, ctx, srcref, a), tree.args[2:end])...)
    elseif Meta.isexpr(tree, (:block, :tuple))
        Expr(tree.head, map(a->_expand_ast_tree(defs, ctx, srcref, a), tree.args)...)
    else
        esc(tree)
    end
end

"""
    @ast ctx srcref tree

Syntactic s-expression shorthand for constructing a `SyntaxTree` AST.

* `ctx` - SyntaxGraph context
* `srcref` - Reference to the source code from which this AST was derived.

The `tree` contains syntax of the following forms:
* `[kind child₁ child₂]` - construct an interior node with children
* `value :: kind`        - construct a leaf node
* `ex => kind`           - convert a leaf node to the given `kind`, copying attributes
                           from it and also using `ex` as the source reference.
* `var=ex`               - Set `var=ssavar(...)` and return an assignment node `\$var=ex`.
                           `var` may be used outside `@ast`
* `cond ? ex1 : ex2`     - Conditional; `ex1` and `ex2` will be recursively expanded.
                           `if ... end` and `if ... else ... end` also work with this.

Any `kind` can be replaced with an expression of the form
* `kind(srcref)` - override the source reference for this node and its children
* `kind(attr=val)` - set an additional attribute
* `kind(srcref; attr₁=val₁, attr₂=val₂)` - the general form

In any place `srcref` is used, the special form `@HERE()` can be used to instead
to indicate that the "primary" location of the source is the location where
`@HERE` occurs.


# Examples

```
@ast ctx srcref [
   K"toplevel"
   [K"using"
       [K"importpath"
           "Base"       ::K"Identifier"(src)
       ]
   ]
   [K"function"
       [K"call"
           "eval"       ::K"Identifier"
           "x"          ::K"Identifier"
       ]
       [K"call"
           "eval"       ::K"core"      
           mn           =>K"Identifier"
           "x"          ::K"Identifier"
       ]
   ]
]
```
"""
macro ast(ctx, srcref, tree)
    defs = []
    push!(defs, :(ctx = $(esc(ctx))))
    push!(defs, :(srcref = $(_match_srcref(srcref))))
    ex = _expand_ast_tree(defs, :ctx, :srcref, tree)
    quote
        $(defs...)
        $ex
    end
end

#-------------------------------------------------------------------------------
# Mapping and copying of AST nodes
function copy_attrs!(dest, src, all=false)
    # TODO: Make this faster?
    for (name, attr) in pairs(src.graph.attributes)
        if (all || (name !== :source && name !== :kind && name !== :syntax_flags)) &&
                haskey(attr, src.id)
            dest_attr = getattr(dest.graph, name, nothing)
            if !isnothing(dest_attr)
                dest_attr[dest.id] = attr[src.id]
            end
        end
    end
end

function copy_attrs!(dest, head::Union{Kind,JuliaSyntax.SyntaxHead}, all=false)
    if all
        sethead!(dest.graph, dest.id, head)
    end
end

function mapchildren(f, ctx, ex; extra_attrs...)
    if !haschildren(ex)
        return ex
    end
    orig_children = children(ex)
    cs = isempty(extra_attrs) ? nothing : SyntaxList(ctx)
    for (i,e) in enumerate(orig_children)
        c = f(e)
        if isnothing(cs)
            if c == e
                continue
            else
                cs = SyntaxList(ctx)
                append!(cs, orig_children[1:i-1])
            end
        end
        push!(cs::SyntaxList, c)
    end
    if isnothing(cs)
        # This function should be allocation-free if no children were changed
        # by the mapping and there's no extra_attrs
        return ex
    end
    cs::SyntaxList
    ex2 = makenode(ctx, ex, head(ex), cs)
    copy_attrs!(ex2, ex)
    setattr!(ex2; extra_attrs...)
    return ex2
end

"""
Copy AST `ex` into `ctx`
"""
function copy_ast(ctx, ex)
    # TODO: Do we need to keep a mapping of node IDs to ensure we don't
    # double-copy here in the case when some tree nodes are pointed to by
    # multiple parents? (How much does this actually happen in practice?)
    s = ex.source
    # TODO: Figure out how to use provenance() here?
    srcref = s isa NodeId ? copy_ast(ctx, SyntaxTree(ex.graph, s))            :
             s isa Tuple  ? map(i->copy_ast(ctx, SyntaxTree(ex.graph, i)), s) :
             s
    if haschildren(ex)
        cs = SyntaxList(ctx)
        for e in children(ex)
            push!(cs, copy_ast(ctx, e))
        end
        ex2 = makenode(ctx, srcref, ex, cs)
    else
        ex2 = makeleaf(ctx, srcref, ex)
    end
    return ex2
end

"""
    adopt_scope(ex, ref)

Copy `ex`, adopting the scope layer of `ref`.
"""
function adopt_scope(ex, scope_layer::LayerId)
    set_scope_layer(ex, ex, scope_layer, true)
end

function adopt_scope(ex, ref::SyntaxTree)
    adopt_scope(ex, ref.scope_layer)
end

#-------------------------------------------------------------------------------
# Predicates and accessors working on expression trees

function is_quoted(ex)
    kind(ex) in KSet"quote top core globalref outerref break inert
                     meta inbounds inline noinline loopinfo"
end

function is_sym_decl(x)
    k = kind(x)
    k == K"Identifier" || k == K"::"
end

function is_identifier(x)
    k = kind(x)
    k == K"Identifier" || k == K"var" || is_operator(k) || is_macro_name(k)
end

function is_eventually_call(ex::SyntaxTree)
    k = kind(ex)
    return k == K"call" || ((k == K"where" || k == K"::") && is_eventually_call(ex[1]))
end

function is_function_def(ex)
    k = kind(ex)
    return k == K"function" || k == K"->" ||
        (k == K"=" && numchildren(ex) == 2 && is_eventually_call(ex[1]))
end

function is_valid_name(ex)
    n = identifier_name(ex).name_val
    n !== "ccall" && n !== "cglobal"
end

function identifier_name(ex)
    kind(ex) == K"var" ? ex[1] : ex
end

function decl_var(ex)
    kind(ex) == K"::" ? ex[1] : ex
end

# Remove empty parameters block, eg, in the arg list of `f(x, y;)`
function remove_empty_parameters(args)
    i = length(args)
    while i > 0 && kind(args[i]) == K"parameters" && numchildren(args[i]) == 0
        i -= 1
    end
    args[1:i]
end

# given a complex assignment LHS, return the symbol that will ultimately be assigned to
function assigned_name(ex)
    k = kind(ex)
    if (k == K"call" || k == K"curly" || k == K"where") || (k == K"::" && is_eventually_call(ex))
        assigned_name(ex[1])
    else
        ex
    end
end

#-------------------------------------------------------------------------------
# @chk: Basic AST structure checking tool
#
# Check a condition involving an expression, throwing a LoweringError if it
# doesn't evaluate to true. Does some very simple pattern matching to attempt
# to extract the expression variable from the left hand side.
#
# Forms:
# @chk pred(ex)
# @chk pred(ex) msg
# @chk pred(ex) (msg_display_ex, msg)
macro chk(cond, msg=nothing)
    if Meta.isexpr(msg, :tuple)
        ex = msg.args[1]
        msg = msg.args[2]
    else
        ex = cond
        while true
            if ex isa Symbol
                break
            elseif ex.head == :call
                ex = ex.args[2]
            elseif ex.head == :ref
                ex = ex.args[1]
            elseif ex.head == :.
                ex = ex.args[1]
            elseif ex.head in (:(==), :(in), :<, :>)
                ex = ex.args[1]
            else
                error("Can't analyze $cond")
            end
        end
    end
    quote
        ex = $(esc(ex))
        @assert ex isa SyntaxTree
        ok = try
            $(esc(cond))
        catch
            false
        end
        if !ok
            throw(LoweringError(ex, $(isnothing(msg) ? "expected `$cond`" : esc(msg))))
        end
    end
end

