# PowerFlowFileParser.jl

**Package role:** File Parsing library for power system data
**Julia compat:** ^1.10

## Overview

PowerFlowFileParser.jl is a specialized library for parsing text-based power flow file formats into simple intermediate data representations. This library serves as a critical bridge between legacy power system data formats (MATPOWER, PSS/E) and modern Julia-based power system analysis tools in the Sienna ecosystem. Always load the Sienna.md file before starting the session or suggesting any changes or running tests.

**Architectural Principle**: The core parsing functionality in this repository should **NOT** require PowerSystems.jl as a dependency. The parser's responsibility is to convert text files into simple, well-structured dictionary or struct representations. Any conversion to PowerSystems.jl typed components should be handled by PowerSystems.jl itself or by separate integration code.

For general Sienna coding practices, conventions, and performance guidelines, see [.claude/Sienna.md](.claude/Sienna.md).

This document covers PowerFlowFileParser-specific aspects.

## Core Capabilities

### Supported File Formats

PowerFlowFileParser can parse and convert the following text-based power flow file formats:

1. **MATPOWER (.m files)**: Matlab-based power flow case files widely used in academic research
2. **PSS/E RAW files (.raw)**: Industry-standard format from Siemens PTI PSS/E software
   - Supports versions 30, 32, 33, and 35
3. **Generic Matlab files**: General Matlab data structure files

### Conversion Pipeline

The library provides two main parsing pathways:

#### 1. PowerModels-based Pipeline
- **Entry Point**: `parse_file(file)` or `PowerModelsData(file)` constructor
- **Input**: MATPOWER (.m) or PSS/E (.raw) files
- **Process**:
  1. Parse text file using format-specific parser
  2. Convert to PowerModels intermediate dictionary representation
  3. Apply data corrections and validation
- **Output**: Dictionary with standardized power system data (PowerModelsData container)

#### 2. PowerFlowData-based Pipeline
- **Entry Point**: `PowerFlowDataNetwork(file)` constructor
- **Input**: PSS/E RAW files (versions 30, 32, 33)
- **Process**:
  1. Parse using PowerFlowData.jl native parser
  2. Store in PowerFlowData.Network typed structs
- **Output**: PowerFlowDataNetwork container with parsed component data

**Note**: The parsing logic produces simple intermediate representations (dictionaries or lightweight structs). Conversion to PowerSystems.jl typed components is a separate concern that should be handled downstream.
### Power System Components

The parser handles comprehensive power system modeling including:

- **Buses**: AC buses with voltage control, PQ/PV/Slack types
- **Branches**: Transmission lines, transformers (2-winding and 3-winding)
- **Generators**: Thermal, hydro, renewable (wind/solar), synchronous condensers
- **Loads**: Static loads, power loads
- **Shunts**: Fixed and switched admittances
- **DC Systems**: Two-terminal HVDC lines, VSC converters, multi-terminal DC
- **FACTS Devices**: Flexible AC transmission system controllers
- **Storage**: Energy reservoir storage systems
- **Control Devices**: Tap-changing transformers, phase-shifting transformers
- **Areas and Zones**: Load zones and areas for regional modeling

### Data Validation and Correction

Automatic data quality checks and corrections include:
- Connectivity validation
- Reference bus verification
- Per-unit conversion
- Transformer parameter correction
- Voltage angle difference bounds
- Thermal limit validation
- Branch rating corrections

## File Structure

### Top-Level Organization

```
PowerFlowFileParser.jl/
├── src/                      # Source code
│   ├── PowerFlowFileParser.jl  # Main module file (exports and imports)
│   ├── definitions.jl         # Constants and type definitions
│   ├── common.jl              # Shared utility functions
│   ├── pm_io.jl              # PowerModels IO includes
│   ├── im_io.jl              # InfrastructureModels IO includes
│   ├── power_models_data.jl  # PowerModelsData struct and System constructor
│   ├── powerflowdata_data.jl # PowerFlowDataNetwork struct and System constructor
│   ├── pm_io/                # PowerModels format parsers
│   └── im_io/                # InfrastructureModels format parsers
├── test/                     # Test suite
├── docs/                     # Documentation
└── scripts/                  # Utility scripts
```

### Source Code Details

#### Main Module (`src/PowerFlowFileParser.jl`)
- Defines module exports: `PowerModelsData`, `PowerFlowDataNetwork`, `parse_file`, `make_database`
- **Core parsing code should minimize imports** - avoid PowerSystems.jl types in parsing logic
- Current implementation has PowerSystems imports that should be refactored into separate integration layer

#### Core Data Structures

**`src/power_models_data.jl`**
- `PowerModelsData`: Simple container wrapping PowerModels dictionary format
- Should focus on data validation and correction, not PowerSystems.jl type construction
- Component readers should produce dictionaries, not typed PowerSystems components

**`src/powerflowdata_data.jl`**
- `PowerFlowDataNetwork`: Container wrapping PowerFlowData.Network format
- Provides access to parsed structs from PowerFlowData.jl
- Keep conversion logic separate from core parsing
#### Parser Implementations

**`src/pm_io/` - PowerModels IO Pathway**
- `matpower.jl`: MATPOWER .m file parser (~826 lines)
  - Matlab code parsing for matrices and data structures
  - Column definitions for bus, gen, branch, cost data
  - Conversion to PowerModels dictionary format

- `psse.jl`: PSS/E RAW file parser (~2348 lines)
  - PSS/E v33/v35 format support
  - Section-based parsing (BUS, LOAD, GENERATOR, BRANCH, etc.)
  - Three-winding transformer handling with star-bus creation

