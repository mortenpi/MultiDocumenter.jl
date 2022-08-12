module MultiDocumenter

import Documenter, Gumbo, AbstractTrees

include("search/flexsearch.jl")
include("search/stork.jl")

"""
    SearchConfig(index_versions = ["stable"], engine = MultiDocumenter.FlexSearch)

"""
Base.@kwdef mutable struct SearchConfig
    index_versions = ["stable"]
    engine = FlexSearch
end

struct MultiDocRef
    upstream::String

    path::String
    name::String
end

struct BrandImage
    path::String
    imagepath::String
end

function MultiDocRef(; upstream, name, path)
    MultiDocRef(upstream, path, name)
end

"""
    make(
        outdir,
        docs::Vector{MultiDocRef};
        assets_dir,
        brand_image,
        custom_stylesheets = [],
        custom_scripts = [],
        search_engine = SearchConfig(),
        prettyurls = true
    )

Aggregates multiple Documenter.jl-based documentation pages `docs` into `outdir`.

- `assets_dir` is copied into `outdir/assets`
- `brand_image` is a `BrandImage(path, imgpath)`, which is rendered as the leftmost
  item in the global navigation
- `custom_stylesheets` is a `Vector{String}` of stylesheets injected into each page.
- `custom_scripts` is a `Vector{String}` of scripts injected into each page.
- `search_engine` inserts a global search bar. See [`SearchConfig`](@ref) for more details.
- `prettyurls` removes all `index.html` suffixes from links in the global navigation.
"""
function make(
    outdir,
    docs::Vector{MultiDocRef};
    assets_dir = nothing,
    brand_image::Union{Nothing,BrandImage} = nothing,
    custom_stylesheets = [],
    custom_scripts = [],
    search_engine = SearchConfig(index_versions = ["stable"], engine = FlexSearch),
    prettyurls = true
)

    dir = make_output_structure(docs, prettyurls)
    out_assets = joinpath(dir, "assets")
    if assets_dir !== nothing && isdir(assets_dir)
        cp(assets_dir, out_assets)
    end
    isdir(out_assets) || mkpath(out_assets)
    cp(joinpath(@__DIR__, "..", "assets", "__default"), joinpath(out_assets, "__default"))

    inject_styles_and_global_navigation(
        dir,
        docs,
        brand_image,
        custom_stylesheets,
        custom_scripts,
        search_engine,
        prettyurls
    )

    if search_engine != false
        search_engine.engine.build_search_index(dir, search_engine)
    end

    cp(dir, outdir; force = true)
    rm(dir; force = true, recursive = true)

    return outdir
end

function make_output_structure(docs::Vector, prettyurls)
    dir = mktempdir()

    for doc in docs
        outpath = joinpath(dir, doc.path)
        cp(doc.upstream, outpath)

        gitpath = joinpath(outpath, ".git")
        if isdir(gitpath)
            rm(gitpath, recursive=true)
        end
    end

    open(joinpath(dir, "index.html"), "w") do io
        println(
            io,
            """
                <!--This file is automatically generated by MultiDocumenter.jl-->
                <meta http-equiv="refresh" content="0; url=./$(string(first(docs).path), prettyurls ? "/" : "/index.html")"/>
            """,
        )
    end

    return dir
end

