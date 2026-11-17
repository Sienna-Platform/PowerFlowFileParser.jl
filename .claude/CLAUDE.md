# PowerFlowFileParser.jl (PFFP) — psy6 branch

The only raw-file parser of the psy6 stack (layer 2). It parses MATPOWER and PSS/E files into a
PowerModels dictionary, then emits an OpenAPI document. PowerSystems.jl reads that document with
`from_file`. Julia compat: `^1.10`.

This file is repo-specific. The shared Sienna rules load from the import below; the `sienna-dev` skill holds the cross-package
context; the `sienna-dev` and `sienna-reviewer` subagents implement and review.

@Sienna.md

## Architecture rule

This package does not depend on PowerSystems.jl. It builds no PowerSystems.jl component. Do not
add a PSY dependency; PSY consumes the OpenAPI document instead.

## Pipeline

1. **Parse** — `parse_file(file)` or `PowerModelsData(file)`. `parse_file` accepts `.m`, `.raw`,
   and `.json`. The format parser builds the PowerModels dictionary, then applies data corrections
   and validation.
   - PSS/E RAW versions: `SUPPORTED_PTI_VERSIONS = (29, 30, 32, 33, 34, 35)` (`src/pm_io/pti.jl`).
     v29 uses the v30 tables; each layout family has one `(sections, dtypes, defaults)` registry.
2. **Contingency and monitoring data (optional)** — pass `con_files`, `mon_file`, `sub_file`, or
   `monitor_all_branches` to `parse_file`/`PowerModelsData`, or call `add_contingencies!`,
   `add_monitored!(pm, mon_path; sub_path)`, and `monitor_all_branches!` after the parse.
   `mon_file` and `monitor_all_branches` are mutually exclusive (`ArgumentError`).
3. **Emit** — `build_openapi_system(pm_data; power_units)` assembles an `OpenAPISystem`.
   `to_json(sys, filename; force, pretty)` validates and writes the OpenAPI JSON document.
   - `power_units` is `"NATURAL_UNITS"` (default) or `"COMPONENT_BASE"`. Any other value throws
     `DataFormatError`.
   - `build_openapi_system(raw_file, dyr_file)` also reads a PSS/E `.dyr` file. `parse_dyr` is
     internal (`src/pm_io/psse_dyr.jl`, `psse_dyr_mapping.jl`, `src/openapi/dynamics.jl`).

## Source layout — the non-obvious parts

- `src/pm_io/common.jl` holds `parse_file` and `correct_network_data!`. `src/pm_io/data.jl` holds
  `calc_*` helpers and per-unit conversion; it is not a component reader.
- `src/pm_io/psse.jl` builds the star bus of each three-winding transformer.
- `src/pm_io/node_breaker.jl` expands the `substation` section into bus records.
- `src/pm_io/psse_index.jl` holds the lookup keys that the `.con` and `.mon` readers share.
- `src/openapi/build.jl` runs the readers in dependency order. **It throws on any non-empty
  dictionary section that no reader consumed.** Add a reader, or add the section to
  `KNOWN_UNCONSUMED_PM_SECTIONS`.
- `src/openapi/device_base.jl` (`apply_device_base_conversion!`) implements
  `power_units = "COMPONENT_BASE"`. The name predates the "component base" term.
- `src/openapi/units.jl` assigns unit-checked values onto the generated OpenAPI components;
  `identity.jl` allocates component ids and resolves cross-references.
- `src/definitions.jl` holds the PSS/E rating version families (`PSSE_LEGACY_RATING_VERSIONS`,
  `PSSE_TWELVE_RATING_VERSIONS`).

## Dependencies

- `Project.toml` and `test/Project.toml` pin `InfrastructureSystems` to branch `IS4` through
  `[sources]`. Do not change the pin or any compat bound.
- The OpenAPI model packages: `InfrastructureCoreOpenAPIModels`, `PowerCoreOpenAPIModels`,
  `PowerOperationsOpenAPIModels`, `PowerDynamicsOpenAPIModels`.

## Commands

```sh
julia --project=test -e 'using Pkg; Pkg.instantiate()'     # test/Project.toml path-pins this checkout
julia --project=test test/runtests.jl                        # full suite
julia --project=test test/runtests.jl test_parse_dyr         # one file (@includetests, stem without .jl)
julia --project=docs docs/make.jl
julia --project=scripts/formatter -e 'include("scripts/formatter/formatter_code.jl")'
```

Compile-check after each edit: `julia --project -e 'using PowerFlowFileParser'`.