- `pti.jl`: PTI format definitions (~2678 lines)
  - Data type specifications for all PSS/E sections
  - Field mappings and default values
  - Multi-version support (v30, v32, v33, v35)

- `common.jl`: Shared parsing utilities
  - `parse_file()`: Main entry point dispatching by file extension
  - Data validation and correction pipeline
  - Format detection (.m, .raw, .json)

- `data.jl`: PowerModels data manipulation
  - Network data correction functions
  - Component-specific readers (buses, generators, loads, etc.)

**`src/im_io/` - InfrastructureModels IO Pathway**
- `matlab.jl`: Generic Matlab file parser (~339 lines)
  - Parses Matlab assignment syntax
  - Handles matrices, cells, and scalar values
  - Extensible for custom Matlab formats

- `common.jl`: Shared utilities for IM format
- `data.jl`: Data manipulation utilities (~179 lines)
  - Multi-network support
  - Data merging and updating functions

#### Utilities

**`src/common.jl`**
- `make_database()`: Export System to SQLite database using SiennaOpenAPIModels
- Generator mapping from YAML configuration
- Fuel type and prime mover string conversions
- Constants for data validation thresholds

**`src/definitions.jl`**
- Constants for logging, validation tolerances
- Winding category mappings
- Transformer parameter names

### Test Structure

```
test/
├── runtests.jl                 # Test runner
├── test_parse_matpower.jl      # MATPOWER parsing tests
└── test_parse_psse.jl          # PSS/E parsing tests
```

Tests validate:
- Parsing of various file formats
- Conversion to PowerModels dictionary
- System construction with all components
- Data integrity and validation

## Usage Patterns

### Core Parsing (Pure Data Extraction)

```julia
using PowerFlowFileParser

# Parse MATPOWER file to dictionary
pm_dict = parse_file("case30.m")
# Returns: Dict{String, Any} with keys like "bus", "gen", "branch", "baseMVA", etc.

# Parse PSS/E RAW file to dictionary
pm_dict = parse_file("network.raw")
# Returns: Dict{String, Any} in PowerModels format

# Wrap in container for convenience
pm_data = PowerModelsData("case30.m")
# Access: pm_data.data["bus"], pm_data.data["gen"], etc.

# Alternative: Use PowerFlowData parser
pfd_data = PowerFlowDataNetwork("network.raw")
# Access: pfd_data.data.buses, pfd_data.data.generators, etc.
```

### Advanced Parsing Options

```julia
# Control data validation and corrections
pm_dict = parse_file(
    "case.raw",
    import_all = false,              # Import only essential fields
    validate = true,                 # Apply data corrections
    correct_branch_rating = true     # Fix branch thermal ratings
)

# Or using PowerModelsData constructor
pm_data = PowerModelsData(
    "case.raw",
    pm_data_corrections = true,      # Apply PowerModels corrections
    import_all = false,              # Import only essential fields
    correct_branch_rating = true     # Fix branch thermal ratings
)
```

### Integration with PowerSystems.jl (Downstream)

**Note**: The following System construction should ideally be handled by PowerSystems.jl or a separate integration package, not by this parser library:

```julia
# This integration code should move to PowerSystems.jl
using PowerSystems

# PowerSystems.jl should provide constructors like:
sys = System(pm_data)  # Handled by PowerSystems, not this parser
```

## Key Dependencies

### Core Parsing Dependencies (should be minimal)
- **DataStructures.jl**: Sorted dictionaries for component ordering
- **YAML.jl**: Configuration file parsing

### Integration/Extension Dependencies (separate from core parsing)
- **PowerFlowData.jl**: Alternative PSS/E parser pathway
- **PowerSystems.jl**: ⚠️ Should NOT be required by core parsing code
- **InfrastructureSystems.jl**: ⚠️ Should be used only in integration layers
- **SiennaOpenAPIModels.jl**: Database serialization (extension functionality)
- **SQLite.jl**: Database export functionality (extension functionality)

**Refactoring Goal**: Move any PowerSystems.jl dependencies out of the core parsing logic (`pm_io/`, `im_io/`) and into separate integration modules or downstream packages.

## Design Philosophy

### Separation of Concerns

The library maintains a clear separation between parsing and system construction:

1. **Parse**: Text file → Intermediate representation (Dict or typed struct)
   - This is the primary responsibility of PowerFlowFileParser.jl
   - Should NOT depend on PowerSystems.jl types
   - Produces simple, well-documented data structures

2. **Build**: Intermediate representation → PowerSystems.System with typed components
   - This conversion should be handled by PowerSystems.jl or integration code
   - Not the core responsibility of this parsing library

### Benefits of This Approach

- **Independence**: Parser remains lightweight and doesn't depend on heavy simulation packages
- **Reusability**: Parsed data can be consumed by multiple downstream packages
- **Testability**: Parsing logic can be tested without PowerSystems.jl infrastructure
- **Maintainability**: Changes to PowerSystems.jl types don't require parser updates
- **Debugging**: Easy to inspect intermediate representations without type conversions

### Current State vs. Target Architecture

**Note**: The current codebase may still contain PowerSystems.jl dependencies in some integration code. The architectural goal is to refactor toward keeping the core parsing logic (in `pm_io/` and `im_io/`) independent of PowerSystems.jl, with only the data containers (`PowerModelsData`, `PowerFlowDataNetwork`) being simple wrappers around dictionaries or structs.
