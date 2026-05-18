# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project overview

DIPY is a Python library for the analysis of MR diffusion imaging. It is a mixed Python/Cython/C codebase distributed on PyPI and conda-forge. The build system is Meson (via `meson-python`) and the developer task runner is [`spin`](https://github.com/scientific-python/spin), customized in `.spin/cmds.py`.

Python 3.12+ is required. Current development version: `1.13.0.dev0` (see `pyproject.toml`); `master` targets the future 2.0.0 line.

## Build & install (from source)

The package contains Cython extensions that must be compiled. Editable installs work, but **must disable build isolation** so the in-tree numpy/cython are used:

```bash
pip install -r requirements/build.txt
pip install --no-build-isolation -e .
```

`requirements/build.txt` is auto-generated from `pyproject.toml`'s `[project.optional-dependencies].build` table by `tools/generate_requirements.py` (enforced by a pre-commit hook). Edit `pyproject.toml`, not the generated `requirements/*.txt`.

Alternative dev workflow using `spin` (no manual editable install):

```bash
spin build          # meson-compile in ./build, install to ./build-install
spin test           # run pytest against the spin-installed tree
spin python         # spawn an interpreter with the built tree on sys.path
spin docs           # build Sphinx HTML docs (use --no-plot to skip examples)
spin clean          # remove build/ and build-install/
```

Cython sources live alongside `.py` files in each subpackage (e.g. `dipy/reconst/recspeed.pyx`, `dipy/tracking/propspeed.pyx`, `dipy/align/vector_fields.pyx`). After editing a `.pyx` file you must rebuild — running tests against stale `.so` files silently uses old code. The top-level `Makefile` documents which `.pyx` files exist per subpackage and is useful as an index, but real builds go through Meson; nested `meson.build` files in each subpackage declare the extensions.

## Tests

Test framework: `pytest>=9`. Tests live in `dipy/<subpackage>/tests/test_*.py`. Per-module test layout — adding code to `dipy/foo/bar.py` means adding tests in `dipy/foo/tests/test_bar.py`.

```bash
# Full suite (including doctests)
pytest -svv --doctest-modules --pyargs dipy

# A single test file / a single test
pytest dipy/reconst/tests/test_dti.py -svv
pytest dipy/reconst/tests/test_dti.py::test_tensor_model -svv

# Coverage for a single module
coverage run --source=dipy.core.geometry -m pytest --doctest-modules \
    dipy/core/tests/test_geometry.py
coverage report -m
```

`conftest.py` at the package root (`dipy/conftest.py`) defines a custom `PyxFile` pytest collector so that Cython `test_*.pyx` files are imported (as compiled modules) and their `test_*` functions are collected — never edit a `.pyx` test and expect pytest to pick it up without rebuilding. It also wires a `--warnings-as-errors` flag / `DIPY_WERRORS` env var.

`pyproject.toml` `[tool.pytest]` pins a long `filterwarnings` list for noisy upstream deprecations (FURY, cvxpy, joblib, scipy/h5py). Add new ignores there, not via inline `warnings.filterwarnings` in tests.

CI runs from an out-of-tree directory (`tools/ci/run_tests.sh` `cd`s into `for_testing/` and uses `pytest --pyargs dipy`) so import paths resolve from the installed package, not the source tree.

## Lint, format, pre-commit

Style is enforced by `ruff` (config in `ruff.toml`, line length 88) plus `codespell` and a few rst-checking hooks. Set up:

```bash
pip install -e .[style]
pre-commit install
pre-commit run --all-files   # one-shot run
```

Key isort settings (in `ruff.toml`): `force-sort-within-sections = true`, `known-first-party = ["dipy"]`, `section-order = [future, stdlib, third-party, first-party, local]`. Imports inside a section are sorted case-sensitive, by type, then alphabetically — `ruff check --fix` handles this automatically.

There is no separate type checker in CI; `py.typed` is shipped but typing is partial.

## Architecture

### Subpackage map (see `dipy/__init__.py` for the canonical list)

- `dipy/core` — gradient tables, spheres, geometry primitives; foundational types used everywhere.
- `dipy/reconst` — signal reconstruction models (DTI, DKI, CSD, CSA, DSI, MAPMRI, IVIM, SFM, ForeCAST, GQI, …). Each model is typically a `Model` / `Fit` class pair; speed-critical kernels live in sibling `.pyx` files (`recspeed.pyx`, `dkispeed.pyx`, `dirspeed.pyx`).
- `dipy/tracking` — local and PFT tractography, streamline metrics. Cython hotspots: `propspeed.pyx`, `localtrack.pyx`, `streamlinespeed.pyx`, `distances.pyx`. Direction getters and stopping criteria are also Cython (with `.pxd` headers for cross-module cimports).
- `dipy/align` — affine + SyN registration, streamline-based registration (SLR, BundleWarp), reslicing. Kernels: `vector_fields.pyx`, `crosscorr.pyx`, `sumsqdiff.pyx`, `expectmax.pyx`, `bundlemin.pyx`.
- `dipy/segment` — clustering (QuickBundles), tissue classification, brain masking; Cython modules: `cythonutils.pyx`, `featurespeed.pyx`, `metricspeed.pyx`, `clusteringspeed.pyx`, `clustering_algorithms.pyx`, `mrf.pyx`.
- `dipy/denoise` — NLMEANS, LPCA/MPPCA, Patch2Self, Gibbs ringing; `denspeed.pyx` for hot loops.
- `dipy/nn` — neural-network-based methods (EVAC+, bias field correction). Both `torch` and `tf` backends are present as subdirs; torch/tensorflow are optional and gated via `dipy.utils.optpkg`.
- `dipy/io` — readers/writers for NIfTI, gradient tables, tractograms (TRX/TCK/TRK), PAM (peak-and-metric) HDF5 files.
- `dipy/sims` — synthetic diffusion signal simulators.
- `dipy/stats` — tractometry / Bundle Analysis (BUAN) statistics.
- `dipy/viz` — visualization (depends on `fury`, optional).
- `dipy/data` — small datasets bundled with the package + a fetcher API in `fetcher.py` for larger remote datasets.
- `dipy/workflows` — see below.
- `dipy/utils` — cross-cutting helpers: `optpkg.py` (graceful optional imports — returns a `TripWire` that errors on attribute access if the package is missing), `logging.py`, `parallel.py`, `multiproc.py`, `deprecator.py`, `omp.pyx` (OpenMP runtime helpers).
- `dipy/testing` — shared test utilities and `decorators.py` (ignored by pytest at the top-level config because it defines decorators, not tests). `warning_for_keywords()` is used widely to enforce keyword-only public APIs while emitting a deprecation warning for positional calls — keep it on new public functions whose signatures we want to stabilize.

### Workflows / CLI

Every `dipy_*` console script declared in `pyproject.toml` `[project.scripts]` is a single entry point `dipy.workflows.cli:run`. That dispatcher looks up `sys.argv[0]` in the `cli_flows` mapping (`dipy/workflows/cli.py`) and runs the corresponding `Workflow` subclass. So adding a new CLI command means:

1. Implement a class extending `dipy.workflows.workflow.Workflow` with a `run(...)` method whose docstring drives argument parsing (`flow_runner.py` + `docstring_parser.py`).
2. Register the class in `cli_flows` (`dipy/workflows/cli.py`).
3. Add a `dipy_<name> = "dipy.workflows.cli:run"` entry in `pyproject.toml`.

Workflows use a docstring-driven IO iterator (`Workflow.get_io_iterator`) that introspects the calling frame to expand glob patterns and pair inputs with derived output filenames — this is why workflow `run()` signatures and docstrings must match exactly.

### C/Cython integration

- Shared C headers live in `src/`: `dpy_math.h`, `safe_openmp.pxd` (used to write OpenMP-friendly Cython that degrades gracefully when OpenMP isn't available), `conditional_omp.h`, `ctime.pxd`, `cythonutils.h`.
- `.pxd` files declare the cross-module Cython interface (e.g. `dipy/tracking/direction_getter.pxd`, `dipy/tracking/stopping_criterion.pxd`). When changing function signatures in a `.pxd`, every `cimport`er must be recompiled.
- The Meson minimum compiler versions (`meson.build`) are GCC ≥ 8.0, MSVC ≥ 19.20, Cython ≥ 0.29.35 — but the build requirement in `pyproject.toml` pins Cython ≥ 3.0.4.

## Development workflow conventions

### Branch / backport model

- All bug fixes and features land on `master` first. Backports to `maint/X.Y.x` happen automatically after merge by labeling the PR with `backport-maint/X.Y.x` — never push directly to a maint branch.
- The backport workflow (`.github/workflows/backport.yml`) is fully dynamic; adding a new maint branch only requires creating the matching GitHub label.
- See `.github/CONTRIBUTING.md` for the full maintenance/backport guide and conflict-resolution recipe.

### Releases

`spin prepare-release` (defined in `.spin/cmds.py`) runs a 22-step interactive checklist for full releases on `master` or a 9-step reduced checklist when invoked on a `maint/X.Y.x` branch (auto-detected from the current branch). Use `--from-step N` to resume after an interruption. Don't run release-prep steps manually unless you know which artefacts they touch — they edit `pyproject.toml`, `Changelog`, `AUTHOR`, `.mailmap`, `doc/index.rst`, `doc/release_notes/`, `doc/_static/version_switcher.json`, and `doc/devel/toolchain.rst`.

### Optional dependencies

Heavy or optional imports (cvxpy, scikit-learn, statsmodels, fury, matplotlib, torch, tensorflow, scikit-image, boto3, numexpr, …) **must** go through `dipy.utils.optpkg.optional_package`. Importing them at module top level breaks installs that don't have the extra installed. The pattern is:

```python
from dipy.utils.optpkg import optional_package
sklearn, have_sklearn, _ = optional_package("sklearn")
```

`have_<pkg>` flags are then used to gate code paths and skip tests.

### Public API stability

Use `dipy.testing.decorators.warning_for_keywords()` on new public functions to enforce keyword-only arguments going forward (emits a `DeprecationWarning` for positional calls). Use `dipy.utils.deprecator` helpers (`deprecate_with_version`, `deprecated_params`) when changing existing signatures rather than breaking them outright.

## Things to know before editing

- The repo's primary remote is `https://github.com/dipy/dipy` and the default branch is `master` (not `main`). The release tag detection in `.spin/cmds.py` fetches from that upstream explicitly.
- `dipy/data/files/` is excluded from pre-commit hooks — don't apply formatting to vendored test data.
- `tools/` and `doc/sphinxext/` are excluded from ruff (`ruff.toml` `extend-exclude`). Don't apply lint fixes blindly there.
- `dipy.__version__` comes from `dipy/version.py`, which is generated at build time by `tools/gitversion.py` and consumed by `meson.build`. Don't edit `version.py` by hand.
