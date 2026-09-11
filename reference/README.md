# Reference material

Long-form documents that are versioned with the documentation but are not
rendered into the site. The site pages in `../content/` are the introduction;
these are the details behind them.

## Language

| Document | Covers |
| --- | --- |
| [`language.md`](language.md) | Full language reference |
| [`language/grammar.md`](language/grammar.md) | Concrete grammar |
| [`language/async.md`](language/async.md) | Async model |
| [`language/structured-async.md`](language/structured-async.md) | Structured concurrency rules |
| [`objects/README.md`](objects/README.md) | Object and contract semantics |
| [`injection/README.md`](injection/README.md) | Dependency injection |

## Implementation and ecosystem

| Document | Covers |
| --- | --- |
| [`stdlib.md`](stdlib.md) | Standard library overview |
| [`compiler-architecture.md`](compiler-architecture.md) | Compiler pipeline overview |
| [`performance/PERFORMANCE.md`](performance/PERFORMANCE.md) | Performance characteristics and measurements |
| [`THIRD_PARTY.md`](THIRD_PARTY.md) | Third-party integrations |

## Releases

Release notes are kept per version in [`releases/`](releases/): the current
release is [`1.3`](releases/1.3.md), preceded by [`1.0`](releases/1.0.md),
[`0.9.0-dev.5`](releases/0.9.0-dev.5.md) and
[`0.5.0-beta`](releases/0.5.0-beta.md).

## Related repositories

- Compiler, runtime and standard library: [`pumpumlang/punpun`](https://github.com/pumpumlang/punpun)
- Package manager and catalog: [`pumpumlang/punpun-ppx`](https://github.com/pumpumlang/punpun-ppx)

Generated API signatures are produced by the language repository (`pp doc`) and
published here as [API reference](../api-reference.html).
