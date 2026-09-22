# [Parsing MATPOWER or PSS/E Files](@id pm_data)

## Basic Parsing

Parse MATPOWER `.m` or PSS/E `.raw` files into intermediate data structures:

```julia
using PowerFlowFileParser

# Parse to PowerModels dictionary format
pm_data = PowerModelsData("case5.m")
pm_data = PowerModelsData("network.raw")

# Or use the base parsing function
pm_dict = parse_file("case5.m")
```

The parsing code originated from [`PowerModels.jl`](https://github.com/lanl-ansi/PowerModels.jl) (used with permission) and has been enhanced to handle large industrial cases with diverse modeling practices.

The PSS/E parser handles diverse modeling practices from transmission engineering, though anticipating all variations is challenging.

PowerFlowFileParser.jl has been tested with large cases including North American systems (WECC, MMWG), Latin American networks, and Caribbean grids, plus numerous open datasets.

## [Parsing Conventions](@id parse_conventions)

PowerFlowFileParser.jl applies the following conventions when parsing MATPOWER and PSS/E files to ensure data consistency and compatibility with downstream applications:

  - **BusType correction**: Validates bus connectivity status. Isolated buses in PSS/E are checked against network topology - truly disconnected buses are marked ISOLATED, while buses with generators become PV type. Applies to both MATPOWER and PSS/E.
  - **Synchronous Condensers**: Generators on PV buses with zero active power are identified as synchronous condensers.
  - **Transformer Data**: Stored in device base per-unit system.
  - **Transformer Susceptance**: MATPOWER transformer susceptance is split evenly between `from` and `to` ends to match PSS/E modeling.
  - **Tap Settings**: Automatically corrects tap values to be within defined ranges (mirrors PSS/E internal behavior not reflected in RAW files).
  - **Multi-Section Lines**: Parsed as individual line segments with intermediate "dummy buses" added to the network.
  - **PSS/E v34 field order**: v34 files share v35's section layout but keep the v33 field order in LOAD, GENERATOR, TWO-TERMINAL DC, VSC converter, FACTS, SWITCHED SHUNT and transformer winding records, with the v34 fields (`NREG`, `NDR`/`NDI`, `DGENP`/`DGENQ`/`DGENM`, winding `NOD`) appended at the end. The version is read from the `REV` header field; `@!` column comments are ignored.
  - **Geographic Data** (PSS/E v34 and v35): Substation coordinates automatically parsed when available.
  - **Interruptible Loads** (PSS/E v35): Interruptible load flags preserved in parsed data.
  - **Conforming/Non-Conforming Loads**: Load conforming status preserved as enum values.
  - **Breakers and Switches**: Distinguished by enum but use same data structure.
  - **Rating Corrections**: Rates B and C set to `nothing` when zero. Rate A corrected based on voltage levels (may generate warnings for double-circuit lines).
  - **Motor Loads**: Parser logs warnings when detecting motor load indicators, though PSS/E doesn't explicitly represent them.

## Known Limitations

  - **New rating formats**: Newer PSS/E versions support 12 rating bands (vs. traditional A/B/C). Without metadata, interpretation remains ambiguous.
  - **Motor load detection**: Motors modeled as negative-injection generators cannot be reliably distinguished from actual generators.
  - **Transformer direction**: Automatic direction swapping not yet implemented.
  - **Outage data**: Not currently parsed.

## Parsed Components

PowerFlowFileParser extracts comprehensive power system data including:

  - **Network**: Buses, branches (lines, transformers), areas, zones
  - **Generation**: Generators, synchronous condensers
  - **Load**: Static loads, interruptible loads, motor loads
  - **Compensation**: Shunts (fixed and switched)
  - **DC Systems**: HVDC lines, VSC converters
  - **FACTS**: Flexible AC transmission devices
  - **Storage**: Energy storage systems
  - **Controls**: Tap-changing transformers, phase-shifters
