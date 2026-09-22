# Architecture and Design Philosophy

PowerFlowFileParser.jl follows a clear separation of concerns:

**Parse, Don't Transform**: The library's primary responsibility is converting text files into simple, well-structured PowerModels dictionaries. Conversion to domain-specific types like PowerSystems.jl components is handled downstream.

**Parsing Pathway**: MATPOWER and PSS/E files are parsed into standardized PowerModels dictionaries via `parse_file()` or `PowerModelsData`.

This architecture keeps the parser lightweight, testable, and reusable across multiple downstream packages.

## Supported Formats

  - **MATPOWER (.m)**: Matlab-based case files common in academic research
  - **PSS/E RAW (.raw)**: Industry-standard format (versions 30, 32, 33, 34, 35)

## Data Validation

The parser applies automatic corrections including:

  - Connectivity validation
  - Reference bus verification
  - Per-unit conversion
  - Transformer parameter correction
  - Thermal limit validation
