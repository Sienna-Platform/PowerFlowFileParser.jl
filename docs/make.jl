using Documenter
import DataStructures: OrderedDict
using PowerFlowFileParser

pages = OrderedDict(
    "Welcome Page" => "index.md",
    "Tutorials" => Any[
        "Quick Start" => "tutorials/quickstart.md",
    ],
    "How-To Guides" => Any[
        "Overview" => "how_to_guides/stub.md",
        "Parsing MATPOWER or PSS/E Files" => "how_to_guides/parse_matpower_psse.md"
    ],
    "Explanation" => Any[
        "Architecture" => "explanation/arch_design.md",
        "Main Data Structures" => "explanation/arch_design.md"
    ],
    "Reference" => Any[
        "Quick Reference" => "reference/stub.md",
        "Developer Guidelines" => "reference/developer_guidelines.md",
        "Public API" => "reference/public.md",
        "Internal API" => "reference/internal.md"
    ],
)

makedocs(
    modules = [PowerFlowFileParser],
    format = Documenter.HTML(
        prettyurls = haskey(ENV, "GITHUB_ACTIONS"),
        size_threshold = nothing,),
    sitename = "github.com/Sienna-Platform/PowerFlowFileParser.jl",
    authors = "Sienna Team",
    pages = Any[p for p in pages],
    draft = false,
)

deploydocs(
    repo="github.com/Sienna-Platform/PowerFlowFileParser.jl",
    target="build",
    branch="gh-pages",
    devbranch="main",
    devurl="dev",
    push_preview=true,
    versions=["stable" => "v^", "v#.#"],
)
