# RuDI Pipelines Framework

The [Rusty Data Interface](https://rustydataint.github.io/) (RuDI) 
is a standardized framework for developing and running HPC data 
analysis **pipelines** and interactive visualization **apps**
with a Rust-first mindset.

This is the repository for the **RuDI pipelines framework**, where
a pipeline, roughly synonymous with a workflow, refers to a 
series of data analysis actions coordinated by wrapper scripts.

The pipelines framework does not encode analysis pipelines themselves, 
which are found in other tool suite repositories created from our 
suite repository template:

- tool suite template: <https://github.com/RustyDataInt/rudi-suite-template>

Instead, the pipelines framework:

- reads YAML configuration files that are used to define a pipeline
- wraps pipelines into a common command-line interface (CLI)
- coordinates pipeline job submission to HPC schedulers
- provides a consistent format for building pipeline options and actions

## Usage

This repository is not used directly. Instead, it is cloned
and called by the 
[installer and CLI found here](https://github.com/RustyDataInt/rudi).
