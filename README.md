# RuDI Pipelines Framework

The [Rusty Data Interface](https://rustydataint.github.io/) (RuDI) 
is a framework for developing, installing and running HPC **pipelines** 
and interactive web **apps** in a standardized design interface
with a Rust-first mindset.

This is the repository for the **RuDI pipelines framework**, where
a pipeline, roughly synonymous with a workflow, refers
to a series of data analysis actions coordinated by scripts.

The pipelines framework does not encode the analysis pipelines 
themselves, which are found in tool suites created from our 
suite repository template:

- tool suite template: <https://github.com/RustyDataInt/rudi-suite-template>

Instead, the pipelines framework encodes scripts that:

- allow YAML configuration files to be used to define a pipeline
- wrap pipelines into a common command-line interface (CLI)
- coordinate pipeline job submission to HPC schedulers

## Installation and use

This repository is not used directly. Instead, it is cloned
and managed by the 
[installer and CLI found here](https://github.com/RustyDataInt/rudi).
