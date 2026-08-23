# MAX framework

MAX is a high-performance inference server that provides
an [OpenAI-compatible endpoint](https://max.modular.com/rest-api/) for
large language models (LLMs) and it's a fundamental component of the
[Modular Platform](https://max.modular.com/intro).

This directory includes the source for our Python-based inference server,
Python-based model pipelines (graphs), Python-based neural-net operators
(high-level graph ops), Mojo-based kernel functions (low-level graph
ops for GPUs and CPUs), and more.

## Usage

With just a few commands, you can use MAX to create a local endpoint serving a
large language model (LLM) of your choice, using our CLI tool or Docker
container. Try it now with our [quickstart
guide](https://max.modular.com/get-started).

## Contributing

This tree is part of an unofficial fork and **does not accept contributions**.
See the [repository README](../README.md) for what this fork is and is not.

MAX itself is developed at
[modular/modular](https://github.com/modular/modular), which is where bug
reports, feature requests and pull requests for MAX belong. Please do not
file issues about this fork there.
