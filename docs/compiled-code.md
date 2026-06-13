---
title: Compiled Code
has_children: false
nav_order: 50
---

## {{page.title}}

The MDI Pipelines Framework provides helpful support tools for 
integrating compiled code into your pipeline.

### Rust

The MDI Pipelines Framework provides the most extensive support
for pipelines with tools written in 
[Rust](https://rust-lang.org/). 
Rust is an oustanding system-level language for writing HPC 
data processing pipelines and highly recommended.

You are encouraged to create a single Rust crate, and thus compiled binary,
for your entire tool suite. Because that binary likely supports
multiple pipelines and actions via a dispatcher, by convention Rust code 
is placed into folder `shared/crates/<my_tools_name>`.

The following in an example command to compile Rust code.
All of the `rust` commands operate at the level of a tool suite.
However, it is necessary to activate the commands by calling
then on a specific pipeline of that suite. It does not matter which
pipeline you use, it just has to be part of the parent suite of interest.

```sh
# example command to compile Rust code
# `basecall` is any of the pipelines from the `hf3` tool suite
hf3 -d basecall rust --gcc "module load gcc/15" --compile 1.92
```

### Releasing compiled binaries via Continuous Integration with GitHub Actions

Most users do not want to compile your code into executable binaries, which 
can be frought with complications. For the best user experience, you should 
use Continuous Integration (CI) with 
[GitHub Actions](https://github.com/features/actions) to attach compiled 
x86_64 Linux binaries to versioned code releases.

Specifically, the
[MDI Tool Suite Template](https://RustyDataInt.github.io/mdi-suite-template/overview)
you should use to create your new tool suite provides templates for 
CI workflows. Copy them as needed from the `templates` to the `.github/workflows`
folder of your tools suite, change just one or two variables, and
the relevant Rust code will be compiled to a binary and attached as a release assset
whenever you push a new version tag to GitHub. Importantly, unlike containers,
binaries are compiled and released on any version tag release, even a patch update.

You can then write one or two lines in your pipeline code to download the binary 
automatically on the users behalf:

```sh
# SUITE_NAME is always set in a running pipeline
# GITHUB_OWNER and BINARY_NAME you must enter manually
# VERSIONED_BINARY_PATH is set by the getVersionedBinary utility
getVersionedBinary ${GITHUB_OWNER}/${SUITE_NAME} ${BINARY_NAME}
export MY_TOOLS_BIN=${VERSIONED_BINARY_PATH} # if you prefer your alias to VERSIONED_BINARY_PATH
${MY_TOOLS_BIN} action_name ...
```

It's that easy!
