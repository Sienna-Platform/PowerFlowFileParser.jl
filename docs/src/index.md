# PowerFlowFileParser.jl

```@meta
CurrentModule = PowerFlowFileParser
```

## Overview

`PowerFlowFileParser.jl` is a [`Julia`](http://www.julialang.org) package for parsing text-based power flow file formats (MATPOWER `.m` and PSS/E `.raw` files) into standardized intermediate data representations. It serves as a lightweight bridge between legacy power system data formats and modern Julia-based analysis tools

## About

`PowerFlowFileParser` is part of the National Laboratory of the Rockies
[Sienna platform](https://www.nrel.gov/analysis/sienna.html), an open source framework for
scheduling problems and dynamic simulations for power systems. The Sienna platform can be
[found on github](https://github.com/Sienna-Platform/Sienna). It contains three applications:

  - [Sienna\Data](https://github.com/Sienna-Platform/Sienna?tab=readme-ov-file#siennadata) enables
    efficient data input, analysis, and transformation
  - [Sienna\Ops](https://github.com/Sienna-Platform/Sienna?tab=readme-ov-file#siennaops) enables
    enables system scheduling simulations by formulating and solving optimization problems
  - [Sienna\Dyn](https://github.com/Sienna-Platform/Sienna?tab=readme-ov-file#siennadyn) enables
    system transient analysis including small signal stability and full system dynamic
    simulations

Each application uses multiple packages in the [`Julia`](http://www.julialang.org)
programming language.