function make_global_nav(dir, docs, thispagepath, brand_image, search_engine, prettyurls)
    nav = Gumbo.HTMLElement{:nav}([], Gumbo.NullNode(), Dict("id" => "multi-page-nav"))

    if brand_image !== nothing
        a = Gumbo.HTMLElement{:a}(
            [],
            nav,
            Dict(
                "class" => "brand",
                "href" => relpath(joinpath(dir, brand_image.path), thispagepath),
            ),
        )
        img = Gumbo.HTMLElement{:img}(
            [],
            a,
            Dict("src" => relpath(joinpath(dir, brand_image.imagepath), thispagepath)),
        )
        push!(a.children, img)
        push!(nav.children, a)
    end

    navitems = Gumbo.HTMLElement{:div}(
        [],
        nav,
        Dict("id" => "nav-items", "class" => "hidden-on-mobile"),
    )
    push!(nav.children, navitems)

    for doc in docs
        rp = relpath(joinpath(dir, doc.path), thispagepath)
        a = Gumbo.HTMLElement{:a}(
            [],
            navitems,
            Dict(
                "href" => string(rp, prettyurls ? "/" : "/index.html"),
                "class" =>
                    startswith(thispagepath, joinpath(dir, doc.path)) ?
                    "nav-link active nav-item" : "nav-link nav-item",
            ),
        )
        push!(a.children, Gumbo.HTMLText(a, doc.name))
        push!(navitems.children, a)
    end
    if search_engine != false
        search_engine.engine.inject_html!(navitems)
    end

    toggler = Gumbo.HTMLElement{:a}([], nav, Dict("id" => "multidoc-toggler"))
    push!(nav.children, toggler)

    return nav
end

function make_global_stylesheet(custom_stylesheets, path)
    out = []

    for stylesheet in custom_stylesheets
        style = Gumbo.HTMLElement{:link}(
            [],
            Gumbo.NullNode(),
            Dict(
                "rel" => "stylesheet",
                "type" => "text/css",
                "href" => joinpath(path, stylesheet),
            ),
        )
        push!(out, style)
    end

    return out
end

function make_global_scripts(custom_scripts, path)
    out = []

    for script in custom_scripts
        js = Gumbo.HTMLElement{:script}(
            [],
            Gumbo.NullNode(),
            Dict(
                "src" => joinpath(path, script),
                "type" => "text/javascript",
                "charset" => "utf-8",
            ),
        )
        push!(out, js)
    end

    return out
end

function js_injector()
    return read(joinpath(@__DIR__, "..", "assets", "multidoc_injector.js"), String)
end

function inject_styles_and_global_navigation(
    dir,
    docs::Vector{MultiDocRef},
    brand_image::BrandImage,
    custom_stylesheets,
    custom_scripts,
    search_engine,
    prettyurls
)

    if search_engine != false
        search_engine.engine.inject_script!(custom_scripts)
        search_engine.engine.inject_styles!(custom_stylesheets)
    end
    pushfirst!(custom_stylesheets, joinpath("assets", "__default", "multidoc.css"))

    for (root, _, files) in walkdir(dir)
        for file in files
            path = joinpath(root, file)
            if file == "documenter.js"
                open(path, "a") do io
                    println(io, js_injector())
                end
                continue
            end
            # no need to do anything about /index.html
            path == joinpath(dir, "index.html") && continue

            endswith(file, ".html") || continue

            islink(path) && continue
            isfile(path) || continue

            stylesheets = make_global_stylesheet(custom_stylesheets, relpath(dir, root))
            scripts = make_global_scripts(custom_scripts, relpath(dir, root))

            page = read(path, String)
            doc = Gumbo.parsehtml(page)
            injected = 0

            for el in AbstractTrees.PreOrderDFS(doc.root)
                injected >= 2 && break

                if el isa Gumbo.HTMLElement
                    if Gumbo.tag(el) == :head
                        for stylesheet in stylesheets
                            stylesheet.parent = el
                            push!(el.children, stylesheet)
                        end
                        for script in scripts
                            script.parent = el
                            pushfirst!(el.children, script)
                        end
                        injected += 1
                    elseif Gumbo.tag(el) == :body && !isempty(el.children)
                        documenter_div = first(el.children)
                        if documenter_div isa Gumbo.HTMLElement &&
                           Gumbo.getattr(documenter_div, "id", "") == "documenter"
                            # inject global navigation as first element in body

                            global_nav =
                                make_global_nav(dir, docs, root, brand_image, search_engine, prettyurls)
                            global_nav.parent = el
                            pushfirst!(el.children, global_nav)
                            injected += 1
                        else
                            @warn "Could not inject global nav into $path."
                        end
                    end
                end
            end

            open(path, "w") do io
                print(io, doc)
            end
        end
    end
end

end