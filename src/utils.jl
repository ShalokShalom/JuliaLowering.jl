# Error handling

TODO(msg::AbstractString) = throw(ErrorException("Lowering TODO: $msg"))
TODO(ex::SyntaxTree, msg="") = throw(LoweringError(ex, "Lowering TODO: $msg"))

# Errors found during lowering will result in LoweringError being thrown to
# indicate the syntax causing the error.
struct LoweringError <: Exception
    ex::SyntaxTree
    msg::String
end

function Base.showerror(io::IO, exc::LoweringError)
    print(io, "LoweringError:\n")
    src = sourceref(exc.ex)
    highlight(io, src; note=exc.msg)

    print(io, "\n\nDetailed provenance:\n")
    showprov(io, exc.ex, tree=true)
end

#-------------------------------------------------------------------------------
function _show_provtree(io::IO, ex::SyntaxTree, indent)
    print(io, ex, "\n")
    prov = provenance(ex)
    for (i, e) in enumerate(prov)
        islast = i == length(prov)
        printstyled(io, "$indent$(islast ? "└─ " : "├─ ")", color=:light_black)
        inner_indent = indent * (islast ? "   " : "│  ")
        _show_provtree(io, e, inner_indent)
    end
end

function _show_provtree(io::IO, prov, indent)
    fn = filename(prov)
    line, _ = source_location(prov)
    printstyled(io, "@ $fn:$line\n", color=:light_black)
end

function showprov(io::IO, exs::Vector)
    for (i,ex) in enumerate(Iterators.reverse(exs))
        sr = sourceref(ex)
        if i > 1
            print(io, "\n\n")
        end
        k = kind(ex)
        note = i > 1 && k == K"macrocall"  ? "in macro expansion" :
               i > 1 && k == K"$"          ? "interpolated here"  :
               "in source"
        highlight(io, sr, note=note)

        line, _ = source_location(sr)
        locstr = "$(filename(sr)):$line"
        JuliaSyntax._printstyled(io, "\n# @ $locstr", fgcolor=:light_black)
    end
end

function showprov(io::IO, ex::SyntaxTree; tree=false)
    if tree
        _show_provtree(io, ex, "")
    else
        showprov(io, flattened_provenance(ex))
    end
end

function showprov(x; kws...)
    showprov(stdout, x; kws...)
end

