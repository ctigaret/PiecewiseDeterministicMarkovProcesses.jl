using Documenter, PDMP

makedocs()

deploydocs(
	deps   = Deps.pip("mkdocs", "python-markdown-math"),
    repo   = "github.com/rveltz/PDMP.jl.git",
	julia  = "0.6",
	osname = "linux"
)

